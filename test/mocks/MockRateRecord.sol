// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

/// @notice A stand-in for a rate record in tests of the following formula: answers a settable highest
///         rate, a settable centre (over any span too), a settable time of its last reading (this
///         block at creation, so that it starts fresh) and an initial centre, with no checks, so the
///         formula's own guards can be exercised.
contract MockRateRecord {
    uint256 public maxRate;
    uint256 public centre;
    uint256 public initialCentre;
    uint64 public lastAsOf;

    constructor(uint256 maxRate_, uint256 centre_) {
        maxRate = maxRate_;
        centre = centre_;
        initialCentre = centre_;
        // casting to 'uint64' is safe because the tests' clock never leaves the uint64 range
        // forge-lint: disable-next-line(unsafe-typecast)
        lastAsOf = uint64(block.timestamp);
    }

    function setMaxRate(uint256 value) external {
        maxRate = value;
    }

    function setCentre(uint256 value) external {
        centre = value;
    }

    function setInitialCentre(uint256 value) external {
        initialCentre = value;
    }

    function setLastAsOf(uint64 value) external {
        lastAsOf = value;
    }

    /// @dev The centre, whatever the span: the stand-in keeps no history.
    function centreOver(uint256, uint256) external view returns (uint256) {
        return centre;
    }
}
