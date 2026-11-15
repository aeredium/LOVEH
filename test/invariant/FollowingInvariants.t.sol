// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FollowingRateFormula} from "../../src/rates/FollowingRateFormula.sol";
import {RateRecord} from "../../src/rates/RateRecord.sol";
import {MarketInvariantsBase} from "./MarketInvariants.t.sol";
import {ReadingHandler} from "./ReadingHandler.sol";

/// @notice The existing market invariant suite, run again with the following formula in place of a
///         fixed one, while a second handler delivers random readings to the record in between the
///         market actions; plus the record's and the formula's own invariants.
contract MarketInvariantsFollowingTest is MarketInvariantsBase {
    uint256 internal constant MAX_RATE = 1e18 / YEAR;
    uint256 internal constant TARGET = 0.8e18;
    uint256 internal constant FLOOR = 0.5e18;
    uint256 internal constant FULL = 4e18;

    RateRecord internal record;
    FollowingRateFormula internal following;
    ReadingHandler internal readings;

    function _formula() internal override returns (address) {
        (address signer, uint256 signerSeed) = makeAddrAndKey("AERKey signer");
        bytes32[10] memory labels;
        for (uint256 i = 0; i < 10; ++i) {
            labels[i] = keccak256(abi.encodePacked("candidate ", i));
        }
        record = new RateRecord(labels, MAX_RATE, 0.05e18 / YEAR, signer);
        following = new FollowingRateFormula(address(record), TARGET, FLOOR, FULL);
        readings = new ReadingHandler(record, signerSeed);
        targetContract(address(readings));
        return address(following);
    }

    function invariant_centreBoundedAndNeverReverts() public view {
        assertLe(record.centre(), MAX_RATE);
        assertLe(readings.highestCentre(), MAX_RATE);
        uint256[3] memory l = record.leaders();
        assertTrue(l[0] < 10 && l[1] < 10 && l[2] < 10);
        if (record.readingCount() != 0) assertTrue(l[0] != l[1] && l[1] != l[2] && l[0] != l[2]);
    }

    /// @dev The formula answers for every utilisation, whatever the record's state, and keeps its shape.
    function invariant_ratePerSecondNeverRevertsAndKeepsItsShape() public view {
        uint256 c = record.centre();
        assertEq(following.ratePerSecond(80, 100), c, "at the target the rate is the centre");
        assertEq(following.ratePerSecond(0, 100), c * FLOOR / WAD);
        assertEq(following.ratePerSecond(100, 100), c * (WAD + FULL) / WAD);
        assertEq(following.ratePerSecond(type(uint256).max, 0), c * (WAD + FULL) / WAD);
        uint256 previous = following.ratePerSecond(0, 1);
        for (uint256 u = 5; u <= 100; u += 5) {
            uint256 rate = following.ratePerSecond(u, 100);
            assertGe(rate, previous, "rising everywhere");
            previous = rate;
        }
        assertEq(
            following.ratePerSecond(market.loans(), market.deposits()),
            following.ratePerSecond(market.loans(), market.deposits())
        );
    }

    function invariant_readingsCountSummary() public view {
        if (readings.accepted() != 0) assertGt(record.readingCount(), 0);
        assertEq(record.readingCount(), readings.accepted());
    }
}
