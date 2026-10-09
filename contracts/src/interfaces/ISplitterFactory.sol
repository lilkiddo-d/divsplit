// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDividendAdapter} from "./IDividendAdapter.sol";
import {IOracleAdapter} from "./IOracleAdapter.sol";

interface ISplitterFactory {
    struct StockConfig {
        bool listed;
        IDividendAdapter adapter;
        uint16 maxDividendBps; // per-harvest change above this is treated as a corporate action
        uint32 trailingWindow; // seconds after expiry during which D still receives dividends
        int256 scalarRoot; // P-pool curve flatness (wad); implied-rate move per logit unit ~= 1/scalarRoot
        int256 scalarRootD; // D-pool curve flatness (wad); D is a leveraged rate claim so this is ~5-10x larger
        int256 initialAnchor; // AMM opening rate: 1 + annual implied dividend yield (wad, >= 1e18)
    }

    function stockConfig(address stock) external view returns (StockConfig memory);
    function oracle() external view returns (IOracleAdapter);
    function stable() external view returns (address);
    function feeCollector() external view returns (address);
    function swapFeeBps() external view returns (uint16);
    function protocolFeeShareBps() external view returns (uint16);
    function globalPaused() external view returns (bool);
    function isAdmin(address account) external view returns (bool);
    function isGuardian(address account) external view returns (bool);
    function isKeeper(address account) external view returns (bool);
    function checkCompliance(address account, bytes32 action) external view;
}
