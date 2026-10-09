// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IProjectTokenHooks} from "../interfaces/IProjectTokenHooks.sol";

/// @title ProjectTokenHooks
/// @notice Every $DIVS feature lives here and stays disabled until the Timelock calls `setProjectToken` (once).
///         1. Staking: stakers earn a streamed share of AMM swap fees forwarded by the FeeCollector.
///         2. Advisory listing votes: stakers vote (weight = stake at proposal snapshot) on which stocks and expiries
///            should be listed. Results are advisory; listings are executed by the Timelock.
/// @dev The protocol never deploys or mints the project token. Stake is checkpointed by timestamp so voting power
///      is fixed at `snapshot = proposal time - 1`, defeating flash-stake voting. Fee rewards stream over
///      `REWARDS_DURATION`, defeating stake-right-before-distribution sniping.
contract ProjectTokenHooks is IProjectTokenHooks, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    uint256 public constant REWARDS_DURATION = 7 days;
    uint256 public constant MAX_REWARD_TOKENS = 8;
    uint256 private constant PRECISION = 1e18;

    enum ProposalKind {
        ListStock,
        AddExpiry,
        DelistStock,
        ParameterChange
    }

    enum ProposalState {
        Active,
        Defeated,
        Succeeded
    }

    struct RewardData {
        uint256 rate; // reward per second * PRECISION
        uint256 perTokenStored;
        uint64 periodFinish;
        uint64 lastUpdate;
    }

    struct Proposal {
        address proposer;
        ProposalKind kind;
        address stock;
        uint64 expiry;
        uint48 snapshot;
        uint48 voteEnd;
        uint256 forVotes;
        uint256 againstVotes;
        bytes32 descriptionHash;
    }

    IERC20 public projectToken;
    address public feeCollector;

    uint256 public totalStaked;
    mapping(address => uint256) public stakeOf;
    mapping(address => Checkpoints.Trace208) internal _stakeHistory;
    Checkpoints.Trace208 internal _totalHistory;

    address[] public rewardTokens;
    mapping(address token => bool) public isRewardToken;
    mapping(address token => RewardData) public rewardData;
    mapping(address token => mapping(address user => uint256)) public userPerTokenPaid;
    mapping(address token => mapping(address user => uint256)) public rewards;

    uint48 public votingPeriod = 5 days;
    uint256 public proposalThreshold; // in project-token units
    uint16 public quorumBps = 400; // 4% of total stake at snapshot
    Proposal[] internal _proposals;
    mapping(uint256 id => mapping(address voter => bool)) public hasVoted;

    event ProjectTokenSet(address indexed token);
    event FeeCollectorSet(address indexed feeCollector);
    event RewardTokenAdded(address indexed token);
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardNotified(address indexed token, uint256 amount, uint256 rate, uint64 periodFinish);
    event RewardPaid(address indexed account, address indexed token, uint256 amount);
    event GovernanceParamsSet(uint48 votingPeriod, uint256 proposalThreshold, uint16 quorumBps);
    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        ProposalKind kind,
        address stock,
        uint64 expiry,
        uint48 snapshot,
        uint48 voteEnd,
        string description
    );
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);

    error TokenFeaturesDisabled();
    error ProjectTokenAlreadySet();
    error InvalidToken();
    error ZeroAmount();
    error OnlyFeeCollector();
    error NotRewardToken();
    error TooManyRewardTokens();
    error BelowProposalThreshold();
    error VotingClosed();
    error AlreadyVoted();
    error NoVotingPower();
    error InvalidParams();
    error UnknownProposal();

    constructor(address admin, address feeCollector_) {
        if (feeCollector_ == address(0)) revert InvalidParams();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        feeCollector = feeCollector_;
        emit FeeCollectorSet(feeCollector_);
    }

    modifier whenTokenSet() {
        if (address(projectToken) == address(0)) revert TokenFeaturesDisabled();
        _;
    }

    modifier updateRewards(address account) {
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = rewardTokens[i];
            RewardData storage r = rewardData[t];
            r.perTokenStored = rewardPerToken(t);
            r.lastUpdate = uint64(_lastApplicable(r.periodFinish));
            if (account != address(0)) {
                rewards[t][account] = earned(account, t);
                userPerTokenPaid[t][account] = r.perTokenStored;
            }
        }
        _;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Admin (Timelock)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice One-time wiring of the externally launched project token. Callable once, by the Timelock.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert ProjectTokenAlreadySet();
        if (token == address(0) || token.code.length == 0) revert InvalidToken();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    function setFeeCollector(address feeCollector_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeCollector_ == address(0)) revert InvalidParams();
        feeCollector = feeCollector_;
        emit FeeCollectorSet(feeCollector_);
    }

    function addRewardToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || isRewardToken[token]) revert InvalidToken();
        if (rewardTokens.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        isRewardToken[token] = true;
        rewardTokens.push(token);
        emit RewardTokenAdded(token);
    }

    function setGovernanceParams(uint48 votingPeriod_, uint256 proposalThreshold_, uint16 quorumBps_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (votingPeriod_ < 1 days || votingPeriod_ > 30 days || quorumBps_ > 10_000) revert InvalidParams();
        votingPeriod = votingPeriod_;
        proposalThreshold = proposalThreshold_;
        quorumBps = quorumBps_;
        emit GovernanceParamsSet(votingPeriod_, proposalThreshold_, quorumBps_);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Staking
    // ---------------------------------------------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant whenTokenSet updateRewards(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        uint256 before = projectToken.balanceOf(address(this));
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = projectToken.balanceOf(address(this)) - before; // fee-on-transfer safe
        stakeOf[msg.sender] += received;
        totalStaked += received;
        _writeCheckpoints(msg.sender);
        emit Staked(msg.sender, received);
    }

    function unstake(uint256 amount) external nonReentrant whenTokenSet updateRewards(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        stakeOf[msg.sender] -= amount;
        totalStaked -= amount;
        _writeCheckpoints(msg.sender);
        projectToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant updateRewards(msg.sender) {
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = rewardTokens[i];
            uint256 amt = rewards[t][msg.sender];
            if (amt != 0) {
                rewards[t][msg.sender] = 0;
                IERC20(t).safeTransfer(msg.sender, amt);
                emit RewardPaid(msg.sender, t, amt);
            }
        }
    }

    /// @inheritdoc IProjectTokenHooks
    function notifyRewardAmount(address token, uint256 amount) external updateRewards(address(0)) {
        if (msg.sender != feeCollector) revert OnlyFeeCollector();
        if (!isRewardToken[token]) revert NotRewardToken();
        RewardData storage r = rewardData[token];
        uint256 scaled = amount * PRECISION;
        if (block.timestamp >= r.periodFinish) {
            r.rate = scaled / REWARDS_DURATION;
        } else {
            uint256 leftover = (r.periodFinish - block.timestamp) * r.rate;
            r.rate = (scaled + leftover) / REWARDS_DURATION;
        }
        r.lastUpdate = uint64(block.timestamp);
        r.periodFinish = uint64(block.timestamp + REWARDS_DURATION);
        emit RewardNotified(token, amount, r.rate, r.periodFinish);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Advisory listing votes
    // ---------------------------------------------------------------------------------------------------------

    function propose(ProposalKind kind, address stock, uint64 expiry, string calldata description)
        external
        whenTokenSet
        returns (uint256 id)
    {
        uint48 snapshot = SafeCast.toUint48(block.timestamp - 1);
        uint256 power = _stakeHistory[msg.sender].upperLookupRecent(snapshot);
        // slither-disable-next-line incorrect-equality
        if (power == 0 || power < proposalThreshold) revert BelowProposalThreshold();
        uint48 voteEnd = SafeCast.toUint48(block.timestamp) + votingPeriod;
        id = _proposals.length;
        _proposals.push(
            Proposal(msg.sender, kind, stock, expiry, snapshot, voteEnd, 0, 0, keccak256(bytes(description)))
        );
        emit ProposalCreated(id, msg.sender, kind, stock, expiry, snapshot, voteEnd, description);
    }

    function castVote(uint256 id, bool support) external whenTokenSet {
        if (id >= _proposals.length) revert UnknownProposal();
        Proposal storage p = _proposals[id];
        if (block.timestamp >= p.voteEnd) revert VotingClosed();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        uint256 weight = _stakeHistory[msg.sender].upperLookupRecent(p.snapshot);
        if (weight == 0) revert NoVotingPower();
        hasVoted[id][msg.sender] = true;
        if (support) p.forVotes += weight;
        else p.againstVotes += weight;
        emit VoteCast(id, msg.sender, support, weight);
    }

    function state(uint256 id) public view returns (ProposalState) {
        if (id >= _proposals.length) revert UnknownProposal();
        Proposal storage p = _proposals[id];
        if (block.timestamp < p.voteEnd) return ProposalState.Active;
        uint256 quorum = Math.mulDiv(_totalHistory.upperLookupRecent(p.snapshot), quorumBps, 10_000);
        if (p.forVotes > p.againstVotes && p.forVotes >= quorum) return ProposalState.Succeeded;
        return ProposalState.Defeated;
    }

    function proposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    /// @inheritdoc IProjectTokenHooks
    function isActive() external view returns (bool) {
        return address(projectToken) != address(0) && totalStaked != 0;
    }

    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    function stakeAt(address account, uint48 timestamp) external view returns (uint256) {
        return _stakeHistory[account].upperLookupRecent(timestamp);
    }

    function totalStakeAt(uint48 timestamp) external view returns (uint256) {
        return _totalHistory.upperLookupRecent(timestamp);
    }

    function rewardPerToken(address token) public view returns (uint256) {
        RewardData storage r = rewardData[token];
        // slither-disable-next-line incorrect-equality
        if (totalStaked == 0) return r.perTokenStored;
        uint256 last = _lastApplicable(r.periodFinish);
        if (last <= r.lastUpdate) return r.perTokenStored;
        return r.perTokenStored + ((last - r.lastUpdate) * r.rate) / totalStaked;
    }

    function earned(address account, address token) public view returns (uint256) {
        return rewards[token][account]
            + Math.mulDiv(stakeOf[account], rewardPerToken(token) - userPerTokenPaid[token][account], PRECISION);
    }

    function _lastApplicable(uint64 periodFinish) internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function _writeCheckpoints(address account) internal {
        uint48 ts = SafeCast.toUint48(block.timestamp);
        // push returns the previous/new values, which are not needed
        // slither-disable-next-line unused-return
        _stakeHistory[account].push(ts, SafeCast.toUint208(stakeOf[account]));
        // slither-disable-next-line unused-return
        _totalHistory.push(ts, SafeCast.toUint208(totalStaked));
    }
}
