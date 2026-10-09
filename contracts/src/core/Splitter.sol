// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {DividendAccumulator} from "./DividendAccumulator.sol";
import {PToken} from "./PToken.sol";
import {DToken, IDTokenHook} from "./DToken.sol";
import {IDividendAdapter} from "../interfaces/IDividendAdapter.sol";
import {ISplitterFactory} from "../interfaces/ISplitterFactory.sol";

/// @title Splitter
/// @notice Holds one stock token for one expiry and splits it into a Price token (P) and a Dividend token (D).
///         split:  `amount` stock -> `amount * 1e18 / scale` P + the same amount of D  (1:1 while scale == 1e18)
///         merge:  P + D (before expiry) -> stock
///         redeem: P (after expiry)      -> stock (+ any dividends captured after the D cutoff)
///         D holders receive every dividend captured until `dividendCutoff = expiry + trailingWindow`.
/// @dev Deployed as an EIP-1167 clone by SplitterFactory. All governance checks are delegated to the factory.
///      Invariants (see test/invariant):
///        pToken.totalSupply() == dToken.totalSupply()                      (before expiry)
///        stock.balanceOf(this) >= principal() + reserved[stock]             (unless a corporate action is pending)
///        totalPaid[token] <= totalDistributed[token]
contract Splitter is Initializable, ReentrancyGuardUpgradeable, DividendAccumulator, IDTokenHook {
    using SafeERC20 for IERC20;

    uint256 public constant SCALE_ONE = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_BLACKOUT = 45 days;
    uint256 public constant EX_DATE_LEAD = 1 days;
    /// @dev Rounding dust (from floor divisions on split/merge/redeem) that never counts as a corporate action.
    uint256 public constant DUST_TOLERANCE = 1_000;

    bytes32 public constant ACTION_SPLIT = keccak256("SPLIT");
    bytes32 public constant ACTION_MERGE = keccak256("MERGE");

    enum HarvestStatus {
        Ok,
        Deferred,
        CorporateAction
    }

    struct DividendNotice {
        uint64 exDate;
        uint64 payDate;
        uint128 amountPerShare; // informational, payout-token units per share
    }

    ISplitterFactory public factory;
    IERC20 public stock;
    PToken public pToken;
    DToken public dToken;
    uint64 public expiry;
    uint64 public dividendCutoff;
    uint64 public blackoutStart;
    uint64 public blackoutEnd;
    bool public paused;
    bool public corporateActionPending;

    /// @notice Stock units owed per 1e18 P units. Starts at 1e18; moves only on dividend reinvestment
    ///         (multiplier mechanism), post-cutoff stock dividends, or governance-resolved corporate actions.
    uint256 public scale;
    address public adapterInUse;
    uint256 public adapterState;
    uint256 public lastHarvest;

    /// @notice Non-stock dividends captured after the cutoff, per P unit (ACC_PRECISION), paid on redeem.
    mapping(address token => uint256) public postCutoffPerUnit;

    DividendNotice[] internal _notices;

    event Split(address indexed caller, address indexed to, uint256 stockIn, uint256 units);
    event Merged(address indexed caller, address indexed to, uint256 units, uint256 stockOut);
    event Redeemed(address indexed caller, address indexed to, uint256 units, uint256 stockOut);
    event Harvested(uint256 scale, uint256 adapterState);
    event ScaleUpdated(uint256 oldScale, uint256 newScale);
    event AdapterSynced(address indexed adapter, uint256 state);
    event CorporateActionFlagged(uint256 stockBalance, uint256 owed);
    event CorporateActionResolved(uint256 newScale, uint256 newAdapterState);
    event UnallocatedSwept(address indexed token, address indexed to, uint256 amount);
    event PostCutoffDistributed(address indexed token, uint256 amount, uint256 perUnit);
    event DividendAnnounced(uint64 exDate, uint64 payDate, uint128 amountPerShare, uint64 blackoutStart, uint64 blackoutEnd);
    event BlackoutCleared();
    event PausedSet(bool paused);
    event DividendsPulled(address indexed target);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    error NotAdmin();
    error NotGuardian();
    error NotKeeper();
    error OnlyDToken();
    error IsPaused();
    error CorporateActionIsPending();
    error IssuerUpdateInProgress();
    error Expired();
    error NotExpired();
    error InBlackout();
    error ZeroAmount();
    error ZeroAddress();
    error TransferAmountMismatch();
    error InvalidNotice();
    error InvalidTarget();
    error PullFailed();
    error PrincipalDecreased();
    error NoCorporateAction();
    error ProtectedToken();

    constructor() {
        _disableInitializers();
    }

    function initialize(address factory_, address stock_, uint64 expiry_, uint32 trailingWindow, address p, address d)
        external
        initializer
    {
        __ReentrancyGuard_init();
        factory = ISplitterFactory(factory_);
        stock = IERC20(stock_);
        expiry = expiry_;
        dividendCutoff = expiry_ + trailingWindow;
        pToken = PToken(p);
        dToken = DToken(d);
        scale = SCALE_ONE;
        _addRewardToken(stock_);
        _syncAdapter();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Modifiers / guards
    // ---------------------------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        if (!factory.isAdmin(msg.sender)) revert NotAdmin();
        _;
    }

    modifier onlyGuardian() {
        if (!factory.isGuardian(msg.sender) && !factory.isAdmin(msg.sender)) revert NotGuardian();
        _;
    }

    modifier onlyKeeper() {
        if (!factory.isKeeper(msg.sender) && !factory.isAdmin(msg.sender)) revert NotKeeper();
        _;
    }

    function _requireActive() internal view {
        if (paused || factory.globalPaused()) revert IsPaused();
        if (corporateActionPending) revert CorporateActionIsPending();
    }

    function _requireHarvested() internal {
        HarvestStatus s = _harvest();
        if (s == HarvestStatus.Deferred) revert IssuerUpdateInProgress();
        if (s == HarvestStatus.CorporateAction) revert CorporateActionIsPending();
    }

    // ---------------------------------------------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Deposit `amount` stock and receive equal amounts of P and D.
    function split(uint256 amount, address to) external nonReentrant returns (uint256 units) {
        _requireActive();
        if (block.timestamp >= expiry) revert Expired();
        if (inBlackout()) revert InBlackout();
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        factory.checkCompliance(msg.sender, ACTION_SPLIT);
        factory.checkCompliance(to, ACTION_SPLIT);
        // Distribute anything already received to existing D holders BEFORE new D is minted (anti flash-split).
        _requireHarvested();

        units = Math.mulDiv(amount, SCALE_ONE, scale);
        if (units == 0) revert ZeroAmount();

        uint256 before = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), amount);
        if (stock.balanceOf(address(this)) - before != amount) revert TransferAmountMismatch();

        pToken.mint(to, units);
        dToken.mint(to, units);
        emit Split(msg.sender, to, amount, units);
    }

    /// @notice Burn `units` P and `units` D (before expiry) and receive the underlying stock.
    function merge(uint256 units, address to) external nonReentrant returns (uint256 stockOut) {
        _requireActive();
        if (block.timestamp >= expiry) revert Expired();
        if (units == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        factory.checkCompliance(msg.sender, ACTION_MERGE);
        _requireHarvested();

        stockOut = Math.mulDiv(units, scale, SCALE_ONE);
        pToken.burn(msg.sender, units);
        dToken.burn(msg.sender, units); // checkpoints accrued dividends for msg.sender first
        stock.safeTransfer(to, stockOut);
        emit Merged(msg.sender, to, units, stockOut);
    }

    /// @notice After expiry, burn `units` P for the stock (and any post-cutoff non-stock dividends).
    /// @dev Never compliance-gated: holders must always be able to exit.
    function redeem(uint256 units, address to) external nonReentrant returns (uint256 stockOut) {
        _requireActive();
        if (block.timestamp < expiry) revert NotExpired();
        if (units == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        _requireHarvested();

        stockOut = Math.mulDiv(units, scale, SCALE_ONE);

        uint256 n = _rewardTokens.length;
        uint256[] memory extra = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address t = _rewardTokens[i];
            uint256 per = postCutoffPerUnit[t];
            // slither-disable-next-line incorrect-equality
            if (per == 0) continue;
            uint256 amt = Math.mulDiv(units, per, ACC_PRECISION);
            // slither-disable-next-line incorrect-equality
            if (amt == 0) continue;
            extra[i] = amt;
            reserved[t] -= amt;
            totalPaid[t] += amt;
        }

        pToken.burn(msg.sender, units);
        stock.safeTransfer(to, stockOut);
        for (uint256 i; i < n; ++i) {
            if (extra[i] != 0) IERC20(_rewardTokens[i]).safeTransfer(to, extra[i]);
        }
        emit Redeemed(msg.sender, to, units, stockOut);
    }

    /// @notice Claim all dividends accrued to msg.sender's D balance.
    function claimDividends(address to) external nonReentrant returns (uint256[] memory amounts) {
        if (to == address(0)) revert ZeroAddress();
        if (corporateActionPending) revert CorporateActionIsPending();
        _harvest();
        if (corporateActionPending) revert CorporateActionIsPending();
        amounts = _claim(msg.sender, to);
    }

    /// @notice Permissionless: capture newly received dividends. Flags (and halts on) corporate actions.
    function harvest() external nonReentrant returns (HarvestStatus) {
        return _harvest();
    }

    /// @notice Keeper: call the adapter's distributor to claim an airdropped dividend. Call `harvest()` afterwards
    ///         (or let the next split/merge/redeem/claim do it) to distribute what arrived.
    function pullDividends(bytes calldata data) external nonReentrant onlyKeeper {
        IDividendAdapter adapter = _syncAdapter();
        address target = adapter.claimTarget(address(stock));
        if (
            target == address(0) || target == address(stock) || target == address(pToken)
                || target == address(dToken) || isRewardToken[target]
        ) revert InvalidTarget();
        emit DividendsPulled(target);
        uint256 before = stock.balanceOf(address(this));
        // Target is fixed by Timelock-owned adapter config; the call cannot reduce stock (checked below) and no state
        // is written after it. The pre-call balance is intentionally compared post-call.
        // slither-disable-next-line reentrancy-balance,low-level-calls
        (bool ok,) = target.call(data);
        if (!ok) revert PullFailed();
        if (stock.balanceOf(address(this)) < before) revert PrincipalDecreased();
    }

    /// @inheritdoc IDTokenHook
    function onDTokenTransfer(address from, address to) external {
        if (msg.sender != address(dToken)) revert OnlyDToken();
        _checkpoint(from);
        _checkpoint(to);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Keeper / guardian / admin
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Keeper: announce an upcoming dividend. Splitting is blocked from one day before the ex-date until
    ///         the pay date, so nobody can mint D after the record date and dilute holders who earned the payout.
    function announceDividend(uint64 exDate, uint64 payDate, uint128 amountPerShare) external onlyKeeper {
        if (exDate <= block.timestamp || payDate < exDate || payDate - exDate > MAX_BLACKOUT) revert InvalidNotice();
        uint64 start = exDate - uint64(EX_DATE_LEAD);
        if (blackoutEnd >= start && blackoutEnd > block.timestamp) {
            if (start < blackoutStart) blackoutStart = start;
            if (payDate > blackoutEnd) blackoutEnd = payDate;
            if (blackoutEnd - blackoutStart > MAX_BLACKOUT + EX_DATE_LEAD) revert InvalidNotice();
        } else {
            blackoutStart = start;
            blackoutEnd = payDate;
        }
        _notices.push(DividendNotice(exDate, payDate, amountPerShare));
        emit DividendAnnounced(exDate, payDate, amountPerShare, blackoutStart, blackoutEnd);
    }

    /// @notice Guardian: clear a (mistaken or abusive) blackout.
    function clearBlackout() external onlyGuardian {
        blackoutStart = 0;
        blackoutEnd = 0;
        emit BlackoutCleared();
    }

    function pause() external onlyGuardian {
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit PausedSet(false);
    }

    /// @notice Admin (Timelock): resolve a flagged corporate action (split, reverse split, mechanism change).
    /// @param newScale stock units per 1e18 P units after the action (e.g. x2 for a 2:1 rebasing split).
    /// @param newAdapterState adapter state to resume from (e.g. the post-split multiplier).
    function resolveCorporateAction(uint256 newScale, uint256 newAdapterState) external onlyAdmin {
        if (!corporateActionPending) revert NoCorporateAction();
        if (newScale == 0) revert ZeroAmount();
        emit ScaleUpdated(scale, newScale);
        scale = newScale;
        adapterState = newAdapterState;
        corporateActionPending = false;
        emit CorporateActionResolved(newScale, newAdapterState);
    }

    /// @notice Admin: register an extra token dividends may arrive in (e.g. issuer switches payout currency).
    function addRewardToken(address token) external onlyAdmin {
        if (token == address(pToken) || token == address(dToken)) revert ProtectedToken();
        _addRewardToken(token);
    }

    /// @notice Admin: recover tokens sent by mistake. Stock, reward tokens and P/D can never be rescued.
    function rescueToken(address token, address to, uint256 amount) external onlyAdmin {
        if (
            token == address(stock) || isRewardToken[token] || token == address(pToken) || token == address(dToken)
        ) revert ProtectedToken();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Stock owed to P holders.
    function principal() public view returns (uint256) {
        return Math.mulDiv(pToken.totalSupply(), scale, SCALE_ONE);
    }

    function inBlackout() public view returns (bool) {
        return block.timestamp >= blackoutStart && block.timestamp < blackoutEnd;
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= expiry;
    }

    function claimable(address account) external view returns (address[] memory tokens, uint256[] memory amounts) {
        return _claimable(account);
    }

    function noticeCount() external view returns (uint256) {
        return _notices.length;
    }

    function notice(uint256 i) external view returns (DividendNotice memory) {
        return _notices[i];
    }

    /// @notice Stock received but not yet harvested (dividend-in-waiting); 0 if balance is short.
    function pendingStockDividend() external view returns (uint256) {
        uint256 bal = stock.balanceOf(address(this));
        uint256 owed = principal() + reserved[address(stock)];
        return bal > owed ? bal - owed : 0;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------

    function _syncAdapter() internal returns (IDividendAdapter adapter) {
        adapter = factory.stockConfig(address(stock)).adapter;
        if (address(adapter) != adapterInUse) {
            adapterInUse = address(adapter);
            adapterState = adapter.initialState(address(stock));
            address payout = adapter.payoutToken(address(stock));
            if (payout != address(0) && payout != address(pToken) && payout != address(dToken)) {
                _addRewardToken(payout);
            }
            emit AdapterSynced(address(adapter), adapterState);
        }
    }

    function _flagCorporateAction(uint256 bal, uint256 owed) internal {
        corporateActionPending = true;
        emit CorporateActionFlagged(bal, owed);
    }

    function _harvest() internal returns (HarvestStatus) {
        if (corporateActionPending) return HarvestStatus.CorporateAction;
        IDividendAdapter adapter = _syncAdapter();
        uint256 maxBps = factory.stockConfig(address(stock)).maxDividendBps;
        uint256 oldScale = scale;
        IDividendAdapter.Assessment memory a = adapter.assess(address(stock), oldScale, adapterState, maxBps);
        if (a.deferred) return HarvestStatus.Deferred;

        uint256 supply = pToken.totalSupply();
        uint256 oldPrincipal = Math.mulDiv(supply, oldScale, SCALE_ONE);
        uint256 bal = stock.balanceOf(address(this));
        uint256 stockReserved = reserved[address(stock)];
        if (a.corporateAction || a.newScale > oldScale) {
            _flagCorporateAction(bal, oldPrincipal + stockReserved);
            return HarvestStatus.CorporateAction;
        }

        uint256 newPrincipal = Math.mulDiv(supply, a.newScale, SCALE_ONE);
        uint256 owed = newPrincipal + stockReserved;
        if (bal < owed) {
            _flagCorporateAction(bal, owed);
            return HarvestStatus.CorporateAction;
        }
        uint256 excess = bal - owed;
        // A stock windfall larger than a dividend (e.g. 2:1 rebasing split) must not be paid to D holders.
        if (oldPrincipal != 0 && excess > Math.mulDiv(oldPrincipal, maxBps, BPS) + DUST_TOLERANCE) {
            _flagCorporateAction(bal, owed);
            return HarvestStatus.CorporateAction;
        }

        if (a.newScale != oldScale) emit ScaleUpdated(oldScale, a.newScale);
        scale = a.newScale;
        adapterState = a.newState;
        lastHarvest = block.timestamp;

        if (excess != 0) _allocate(address(stock), excess);
        uint256 n = _rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address t = _rewardTokens[i];
            if (t == address(stock)) continue;
            uint256 tb = IERC20(t).balanceOf(address(this));
            uint256 r = reserved[t];
            if (tb > r) _allocate(t, tb - r);
        }
        emit Harvested(scale, adapterState);
        return HarvestStatus.Ok;
    }

    function _allocate(address token, uint256 amount) internal {
        if (block.timestamp < dividendCutoff) {
            if (dToken.totalSupply() == 0) return _sweepUnallocated(token, amount);
            _distribute(token, amount);
            return;
        }
        uint256 ps = pToken.totalSupply();
        if (ps == 0) return _sweepUnallocated(token, amount);
        if (token == address(stock)) {
            uint256 inc = Math.mulDiv(amount, SCALE_ONE, ps);
            // slither-disable-next-line incorrect-equality
            if (inc == 0) return; // dust stays as excess
            emit ScaleUpdated(scale, scale + inc);
            scale += inc;
        } else {
            uint256 per = postCutoffPerUnit[token] + Math.mulDiv(amount, ACC_PRECISION, ps);
            postCutoffPerUnit[token] = per;
            reserved[token] += amount;
            totalDistributed[token] += amount;
            emit PostCutoffDistributed(token, amount, per);
        }
    }

    /// @dev Dividends that arrive while nobody holds the entitled token are sent to the FeeCollector instead of
    ///      being left for a future depositor to capture.
    function _sweepUnallocated(address token, uint256 amount) internal {
        address to = factory.feeCollector();
        IERC20(token).safeTransfer(to, amount);
        emit UnallocatedSwept(token, to, amount);
    }

    function _holderBalance(address account) internal view override returns (uint256) {
        return dToken.balanceOf(account);
    }

    function _holderSupply() internal view override returns (uint256) {
        return dToken.totalSupply();
    }

    function _payout(address token, address to, uint256 amount) internal override {
        IERC20(token).safeTransfer(to, amount);
    }
}
