// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IRateFormula} from "../../interfaces/IRateFormula.sol";
import {Utilisation} from "./Utilisation.sol";

/// @title LinearRateFormula
/// @notice rate = baseRate + slope * utilisation. Stateless; every parameter is fixed at deployment.
contract LinearRateFormula is IRateFormula {
    error ZeroSlope();

    uint256 internal constant WAD = 1e18;

    /// @notice Per-second rate at zero utilisation, scaled by 1e18.
    uint256 public immutable baseRate;
    /// @notice Per-second rate added at full utilisation, scaled by 1e18.
    uint256 public immutable slope;

    constructor(uint256 baseRate_, uint256 slope_) {
        if (slope_ == 0) revert ZeroSlope();
        baseRate = baseRate_;
        slope = slope_;
    }

    /// @inheritdoc IRateFormula
    function ratePerSecond(uint256 loans, uint256 deposits) external view returns (uint256) {
        uint256 u = Utilisation.compute(loans, deposits);
        return baseRate + (slope * u) / WAD;
    }
}
