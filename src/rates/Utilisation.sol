// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

/// @title Utilisation
/// @notice Loans divided by deposits, scaled by 1e18 and capped at 1e18. Never reverts.
library Utilisation {
    uint256 internal constant WAD = 1e18;

    function compute(uint256 loans, uint256 deposits) internal pure returns (uint256) {
        if (loans == 0) return 0;
        if (loans >= deposits) return WAD;
        if (loans <= type(uint256).max / WAD) return (loans * WAD) / deposits;
        // Absurdly large figures: scale both down rather than overflow. deposits > loans > 2^196 here,
        // so the shifted divisor is never zero.
        return ((loans >> 64) * WAD) / (deposits >> 64);
    }
}
