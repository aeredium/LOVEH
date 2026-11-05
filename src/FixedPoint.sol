// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

/// @title FixedPoint
/// @notice Fixed-point helpers. Every rounding direction is explicit at the call site.
library FixedPoint {
    /// @dev 1e18 = 100 percent.
    uint256 internal constant WAD = 1e18;
    /// @dev Prices are scaled by 1e36.
    uint256 internal constant PRICE_SCALE = 1e36;

    /// @dev x * y / d, rounded down. Reverts on overflow of x * y (checked arithmetic).
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @dev x * y / d, rounded up. Reverts on overflow of x * y (checked arithmetic).
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        uint256 p = x * y;
        if (p == 0) return 0;
        return (p - 1) / d + 1;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev a - b, floored at zero.
    function zeroFloorSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
