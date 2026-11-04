// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRateFormula
/// @notice A stateless formula giving the per-second borrowing rate of a market from its utilisation.
/// @dev Utilisation is loans divided by deposits. The rate is a fixed-point number scaled by 1e18:
///      a value of 1e18 means 100 percent per second. The higher the utilisation, the higher the rate.
interface IRateFormula {
    /// @notice The per-second rate, scaled by 1e18, for a market with these loans and deposits.
    /// @param loans Loan token lent out, including interest owed.
    /// @param deposits Loan token deposited, including interest earned.
    function ratePerSecond(uint256 loans, uint256 deposits) external view returns (uint256);
}
