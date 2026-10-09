// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title PToken
/// @notice Price token: redeemable for the principal stock amount at expiry. Product token, not a project token.
/// @dev Deployed as an EIP-1167 clone per splitter; only the splitter can mint/burn.
contract PToken is ERC20PermitUpgradeable {
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
}
