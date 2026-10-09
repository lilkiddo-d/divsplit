// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {SplitterFactory} from "../src/core/SplitterFactory.sol";
import {Splitter} from "../src/core/Splitter.sol";
import {PToken} from "../src/core/PToken.sol";
import {DToken} from "../src/core/DToken.sol";
import {TimeDecayAMM} from "../src/amm/TimeDecayAMM.sol";
import {Router} from "../src/periphery/Router.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {FeeCollector} from "../src/governance/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/governance/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/governance/ComplianceRegistry.sol";
import {DivsplitTimelock} from "../src/governance/DivsplitTimelock.sol";
import {MultiplierDividendAdapter} from "../src/adapters/MultiplierDividendAdapter.sol";
import {RebaseDividendAdapter} from "../src/adapters/RebaseDividendAdapter.sol";
import {AirdropDividendAdapter} from "../src/adapters/AirdropDividendAdapter.sol";
import {NoDividendAdapter} from "../src/adapters/NoDividendAdapter.sol";
import {ISplitterFactory} from "../src/interfaces/ISplitterFactory.sol";
import {IAggregatorV3} from "../src/interfaces/IOracleAdapter.sol";
import {DateLib} from "../src/libraries/DateLib.sol";

/// @title Deploy
/// @notice One-shot deployment of the whole protocol: deploys, wires, lists the configured stocks, opens the next
///         quarterly markets, hands every admin role to the 48h Timelock and writes
///         `deployments/<chainId>.json` plus the frontend config `app/src/config/generated/deployments.<chainId>.json`.
/// @dev Signs only through the broadcaster chosen on the command line (Foundry keystore account
///      `divsplit-deployer` in production; `--unlocked` on a local anvil fork). It never reads a private key.
///      Usage (see DEPLOY.md):
///        forge script script/Deploy.s.sol --rpc-url robinhood --account divsplit-deployer \
///          --sender <deployer> --broadcast --verify --verifier blockscout \
///          --verifier-url https://robinhoodchain.blockscout.com/api/
contract Deploy is Script {
    struct Config {
        uint256 timelockDelay;
        address timelockProposer;
        address guardian;
        address keeper;
        address stable;
        address stableFeed;
        uint32 maxStaleness;
        uint16 maxRoundJumpBps;
        uint16 swapFeeBps;
        uint16 protocolFeeShareBps;
        uint16 stakerShareBps;
        uint32 maxHorizon;
        uint16 maxDividendBps;
        uint32 trailingWindow;
        int256 scalarRoot;
        int256 scalarRootD;
        int256 initialAnchor;
        uint256 quarterlyMarkets;
        string[] symbols;
        address[] tokens;
        address[] feeds;
    }

    struct Deployed {
        DivsplitTimelock timelock;
        OracleAdapter oracle;
        FeeCollector feeCollector;
        ProjectTokenHooks hooks;
        ComplianceRegistry compliance;
        SplitterFactory factory;
        Router router;
        MultiplierDividendAdapter multiplierAdapter;
        RebaseDividendAdapter rebaseAdapter;
        AirdropDividendAdapter airdropAdapter;
        NoDividendAdapter noDividendAdapter;
        address splitterImpl;
        address pTokenImpl;
        address dTokenImpl;
        address ammImpl;
    }

    Config internal cfg;
    Deployed internal d;
    address internal deployer;
    uint64[] internal expiries;

    function run() public {
        _loadConfig();
        deployer = msg.sender;
        address proposer = cfg.timelockProposer == address(0) ? deployer : cfg.timelockProposer;
        address guardian = cfg.guardian == address(0) ? deployer : cfg.guardian;
        address keeper = cfg.keeper == address(0) ? deployer : cfg.keeper;
        console2.log("Deployer:", deployer);
        console2.log("Chain id:", block.chainid);

        _computeExpiries();

        vm.startBroadcast();
        _deployCore(proposer, guardian);
        _wire(keeper);
        _listAndOpenMarkets();
        _handOverToTimelock();
        vm.stopBroadcast();

        _assertHandover();
        _writeOutputs(guardian, keeper, proposer);
    }

    // -----------------------------------------------------------------------------------------------------------

    function _loadConfig() internal {
        string memory path = string.concat(vm.projectRoot(), "/script/config/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        cfg.timelockDelay = vm.parseJsonUint(json, ".timelockDelay");
        cfg.timelockProposer = vm.parseJsonAddress(json, ".timelockProposer");
        cfg.guardian = vm.parseJsonAddress(json, ".guardian");
        cfg.keeper = vm.parseJsonAddress(json, ".keeper");
        cfg.stable = vm.parseJsonAddress(json, ".stable");
        cfg.stableFeed = vm.parseJsonAddress(json, ".stableFeed");
        cfg.maxStaleness = uint32(vm.parseJsonUint(json, ".maxStaleness"));
        cfg.maxRoundJumpBps = uint16(vm.parseJsonUint(json, ".maxRoundJumpBps"));
        cfg.swapFeeBps = uint16(vm.parseJsonUint(json, ".swapFeeBps"));
        cfg.protocolFeeShareBps = uint16(vm.parseJsonUint(json, ".protocolFeeShareBps"));
        cfg.stakerShareBps = uint16(vm.parseJsonUint(json, ".stakerShareBps"));
        cfg.maxHorizon = uint32(vm.parseJsonUint(json, ".maxHorizon"));
        cfg.maxDividendBps = uint16(vm.parseJsonUint(json, ".maxDividendBps"));
        cfg.trailingWindow = uint32(vm.parseJsonUint(json, ".trailingWindow"));
        cfg.scalarRoot = int256(vm.parseJsonUint(json, ".scalarRoot"));
        cfg.scalarRootD = int256(vm.parseJsonUint(json, ".scalarRootD"));
        cfg.initialAnchor = int256(vm.parseJsonUint(json, ".initialAnchor"));
        cfg.quarterlyMarkets = vm.parseJsonUint(json, ".quarterlyMarkets");
        cfg.symbols = vm.parseJsonStringArray(json, ".stockSymbols");
        cfg.tokens = vm.parseJsonAddressArray(json, ".stockTokens");
        cfg.feeds = vm.parseJsonAddressArray(json, ".stockFeeds");
        require(cfg.symbols.length == cfg.tokens.length && cfg.tokens.length == cfg.feeds.length, "config arrays");
        require(cfg.stable.code.length != 0, "stable has no code on this chain");
        for (uint256 i; i < cfg.tokens.length; ++i) {
            require(cfg.tokens[i].code.length != 0, string.concat("no code: ", cfg.symbols[i]));
            require(cfg.feeds[i].code.length != 0, string.concat("no feed code: ", cfg.symbols[i]));
        }
    }

    /// @dev Next `quarterlyMarkets` quarter-start expiries at least MIN_TERM away.
    function _computeExpiries() internal {
        (uint256 y, uint256 m,) = DateLib.dateFromTimestamp(block.timestamp);
        uint256 qm = ((m - 1) / 3) * 3 + 1; // current quarter's first month
        while (expiries.length < cfg.quarterlyMarkets) {
            qm += 3;
            if (qm > 12) {
                qm -= 12;
                y += 1;
            }
            uint256 ts = DateLib.timestampFromDate(y, qm, 1);
            if (ts >= block.timestamp + 7 days && ts <= block.timestamp + cfg.maxHorizon) expiries.push(uint64(ts));
        }
    }

    function _deployCore(address proposer, address guardian) internal {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute once the delay has passed
        d.timelock = new DivsplitTimelock(cfg.timelockDelay, proposers, executors);

        d.oracle = new OracleAdapter(deployer);
        d.feeCollector = new FeeCollector(deployer, address(d.timelock), cfg.stakerShareBps);
        d.hooks = new ProjectTokenHooks(deployer, address(d.feeCollector));
        d.compliance = new ComplianceRegistry(deployer);

        d.splitterImpl = address(new Splitter());
        d.pTokenImpl = address(new PToken());
        d.dTokenImpl = address(new DToken());
        d.ammImpl = address(new TimeDecayAMM());

        d.factory = new SplitterFactory(
            SplitterFactory.InitParams({
                admin: deployer,
                guardian: guardian,
                oracle: address(d.oracle),
                stable: cfg.stable,
                feeCollector: address(d.feeCollector),
                compliance: address(d.compliance),
                swapFeeBps: cfg.swapFeeBps,
                protocolFeeShareBps: cfg.protocolFeeShareBps,
                maxHorizon: cfg.maxHorizon,
                splitterImpl: d.splitterImpl,
                pTokenImpl: d.pTokenImpl,
                dTokenImpl: d.dTokenImpl,
                ammImpl: d.ammImpl
            })
        );
        d.router = new Router(address(d.factory));
        d.multiplierAdapter = new MultiplierDividendAdapter();
        d.rebaseAdapter = new RebaseDividendAdapter();
        d.airdropAdapter = new AirdropDividendAdapter(address(d.timelock));
        d.noDividendAdapter = new NoDividendAdapter();
    }

    function _wire(address keeper) internal {
        d.feeCollector.setHooks(address(d.hooks));
        d.hooks.addRewardToken(cfg.stable);
        d.oracle.setFeed(cfg.stable, _feed(cfg.stableFeed, 0));
        for (uint256 i; i < cfg.tokens.length; ++i) {
            d.oracle.setFeed(cfg.tokens[i], _feed(cfg.feeds[i], cfg.maxRoundJumpBps));
        }
        d.factory.grantRole(d.factory.KEEPER_ROLE(), keeper);
    }

    function _listAndOpenMarkets() internal {
        for (uint256 i; i < cfg.tokens.length; ++i) {
            d.factory.listStock(
                cfg.tokens[i],
                ISplitterFactory.StockConfig({
                    listed: true,
                    adapter: d.multiplierAdapter, // Robinhood Chain stock tokens use the ERC-8056 multiplier
                    maxDividendBps: cfg.maxDividendBps,
                    trailingWindow: cfg.trailingWindow,
                    scalarRoot: cfg.scalarRoot,
                    scalarRootD: cfg.scalarRootD,
                    initialAnchor: cfg.initialAnchor
                })
            );
            for (uint256 j; j < expiries.length; ++j) {
                d.factory.createMarket(cfg.tokens[i], expiries[j]);
            }
        }
    }

    function _handOverToTimelock() internal {
        address tl = address(d.timelock);
        _handOver(IAccessControl(address(d.factory)), tl);
        _handOver(IAccessControl(address(d.oracle)), tl);
        _handOver(IAccessControl(address(d.feeCollector)), tl);
        _handOver(IAccessControl(address(d.hooks)), tl);
        _handOver(IAccessControl(address(d.compliance)), tl);
    }

    function _handOver(IAccessControl c, address tl) internal {
        c.grantRole(bytes32(0), tl);
        c.renounceRole(bytes32(0), deployer);
    }

    function _assertHandover() internal view {
        address tl = address(d.timelock);
        IAccessControl[5] memory cs = [
            IAccessControl(address(d.factory)),
            IAccessControl(address(d.oracle)),
            IAccessControl(address(d.feeCollector)),
            IAccessControl(address(d.hooks)),
            IAccessControl(address(d.compliance))
        ];
        for (uint256 i; i < cs.length; ++i) {
            require(cs[i].hasRole(bytes32(0), tl), "timelock not admin");
            require(!cs[i].hasRole(bytes32(0), deployer), "deployer still admin");
        }
        require(d.airdropAdapter.owner() == tl, "airdrop owner");
        require(d.timelock.getMinDelay() >= 48 hours, "delay");
    }

    function _feed(address feed, uint16 jumpBps) internal view returns (OracleAdapter.FeedConfig memory) {
        return OracleAdapter.FeedConfig({
            primary: IAggregatorV3(feed),
            secondary: IAggregatorV3(address(0)),
            maxStaleness: cfg.maxStaleness,
            maxDeviationBps: 0,
            maxRoundJumpBps: jumpBps
        });
    }

    // -----------------------------------------------------------------------------------------------------------

    function _writeOutputs(address guardian, address keeper, address proposer) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "deployedAtBlock", _l2BlockNumber());
        vm.serializeUint(o, "deployedAt", block.timestamp);
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeAddress(o, "guardian", guardian);
        vm.serializeAddress(o, "keeper", keeper);
        vm.serializeAddress(o, "timelockProposer", proposer);
        vm.serializeAddress(o, "timelock", address(d.timelock));
        vm.serializeAddress(o, "oracle", address(d.oracle));
        vm.serializeAddress(o, "feeCollector", address(d.feeCollector));
        vm.serializeAddress(o, "projectTokenHooks", address(d.hooks));
        vm.serializeAddress(o, "complianceRegistry", address(d.compliance));
        vm.serializeAddress(o, "factory", address(d.factory));
        vm.serializeAddress(o, "router", address(d.router));
        vm.serializeAddress(o, "multiplierAdapter", address(d.multiplierAdapter));
        vm.serializeAddress(o, "rebaseAdapter", address(d.rebaseAdapter));
        vm.serializeAddress(o, "airdropAdapter", address(d.airdropAdapter));
        vm.serializeAddress(o, "noDividendAdapter", address(d.noDividendAdapter));
        vm.serializeAddress(o, "splitterImpl", d.splitterImpl);
        vm.serializeAddress(o, "pTokenImpl", d.pTokenImpl);
        vm.serializeAddress(o, "dTokenImpl", d.dTokenImpl);
        vm.serializeAddress(o, "ammImpl", d.ammImpl);
        string memory base = vm.serializeAddress(o, "stable", cfg.stable);
        // splice the markets array in as raw JSON (serializeString would escape it)
        bytes memory b = bytes(base);
        bytes memory head = new bytes(b.length - 1);
        for (uint256 i; i < head.length; ++i) {
            head[i] = b[i];
        }
        string memory out = string.concat(string(head), ",\"markets\":", _marketsJson(), "}");

        string memory root = vm.projectRoot();
        string memory id = vm.toString(block.chainid);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            // simulation only: never overwrite the real deployment record or the frontend config
            vm.writeFile(string.concat(root, "/../deployments/", id, ".dry-run.json"), out);
            console2.log("Dry run: wrote deployments/%s.dry-run.json (real files untouched)", id);
            return;
        }
        vm.writeFile(string.concat(root, "/../deployments/", id, ".json"), out);
        vm.writeFile(string.concat(root, "/../app/src/config/generated/deployments.", id, ".json"), out);
        console2.log("Wrote deployments/%s.json and app/src/config/generated/deployments.%s.json", id, id);
    }

    function _marketsJson() internal returns (string memory arr) {
        uint256 n = d.factory.splitterCount();
        arr = "[";
        for (uint256 i; i < n; ++i) {
            SplitterFactory.Market memory m = d.factory.market(d.factory.allSplitters(i));
            string memory k = string.concat("m", vm.toString(i));
            vm.serializeAddress(k, "stock", m.stock);
            vm.serializeString(k, "symbol", _symbolOf(m.stock));
            vm.serializeUint(k, "expiry", m.expiry);
            vm.serializeAddress(k, "splitter", m.splitter);
            vm.serializeAddress(k, "pToken", m.pToken);
            vm.serializeAddress(k, "dToken", m.dToken);
            vm.serializeAddress(k, "pPool", m.pPool);
            string memory obj = vm.serializeAddress(k, "dPool", m.dPool);
            arr = string.concat(arr, i == 0 ? "" : ",", obj);
        }
        arr = string.concat(arr, "]");
    }

    /// @dev On Arbitrum-Orbit chains `block.number` is the L1 block; ArbSys(0x64).arbBlockNumber() is the L2 block.
    ///      Local forks do not emulate ArbSys, so fall back to block.number there.
    function _l2BlockNumber() internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(100).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        if (ok && ret.length == 32) return abi.decode(ret, (uint256));
        return block.number;
    }

    function _symbolOf(address token) internal view returns (string memory) {
        for (uint256 i; i < cfg.tokens.length; ++i) {
            if (cfg.tokens[i] == token) return cfg.symbols[i];
        }
        return "";
    }
}
