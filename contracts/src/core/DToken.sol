// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

interface IDTokenHook {
    function onDTokenTransfer(address from, address to) external;
}

/// @title DToken
/// @notice Dividend token: entitles the holder to every dividend the splitter captures until the dividend cutoff.
///         Product token, not a project token. Worthless after the cutoff except for already-accrued dividends.
/// @dev Every balance change first checkpoints both parties in the splitter's accumulator, so accrued dividends stay
///      with the account that held the D token when they were captured.
contract DToken is ERC20PermitUpgradeable {
    address public splitter;
    uint8 private _decimals;

    error OnlySplitter();

    constructor() {
        _disableInitializers();
    }

    function initialize(address splitter_, string calldata name_, string calldata symbol_, uint8 decimals_)
        external
        initializer
    {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        splitter = splitter_;
        _decimals = decimals_;
    }

    modifier onlySplitter() {
        if (msg.sender != splitter) revert OnlySplitter();
        _;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlySplitter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlySplitter {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        IDTokenHook(splitter).onDTokenTransfer(from, to);
        super._update(from, to, value);
    }
}
