// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPriceSource
/// @notice The price of one unit of a market's collateral token, in loan-token units, scaled by 1e36.
/// @dev A market reads only its own price source. A price of zero, or a call that fails, refuses
///      borrowing and collateral withdrawal in that market; it never permits a liquidation by itself.
interface IPriceSource {
    /// @notice Price of one unit (the smallest denomination) of collateral, in the smallest denomination
    ///         of the loan token, multiplied by 1e36.
    function price() external view returns (uint256);
}
