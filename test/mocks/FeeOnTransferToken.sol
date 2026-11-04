// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";

/// @notice ERC-20 that burns a fee, in basis points, from every transfer so the receiver gets less
///         than the amount sent.
contract FeeOnTransferToken is MockERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) MockERC20("Fee Token", "FEE", 18) {
        require(feeBps_ < 10_000, "fee");
        feeBps = feeBps_;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        require(balanceOf[from] >= value, "balance");
        uint256 fee = (value * feeBps) / 10_000;
        balanceOf[from] -= value;
        balanceOf[to] += value - fee;
        totalSupply -= fee;
        emit Transfer(from, to, value - fee);
    }
}
