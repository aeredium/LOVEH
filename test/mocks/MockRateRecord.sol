// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

/// @notice A stand-in for a rate record in tests of the following formula: answers a settable highest
///         rate and a settable centre, with no checks, so the formula's own guards can be exercised.
contract MockRateRecord {
    uint256 public maxRate;
    uint256 public centre;

    constructor(uint256 maxRate_, uint256 centre_) {
        maxRate = maxRate_;
        centre = centre_;
    }

    function setMaxRate(uint256 value) external {
        maxRate = value;
    }

    function setCentre(uint256 value) external {
        centre = value;
    }
}
