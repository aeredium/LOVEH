// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {FoundationTill} from "../../src/FoundationTill.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice ERC-20 that calls back into a till during every transfer, before moving any balance, trying
///         to collect itself a second time. Made the till's beneficiary in the test, it is the one
///         caller that passes the beneficiary check, so the only thing between it and a double
///         collection is the till's guard against re-entry. Records how the inner call ended.
contract ReenteringCoin is MockERC20 {
    FoundationTill public till;
    bool public reentered;
    bool public innerSucceeded;
    bytes public innerRevert;
    bool internal inTransfer;

    constructor() MockERC20("Reentering Coin", "REEN", 18) {}

    function setTill(FoundationTill till_) external {
        till = till_;
    }

    /// @dev Collect this coin from the till, as the beneficiary.
    function drain() external {
        till.collect(address(this));
    }

    function _transfer(address from, address to, uint256 value) internal override {
        if (!inTransfer && address(till) != address(0)) {
            inTransfer = true;
            reentered = true;
            try till.collect(address(this)) {
                innerSucceeded = true;
            } catch (bytes memory reason) {
                innerRevert = reason;
            }
            inTransfer = false;
        }
        super._transfer(from, to, value);
    }
}
