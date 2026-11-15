// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IRateFormula} from "../../interfaces/IRateFormula.sol";
import {RateRecord} from "./RateRecord.sol";
import {Utilisation} from "./Utilisation.sol";

/// @title FollowingRateFormula
/// @notice A kinked formula whose level follows a rate record. With `c` the record's centre (lowered
///         to the ceiling if above it), `u` the utilisation and every figure scaled by 1e18:
///           u <= target:  rate = c * (floorFraction + (1e18 - floorFraction) * u / target) / 1e18
///           u >  target:  rate = c + c * fullMultiple * (u - target) / (1e18 - target) / 1e18
///         The rate at the target is the centre, at zero utilisation the centre times the floor
///         fraction, at full utilisation the centre times one plus the full multiple; it rises with
///         utilisation everywhere and the slope above the target is strictly steeper than below it.
///         Every parameter is fixed at deployment. `ratePerSecond` never reverts.
contract FollowingRateFormula is IRateFormula {
    error ZeroRecord();
    error InvalidTarget();
    error InvalidFloorFraction();
    error ZeroMultiple();
    error SlopeAboveNotSteeper();
    error BadConfig();

    uint256 internal constant WAD = 1e18;

    /// @notice The rate record whose centre this formula follows.
    address public immutable record;
    /// @notice The record's highest rate, read once at creation; a centre above it is lowered to it.
    uint256 public immutable ceiling;
    /// @notice The utilisation at which the rate is exactly the centre, scaled by 1e18, strictly between 0 and 1e18.
    uint256 public immutable targetUtilisation;
    /// @notice The fraction of the centre charged at zero utilisation, scaled by 1e18, below 1e18.
    uint256 public immutable floorFraction;
    /// @notice How many centres are added between the target and full utilisation, scaled by 1e18, above zero.
    uint256 public immutable fullMultiple;

    constructor(address record_, uint256 targetUtilisation_, uint256 floorFraction_, uint256 fullMultiple_) {
        if (record_ == address(0)) revert ZeroRecord();
        if (targetUtilisation_ == 0 || targetUtilisation_ >= WAD) revert InvalidTarget();
        if (floorFraction_ >= WAD) revert InvalidFloorFraction();
        if (fullMultiple_ == 0) revert ZeroMultiple();
        // Slope below the target, per unit of utilisation: (1e18 - floor) / target centres.
        // Slope above it: fullMultiple / (1e18 - target) centres. Above must be strictly steeper:
        // fullMultiple * target > (1e18 - floor) * (1e18 - target), compared without overflow.
        if (fullMultiple_ <= (WAD - floorFraction_) * (WAD - targetUtilisation_) / targetUtilisation_) {
            revert SlopeAboveNotSteeper();
        }
        uint256 ceiling_ = RateRecord(record_).maxRate();
        // The largest product the formula forms is c * fullMultiple * (u - target) with c at most the
        // ceiling and u - target below 1e18, so ceiling * fullMultiple * 1e18 must fit; then so does
        // ceiling * (1e18 + fullMultiple), the rate at full utilisation times 1e18.
        if (ceiling_ == 0 || ceiling_ > type(uint256).max / WAD) revert BadConfig();
        if (fullMultiple_ > type(uint256).max / (ceiling_ * WAD)) revert BadConfig();

        record = record_;
        ceiling = ceiling_;
        targetUtilisation = targetUtilisation_;
        floorFraction = floorFraction_;
        fullMultiple = fullMultiple_;
    }

    /// @inheritdoc IRateFormula
    function ratePerSecond(uint256 loans, uint256 deposits) external view returns (uint256) {
        uint256 u = Utilisation.compute(loans, deposits);
        uint256 c = RateRecord(record).centre();
        if (c > ceiling) c = ceiling;
        if (u <= targetUtilisation) {
            return c * (floorFraction + (WAD - floorFraction) * u / targetUtilisation) / WAD;
        }
        return c + c * fullMultiple * (u - targetUtilisation) / (WAD - targetUtilisation) / WAD;
    }
}
