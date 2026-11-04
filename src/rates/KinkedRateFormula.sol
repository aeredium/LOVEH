// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IRateFormula} from "../../interfaces/IRateFormula.sol";
import {Utilisation} from "./Utilisation.sol";

/// @title KinkedRateFormula
/// @notice One slope below a target utilisation and a steeper slope above it:
///         rate = baseRate + slopeBelow * min(u, target) + slopeAbove * max(u - target, 0).
///         Stateless; every parameter is fixed at deployment.
contract KinkedRateFormula is IRateFormula {
    error ZeroSlope();
    error SlopeAboveNotSteeper();
    error InvalidTarget();

    uint256 internal constant WAD = 1e18;

    /// @notice Per-second rate at zero utilisation, scaled by 1e18.
    uint256 public immutable baseRate;
    /// @notice Per-second rate added per unit of utilisation below the target, scaled by 1e18.
    uint256 public immutable slopeBelow;
    /// @notice Per-second rate added per unit of utilisation above the target, scaled by 1e18.
    uint256 public immutable slopeAbove;
    /// @notice The utilisation at which the slope changes, scaled by 1e18, strictly between 0 and 1e18.
    uint256 public immutable targetUtilisation;

    constructor(uint256 baseRate_, uint256 slopeBelow_, uint256 slopeAbove_, uint256 targetUtilisation_) {
        if (slopeBelow_ == 0) revert ZeroSlope();
        if (slopeAbove_ <= slopeBelow_) revert SlopeAboveNotSteeper();
        if (targetUtilisation_ == 0 || targetUtilisation_ >= WAD) revert InvalidTarget();
        baseRate = baseRate_;
        slopeBelow = slopeBelow_;
        slopeAbove = slopeAbove_;
        targetUtilisation = targetUtilisation_;
    }

    /// @inheritdoc IRateFormula
    function ratePerSecond(uint256 loans, uint256 deposits) external view returns (uint256) {
        uint256 u = Utilisation.compute(loans, deposits);
        if (u <= targetUtilisation) {
            return baseRate + (slopeBelow * u) / WAD;
        }
        return baseRate + (slopeBelow * targetUtilisation) / WAD + (slopeAbove * (u - targetUtilisation)) / WAD;
    }
}
