// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "./Deploy.s.sol";
import {SplitterFactory} from "../src/core/SplitterFactory.sol";
import {Splitter} from "../src/core/Splitter.sol";
import {TimeDecayAMM} from "../src/amm/TimeDecayAMM.sol";

interface IMulticall3 {
    function getBlockNumber() external view returns (uint256);
}

/// @title ForkAll
/// @notice LOCAL ANVIL FORK ONLY. Runs the production Deploy script unchanged, then funds the broadcaster with stock
///         tokens and USDG (anvil_setStorageAt via vm.rpc; balance slots found with forge-std stdstore) and seeds every
///         P and D pool with liquidity plus a few trades. Everything happens in ONE forge invocation because the public
///         Robinhood Chain RPC is not an archive node: a fork's upstream state is pruned within minutes.
///         Usage: forge script script/ForkAll.s.sol --sig "runFork()" --rpc-url http://127.0.0.1:8555 \
///                  --unlocked --sender <address> --broadcast
contract ForkAll is Deploy {
    using stdStorage for StdStorage;

    address constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    function runFork() external {
        require(block.chainid == 4663, "fork of chain 4663 expected");
        run();
        // touch Multicall3 so the frontend's batched reads are served from the fork cache
        IMulticall3(MULTICALL3).getBlockNumber();
        _fund(cfg.stable, 10_000_000e6);
        for (uint256 i; i < cfg.tokens.length; ++i) {
            _fund(cfg.tokens[i], 1_000e18);
        }
        _seed();
    }

    function _fund(address token, uint256 amount) internal {
        uint256 slot = stdstore.target(token).sig("balanceOf(address)").with_key(deployer).find();
        vm.store(token, bytes32(slot), bytes32(amount)); // local simulation
        string memory params = string.concat(
            "[\"", vm.toString(token), "\",\"", vm.toString(bytes32(slot)), "\",\"", vm.toString(bytes32(amount)), "\"]"
        );
        vm.rpc("anvil_setStorageAt", params); // the fork node itself
        require(IERC20(token).balanceOf(deployer) == amount, "funding failed");
    }

    function _seed() internal {
        SplitterFactory factory = d.factory;
        IERC20 stable = IERC20(cfg.stable);
        uint256 n = factory.splitterCount();
        uint256 dl = block.timestamp + 1 hours;
        vm.startBroadcast();
        for (uint256 i; i < n; ++i) {
            SplitterFactory.Market memory m = factory.market(factory.allSplitters(i));
            Splitter s = Splitter(m.splitter);
            TimeDecayAMM pPool = TimeDecayAMM(m.pPool);
            TimeDecayAMM dPool = TimeDecayAMM(m.dPool);
            IERC20(m.stock).approve(address(s), type(uint256).max);
            s.split(20e18, deployer);
            uint256 unitPrice = pPool.unitPrice(); // USDG wad per P+D pair
            IERC20(m.pToken).approve(address(pPool), type(uint256).max);
            IERC20(m.dToken).approve(address(dPool), type(uint256).max);
            stable.approve(address(pPool), type(uint256).max);
            stable.approve(address(dPool), type(uint256).max);
            pPool.addLiquidity(8e18, (8 * unitPrice) / 1e12, 0, deployer, dl);
            dPool.addLiquidity(8e18, (8 * unitPrice) / 1e12 / 10, 0, deployer, dl);
            dPool.swapStableForExactToken(0.4e18, type(uint256).max, deployer, dl);
            pPool.swapExactTokenForStable(0.2e18, 0, deployer, dl);
            dPool.swapExactTokenForStable(0.1e18, 0, deployer, dl);
        }
        vm.stopBroadcast();
        console2.log("Seeded markets:", n);
    }
}
