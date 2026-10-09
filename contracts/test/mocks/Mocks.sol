// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only ERC-20 (also used as the MOCK project token in tests; never deployed by scripts).
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Mimics a Robinhood Chain stock token: ERC-20 + ERC-8056 multiplier + issuer oracle pause.
contract MockScaledStock is MockERC20 {
    uint256 public uiMultiplier = 1e18;
    bool public oraclePaused;

    constructor(string memory n, string memory s) MockERC20(n, s, 18) {}

    function setMultiplier(uint256 m) external {
        uiMultiplier = m;
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }
}

/// @notice Token that takes a 1% fee on transfer (to test rejection).
contract MockFeeOnTransfer is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @notice Chainlink-style feed with settable answer and round history.
contract MockFeed {
    uint8 public decimals;
    uint80 public roundId;
    mapping(uint80 => int256) public answers;
    mapping(uint80 => uint256) public updatedAts;
    uint256 public startedAtOverride;

    constructor(uint8 d, int256 answer) {
        decimals = d;
        set(answer);
    }

    function set(int256 answer) public {
        roundId++;
        answers[roundId] = answer;
        updatedAts[roundId] = block.timestamp;
    }

    function setWithTime(int256 answer, uint256 updatedAt) external {
        roundId++;
        answers[roundId] = answer;
        updatedAts[roundId] = updatedAt;
    }

    function setStartedAt(uint256 s) external {
        startedAtOverride = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 started = startedAtOverride != 0 ? startedAtOverride : updatedAts[roundId];
        return (roundId, answers[roundId], started, updatedAts[roundId], roundId);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(updatedAts[id] != 0, "no round");
        return (id, answers[id], updatedAts[id], updatedAts[id], id);
    }
}

/// @notice Airdrop distributor the splitter can pull from.
contract MockDistributor {
    IERC20 public immutable payout;

    constructor(IERC20 payout_) {
        payout = payout_;
    }

    function claim(address to, uint256 amount) external {
        payout.transfer(to, amount);
    }

    function fail() external pure {
        revert("nope");
    }
}

/// @notice Malicious distributor that tries to pull stock out of the caller.
contract EvilDistributor {
    function steal(IERC20 stock, address from, address to) external {
        stock.transferFrom(from, to, 1);
    }
}
