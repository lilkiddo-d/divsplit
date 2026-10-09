// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IDividendAdapter} from "../interfaces/IDividendAdapter.sol";

/// @title AirdropDividendAdapter
/// @notice For stock tokens whose issuer pays cash dividends by sending (or letting holders claim) a stablecoin.
/// @dev Per-stock configuration (payout token and optional claim distributor) is owned by the Timelock.
///      Received payout tokens are measured by the splitter as `balance - reserved` and distributed to D holders.
///      Because airdrops are snapshot-based, keepers should announce ex-date blackouts on the splitter.
contract AirdropDividendAdapter is IDividendAdapter, Ownable2Step {
    bytes32 public constant MECHANISM = keccak256("AIRDROP");

    struct Config {
        address payout;
        address distributor;
    }

    mapping(address stock => Config) public configs;

    event StockConfigured(address indexed stock, address indexed payout, address indexed distributor);

    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    function configure(address stock, address payout, address distributor) external onlyOwner {
        if (stock == address(0) || payout == address(0) || payout == stock) revert ZeroAddress();
        configs[stock] = Config(payout, distributor);
        emit StockConfigured(stock, payout, distributor);
    }

    function mechanism() external pure returns (bytes32) {
        return MECHANISM;
    }

    function payoutToken(address stock) external view returns (address) {
        return configs[stock].payout;
    }

    function initialState(address) external pure returns (uint256) {
        return 0;
    }

    function claimTarget(address stock) external view returns (address) {
        return configs[stock].distributor;
    }

    function assess(address, uint256 scale, uint256 state, uint256) external pure returns (Assessment memory a) {
        a.newScale = scale;
        a.newState = state;
    }
}
