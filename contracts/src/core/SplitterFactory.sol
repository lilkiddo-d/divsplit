// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ISplitterFactory} from "../interfaces/ISplitterFactory.sol";
import {IDividendAdapter} from "../interfaces/IDividendAdapter.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {DateLib} from "../libraries/DateLib.sol";
import {Splitter} from "./Splitter.sol";
import {PToken} from "./PToken.sol";
import {DToken} from "./DToken.sol";
import {TimeDecayAMM} from "../amm/TimeDecayAMM.sol";

/// @title SplitterFactory
/// @notice Registry and deployer of Splitters (one per stock + quarterly expiry) and their two TimeDecayAMM pools.
///         Also the single source of protocol configuration and roles for all clones.
/// @dev DEFAULT_ADMIN_ROLE is held by the 48h Timelock after deployment. GUARDIAN can only pause; KEEPER can only
///      announce dividend blackouts and pull airdrops.
contract SplitterFactory is AccessControl, ISplitterFactory {
    using Strings for uint256;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint16 public constant MAX_SWAP_FEE_BPS = 100; // 1%
    uint16 public constant MAX_DIVIDEND_BPS_LIMIT = 2_000; // 20%
    uint32 public constant MAX_TRAILING_WINDOW = 120 days;
    uint256 public constant MIN_TERM = 7 days;

    address public immutable splitterImpl;
    address public immutable pTokenImpl;
    address public immutable dTokenImpl;
    address public immutable ammImpl;

    IOracleAdapter public oracle;
    address public stable;
    address public feeCollector;
    IComplianceRegistry public compliance;
    uint16 public swapFeeBps;
    uint16 public protocolFeeShareBps;
    uint32 public maxHorizon;
    bool public globalPaused;

    struct Market {
        address splitter;
        address pToken;
        address dToken;
        address pPool;
        address dPool;
        address stock;
        uint64 expiry;
    }

    mapping(address stock => StockConfig) internal _stockConfigs;
    address[] public listedStocks;
    mapping(address stock => mapping(uint64 expiry => address)) public splitterOf;
    mapping(address splitter => Market) internal _markets;
    address[] public allSplitters;

    event StockListed(address indexed stock, address indexed adapter, uint16 maxDividendBps, uint32 trailingWindow);
    event StockConfigUpdated(address indexed stock, address indexed adapter, uint16 maxDividendBps, uint32 trailingWindow);
    event StockDelisted(address indexed stock);
    event MarketCreated(
        address indexed stock,
        uint64 indexed expiry,
        address splitter,
        address pToken,
        address dToken,
        address pPool,
        address dPool
    );
    event OracleSet(address oracle);
    event StableSet(address stable);
    event FeeCollectorSet(address feeCollector);
    event ComplianceSet(address compliance);
    event FeesSet(uint16 swapFeeBps, uint16 protocolFeeShareBps);
    event MaxHorizonSet(uint32 maxHorizon);
    event GlobalPauseSet(bool paused);

    error ZeroAddress();
    error NotListed();
    error AlreadyListed();
    error InvalidExpiry();
    error MarketExists();
    error InvalidParams();
    error NotCompliant(address account, bytes32 action);

    struct InitParams {
        address admin;
        address guardian;
        address oracle;
        address stable;
        address feeCollector;
        address compliance; // may be zero
        uint16 swapFeeBps;
        uint16 protocolFeeShareBps;
        uint32 maxHorizon;
        address splitterImpl;
        address pTokenImpl;
        address dTokenImpl;
        address ammImpl;
    }

    constructor(InitParams memory p) {
        if (p.admin == address(0) || p.oracle == address(0) || p.stable == address(0) || p.feeCollector == address(0)) {
            revert ZeroAddress();
        }
        if (p.swapFeeBps > MAX_SWAP_FEE_BPS || p.protocolFeeShareBps > 10_000 || p.maxHorizon < MIN_TERM) {
            revert InvalidParams();
        }
        if (p.splitterImpl == address(0) || p.pTokenImpl == address(0) || p.dTokenImpl == address(0) || p.ammImpl == address(0)) {
            revert ZeroAddress();
        }
        splitterImpl = p.splitterImpl;
        pTokenImpl = p.pTokenImpl;
        dTokenImpl = p.dTokenImpl;
        ammImpl = p.ammImpl;

        _grantRole(DEFAULT_ADMIN_ROLE, p.admin);
        if (p.guardian != address(0)) _grantRole(GUARDIAN_ROLE, p.guardian);
        oracle = IOracleAdapter(p.oracle);
        stable = p.stable;
        feeCollector = p.feeCollector;
        compliance = IComplianceRegistry(p.compliance);
        swapFeeBps = p.swapFeeBps;
        protocolFeeShareBps = p.protocolFeeShareBps;
        maxHorizon = p.maxHorizon;
        emit OracleSet(p.oracle);
        emit StableSet(p.stable);
        emit FeeCollectorSet(p.feeCollector);
        emit ComplianceSet(p.compliance);
        emit FeesSet(p.swapFeeBps, p.protocolFeeShareBps);
        emit MaxHorizonSet(p.maxHorizon);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Listing (Timelock)
    // ---------------------------------------------------------------------------------------------------------

    function listStock(address stock, StockConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (stock == address(0)) revert ZeroAddress();
        if (_stockConfigs[stock].listed) revert AlreadyListed();
        _validate(cfg);
        _stockConfigs[stock] = cfg;
        _stockConfigs[stock].listed = true;
        listedStocks.push(stock);
        emit StockListed(stock, address(cfg.adapter), cfg.maxDividendBps, cfg.trailingWindow);
    }

    /// @notice Update a listed stock's adapter/parameters (e.g. issuer changed its dividend mechanism).
    ///         Existing splitters pick up the new adapter on their next harvest. AMM curve params only affect
    ///         markets created afterwards.
    function updateStockConfig(address stock, StockConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_stockConfigs[stock].listed) revert NotListed();
        _validate(cfg);
        _stockConfigs[stock] = cfg;
        _stockConfigs[stock].listed = true;
        emit StockConfigUpdated(stock, address(cfg.adapter), cfg.maxDividendBps, cfg.trailingWindow);
    }

    /// @notice Prevent new markets for `stock`. Existing markets keep working (adapter config is retained).
    function delistStock(address stock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_stockConfigs[stock].listed) revert NotListed();
        _stockConfigs[stock].listed = false;
        emit StockDelisted(stock);
    }

    function _validate(StockConfig calldata cfg) internal pure {
        if (address(cfg.adapter) == address(0)) revert ZeroAddress();
        if (cfg.maxDividendBps == 0 || cfg.maxDividendBps > MAX_DIVIDEND_BPS_LIMIT) revert InvalidParams();
        if (cfg.trailingWindow > MAX_TRAILING_WINDOW) revert InvalidParams();
        if (cfg.scalarRoot <= 0 || cfg.scalarRootD <= 0 || cfg.initialAnchor < 1e18) revert InvalidParams();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Market creation (permissionless for listed stocks and valid expiries)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Create the splitter + P/D tokens + both AMM pools for `stock` expiring at `expiry`.
    /// @param expiry 00:00 UTC on Jan 1 / Apr 1 / Jul 1 / Oct 1 (quarterly; Jan 1 doubles as the yearly expiry).
    function createMarket(address stock, uint64 expiry) external returns (Market memory m) {
        StockConfig memory cfg = _stockConfigs[stock];
        if (!cfg.listed) revert NotListed();
        if (
            !DateLib.isQuarterlyExpiry(expiry) || expiry < block.timestamp + MIN_TERM
                || expiry > block.timestamp + maxHorizon
        ) revert InvalidExpiry();
        if (splitterOf[stock][expiry] != address(0)) revert MarketExists();

        bytes32 salt = keccak256(abi.encode(stock, expiry));
        m.stock = stock;
        m.expiry = expiry;
        m.splitter = Clones.cloneDeterministic(splitterImpl, salt);
        m.pToken = Clones.cloneDeterministic(pTokenImpl, salt);
        m.dToken = Clones.cloneDeterministic(dTokenImpl, salt);
        m.pPool = Clones.cloneDeterministic(ammImpl, keccak256(abi.encode(salt, "P")));
        m.dPool = Clones.cloneDeterministic(ammImpl, keccak256(abi.encode(salt, "D")));

        splitterOf[stock][expiry] = m.splitter;
        _markets[m.splitter] = m;
        allSplitters.push(m.splitter);

        (string memory sym, uint8 dec) = _meta(stock);
        string memory tag = string.concat(sym, "-", _dateTag(expiry));
        PToken(m.pToken).initialize(m.splitter, string.concat("Divsplit Price ", tag), string.concat("p", tag), dec);
        DToken(m.dToken).initialize(m.splitter, string.concat("Divsplit Dividend ", tag), string.concat("d", tag), dec);
        Splitter(m.splitter).initialize(address(this), stock, expiry, cfg.trailingWindow, m.pToken, m.dToken);
        TimeDecayAMM(m.pPool).initialize(
            address(this), m.splitter, m.pToken, stable, false, expiry, cfg.scalarRoot, cfg.initialAnchor
        );
        TimeDecayAMM(m.dPool).initialize(
            address(this), m.splitter, m.dToken, stable, true, expiry, cfg.scalarRootD, cfg.initialAnchor
        );

        emit MarketCreated(stock, expiry, m.splitter, m.pToken, m.dToken, m.pPool, m.dPool);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Configuration (Timelock) and emergency (Guardian)
    // ---------------------------------------------------------------------------------------------------------

    function setOracle(address oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IOracleAdapter(oracle_);
        emit OracleSet(oracle_);
    }

    /// @notice Quote token for markets created afterwards. Existing pools keep their stable.
    function setStable(address stable_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (stable_ == address(0)) revert ZeroAddress();
        stable = stable_;
        emit StableSet(stable_);
    }

    function setFeeCollector(address feeCollector_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        feeCollector = feeCollector_;
        emit FeeCollectorSet(feeCollector_);
    }

    /// @notice Zero address disables compliance gating entirely.
    function setCompliance(address compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(compliance_);
        emit ComplianceSet(compliance_);
    }

    function setFees(uint16 swapFeeBps_, uint16 protocolFeeShareBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (swapFeeBps_ > MAX_SWAP_FEE_BPS || protocolFeeShareBps_ > 10_000) revert InvalidParams();
        swapFeeBps = swapFeeBps_;
        protocolFeeShareBps = protocolFeeShareBps_;
        emit FeesSet(swapFeeBps_, protocolFeeShareBps_);
    }

    function setMaxHorizon(uint32 maxHorizon_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxHorizon_ < MIN_TERM) revert InvalidParams();
        maxHorizon = maxHorizon_;
        emit MaxHorizonSet(maxHorizon_);
    }

    function pauseAll() external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        globalPaused = true;
        emit GlobalPauseSet(true);
    }

    function unpauseAll() external onlyRole(DEFAULT_ADMIN_ROLE) {
        globalPaused = false;
        emit GlobalPauseSet(false);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views used by clones
    // ---------------------------------------------------------------------------------------------------------

    function stockConfig(address stock) external view returns (StockConfig memory) {
        return _stockConfigs[stock];
    }

    function market(address splitter) external view returns (Market memory) {
        return _markets[splitter];
    }

    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    function isGuardian(address account) external view returns (bool) {
        return hasRole(GUARDIAN_ROLE, account);
    }

    function isKeeper(address account) external view returns (bool) {
        return hasRole(KEEPER_ROLE, account);
    }

    function checkCompliance(address account, bytes32 action) external view {
        IComplianceRegistry c = compliance;
        if (address(c) != address(0) && !c.isAllowed(account, action)) revert NotCompliant(account, action);
    }

    function listedStockCount() external view returns (uint256) {
        return listedStocks.length;
    }

    function splitterCount() external view returns (uint256) {
        return allSplitters.length;
    }

    /// @notice Paginated market list for frontends (bounded by `limit`).
    function getMarkets(uint256 offset, uint256 limit) external view returns (Market[] memory out) {
        uint256 total = allSplitters.length;
        if (offset >= total) return out;
        uint256 end = offset + limit > total ? total : offset + limit;
        out = new Market[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = _markets[allSplitters[i]];
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------------------------------------

    function _meta(address stock) internal view returns (string memory sym, uint8 dec) {
        sym = "STOCK";
        dec = 18;
        try IERC20Metadata(stock).symbol() returns (string memory s) {
            if (bytes(s).length != 0 && bytes(s).length <= 16) sym = s;
        } catch {}
        try IERC20Metadata(stock).decimals() returns (uint8 d) {
            dec = d;
        } catch {}
    }

    function _dateTag(uint64 ts) internal pure returns (string memory) {
        (uint256 y, uint256 mo, uint256 d) = DateLib.dateFromTimestamp(ts);
        return string.concat(y.toString(), mo < 10 ? "0" : "", mo.toString(), d < 10 ? "0" : "", d.toString());
    }
}
