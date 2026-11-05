// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";

/// @notice ERC-20 whose transfers to or from a frozen address revert (the way some stablecoins
///         behave for a blocklisted address). Anyone can freeze in this mock; it is for tests only.
contract FreezableToken is MockERC20 {
    mapping(address => bool) public frozen;

    constructor() MockERC20("Freezable Token", "FRZ", 18) {}

    function setFrozen(address account, bool value) external {
        frozen[account] = value;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        require(!frozen[from] && !frozen[to], "frozen");
        super._transfer(from, to, value);
    }
}
