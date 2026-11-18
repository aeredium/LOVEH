// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {RateRecordBase} from "./RateRecordBase.t.sol";
import {FollowingRateFormula} from "../src/rates/FollowingRateFormula.sol";
import {Utilisation} from "../src/rates/Utilisation.sol";
import {MockRateRecord} from "./mocks/MockRateRecord.sol";

/// @notice A caller that answers `lastAccrual()` as a market does, so that the formula is asked
///         from a contract with a last accrual of the test's choosing.
contract AccruingCaller {
    uint256 public lastAccrual;

    function accrueAt(uint256 t) external {
        lastAccrual = t;
    }

    function rate(FollowingRateFormula formula, uint256 loans, uint256 deposits) external view returns (uint256) {
        return formula.ratePerSecond(loans, deposits);
    }
}

/// @notice A caller whose `lastAccrual()` answers with the wrong width, which the formula must treat
///         as no answer.
contract OddCaller {
    function lastAccrual() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function rate(FollowingRateFormula formula, uint256 loans, uint256 deposits) external view returns (uint256) {
        return formula.ratePerSecond(loans, deposits);
    }
}

contract FollowingRateFormulaTest is RateRecordBase {
    uint256 internal constant TARGET = 0.8e18;
    uint256 internal constant FLOOR = 0.5e18;
    uint256 internal constant FULL = 4e18;
    /// @dev 5 percent a year.
    uint256 internal constant R = 0.05e18 / YEAR;

    FollowingRateFormula internal formula;

    function setUp() public override {
        super.setUp();
        formula = new FollowingRateFormula(address(record), TARGET, FLOOR, FULL);
    }

    /// @dev Bring the record's centre to exactly `c`: a reading at `c`, then one a whole window later,
    ///      so that the window holds nothing but `c`.
    function _setCentre(uint256 c) internal {
        uint256 t = record.readingCount() == 0 ? T0 : record.lastAsOf() + 1 hours;
        _submitAt(t, _uniform(c));
        _submitAt(t + 24 hours, _uniform(c));
        assertEq(record.centre(), c);
    }

    /// @dev The formula as written, evaluated independently.
    function _expected(uint256 c, uint256 u) internal pure returns (uint256) {
        if (u <= TARGET) return c * (FLOOR + (WAD - FLOOR) * u / TARGET) / WAD;
        return c + c * FULL * (u - TARGET) / (WAD - TARGET) / WAD;
    }

    // ------------------------------------------------------------------ construction (4)

    function test_construction() public view {
        assertEq(formula.record(), address(record));
        assertEq(formula.ceiling(), MAX_RATE, "the ceiling is the record's highest rate, read at creation");
        assertEq(formula.restingCentre(), INITIAL_CENTRE, "the resting centre is the record's initial centre");
        assertEq(formula.STALE_AFTER(), 7 days);
        assertEq(formula.targetUtilisation(), TARGET);
        assertEq(formula.floorFraction(), FLOOR);
        assertEq(formula.fullMultiple(), FULL);
    }

    function test_constructor_rejects() public {
        vm.expectRevert(FollowingRateFormula.ZeroRecord.selector);
        new FollowingRateFormula(address(0), TARGET, FLOOR, FULL);
        vm.expectRevert(FollowingRateFormula.InvalidTarget.selector);
        new FollowingRateFormula(address(record), 0, FLOOR, FULL);
        vm.expectRevert(FollowingRateFormula.InvalidTarget.selector);
        new FollowingRateFormula(address(record), WAD, FLOOR, FULL);
        vm.expectRevert(FollowingRateFormula.InvalidFloorFraction.selector);
        new FollowingRateFormula(address(record), TARGET, WAD, FULL);
        vm.expectRevert(FollowingRateFormula.ZeroMultiple.selector);
        new FollowingRateFormula(address(record), TARGET, FLOOR, 0);
        // Slope below: (1 - 0.5) / 0.8 = 0.625 centres per unit; slope above: full / 0.2.
        // full = 0.125 gives equal slopes; just above is steeper, just below is not.
        vm.expectRevert(FollowingRateFormula.SlopeAboveNotSteeper.selector);
        new FollowingRateFormula(address(record), TARGET, FLOOR, 0.125e18);
        vm.expectRevert(FollowingRateFormula.SlopeAboveNotSteeper.selector);
        new FollowingRateFormula(address(record), TARGET, FLOOR, 0.125e18 - 1);
        FollowingRateFormula steeper = new FollowingRateFormula(address(record), TARGET, FLOOR, 0.125e18 + 1);
        assertEq(steeper.fullMultiple(), 0.125e18 + 1);
        // A zero floor is allowed: no rate at zero utilisation.
        FollowingRateFormula noFloor = new FollowingRateFormula(address(record), TARGET, 0, FULL);
        assertEq(noFloor.ratePerSecond(0, 100), 0);
    }

    function test_constructor_boundsFullMultipleAgainstOverflow() public {
        uint256 room = type(uint256).max / (MAX_RATE * WAD);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(record), TARGET, FLOOR, room + 1);
        FollowingRateFormula widest = new FollowingRateFormula(address(record), TARGET, FLOOR, room);
        _setCentre(MAX_RATE);
        // The widest permitted multiple at the highest centre and full utilisation does not overflow.
        assertEq(widest.ratePerSecond(1, 1), MAX_RATE + MAX_RATE * room / WAD);
        assertEq(widest.ratePerSecond(9, 10), MAX_RATE + MAX_RATE * room * (0.9e18 - TARGET) / (WAD - TARGET) / WAD);

        // A record whose highest rate is zero or too wide for the formula is refused.
        MockRateRecord mock = new MockRateRecord(0, 1);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
        mock.setMaxRate(type(uint256).max / WAD + 1);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
        // A record whose initial centre is nothing would rest at nothing: refused.
        mock.setMaxRate(MAX_RATE);
        mock.setInitialCentre(0);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
    }

    // ------------------------------------------------------------------ shape (4, 8.13)

    function test_shape_beforeAnyReading() public view {
        uint256 c = INITIAL_CENTRE;
        assertEq(formula.ratePerSecond(80, 100), c, "at the target the rate is the centre");
        assertEq(formula.ratePerSecond(0, 100), c * FLOOR / WAD, "at zero the centre times the floor fraction");
        assertEq(formula.ratePerSecond(0, 0), c * FLOOR / WAD);
        assertEq(formula.ratePerSecond(100, 100), c * (WAD + FULL) / WAD, "at full the centre times 1 + full multiple");
        assertEq(formula.ratePerSecond(100, 0), c * (WAD + FULL) / WAD, "loans without deposits are full utilisation");
        assertEq(formula.ratePerSecond(300, 100), c * (WAD + FULL) / WAD, "capped at full utilisation");
        assertEq(formula.ratePerSecond(40, 100), _expected(c, 0.4e18));
        assertEq(formula.ratePerSecond(90, 100), _expected(c, 0.9e18));
    }

    function test_shape_followsTheCentre() public {
        _setCentre(R);
        assertEq(formula.ratePerSecond(80, 100), R);
        assertEq(formula.ratePerSecond(0, 100), R * FLOOR / WAD);
        assertEq(formula.ratePerSecond(100, 100), R * (WAD + FULL) / WAD);
        assertEq(formula.ratePerSecond(40, 100), R * (FLOOR + (WAD - FLOOR) * 0.4e18 / TARGET) / WAD);
        assertEq(formula.ratePerSecond(90, 100), R + R * FULL * (0.9e18 - TARGET) / (WAD - TARGET) / WAD);
        // The centre moves; the formula follows at once.
        _setCentre(3 * R);
        assertEq(formula.ratePerSecond(80, 100), 3 * R);
        assertEq(formula.ratePerSecond(100, 100), 3 * R * (WAD + FULL) / WAD);
    }

    function test_centreAboveCeilingIsLowered() public {
        MockRateRecord mock = new MockRateRecord(MAX_RATE, MAX_RATE + 1);
        FollowingRateFormula f = new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
        assertEq(f.ceiling(), MAX_RATE);
        assertEq(f.restingCentre(), MAX_RATE, "a resting centre above the ceiling is lowered to it at creation");
        assertEq(f.ratePerSecond(80, 100), MAX_RATE, "lowered to the ceiling");
        mock.setCentre(type(uint256).max);
        assertEq(f.ratePerSecond(80, 100), MAX_RATE);
        assertEq(f.ratePerSecond(100, 100), MAX_RATE * (WAD + FULL) / WAD);
        mock.setCentre(MAX_RATE);
        assertEq(f.ratePerSecond(80, 100), MAX_RATE, "at the ceiling itself nothing is lowered");
        // The ceiling was read once: a later change of the record's highest rate does not move it.
        mock.setMaxRate(1);
        assertEq(f.ceiling(), MAX_RATE);
        assertEq(f.ratePerSecond(80, 100), MAX_RATE);
    }

    function testFuzz_matchesTheWrittenFormula(uint256 c, uint256 loans, uint256 deposits) public {
        c = bound(c, 1, MAX_RATE);
        deposits = bound(deposits, 1, 1e40);
        loans = bound(loans, 0, deposits);
        _setCentre(c);
        uint256 u = loans * WAD / deposits;
        assertEq(formula.ratePerSecond(loans, deposits), _expected(c, u));
    }

    /// @dev The higher the utilisation, the higher the rate.
    function testFuzz_monotone(uint256 deposits, uint256 loansA, uint256 loansB) public {
        _setCentre(R);
        deposits = bound(deposits, 1, 1e40);
        loansA = bound(loansA, 0, deposits);
        loansB = bound(loansB, loansA, deposits);
        assertLe(formula.ratePerSecond(loansA, deposits), formula.ratePerSecond(loansB, deposits));
    }

    function testFuzz_strictlyIncreasingAcrossOnePercent(uint256 u) public {
        _setCentre(R);
        u = bound(u, 0, 98);
        assertLt(formula.ratePerSecond(u, 100), formula.ratePerSecond(u + 1, 100));
    }

    function testFuzz_steeperAboveTheTarget(uint256 below, uint256 above) public {
        _setCentre(R);
        below = bound(below, 0, TARGET - 1e12);
        above = bound(above, TARGET, WAD - 1e12);
        uint256 slopeBelow = formula.ratePerSecond(below + 1e12, WAD) - formula.ratePerSecond(below, WAD);
        uint256 slopeAbove = formula.ratePerSecond(above + 1e12, WAD) - formula.ratePerSecond(above, WAD);
        assertGt(slopeAbove, slopeBelow);
    }

    function testFuzz_boundedByTheCeiling(uint256 loans, uint256 deposits) public view {
        assertLe(formula.ratePerSecond(loans, deposits), MAX_RATE * (WAD + FULL) / WAD);
    }

    // ------------------------------------------------------------------ never reverts (4, 8.14)

    /// @dev Any loans, any deposits, and the record in any state: no reading, a history at the
    ///      highest rate, a random history, or a history at the highest rate gone stale.
    function testFuzz_neverReverts(uint256 loans, uint256 deposits, uint256[10] calldata seeds, uint8 state) public {
        state = uint8(bound(state, 0, 4));
        if (state == 1) {
            _setCentre(MAX_RATE);
        } else if (state == 2) {
            _submitAt(T0, _uniform(MAX_RATE));
        } else if (state == 4) {
            _setCentre(MAX_RATE);
            vm.warp(block.timestamp + 30 days);
        } else if (state == 3) {
            uint256 t = T0;
            for (uint256 n = 0; n < 4; ++n) {
                uint256[10] memory rates;
                for (uint256 i = 0; i < 10; ++i) {
                    rates[i] = bound(uint256(keccak256(abi.encode(seeds[n], i))), 0, MAX_RATE);
                }
                if (n != 0) t += bound(seeds[n], 30 minutes, 60 days);
                _submitAt(t, rates);
            }
        }
        uint256 rate = formula.ratePerSecond(loans, deposits);
        assertLe(rate, MAX_RATE * (WAD + FULL) / WAD);
        assertLe(formula.ratePerSecond(0, 0), rate);
        assertGe(formula.ratePerSecond(1, 0), rate);
    }

    function test_neverReverts_atTheEdges() public {
        _setCentre(MAX_RATE);
        uint256 top = MAX_RATE * (WAD + FULL) / WAD;
        assertEq(formula.ratePerSecond(type(uint256).max, type(uint256).max), top);
        assertEq(formula.ratePerSecond(type(uint256).max, 0), top);
        assertEq(formula.ratePerSecond(0, type(uint256).max), MAX_RATE * FLOOR / WAD);
        assertEq(formula.ratePerSecond(type(uint256).max - 1, type(uint256).max), top);
        assertEq(formula.ratePerSecond(1, type(uint256).max), MAX_RATE * FLOOR / WAD);
        uint256 half = type(uint256).max / 2;
        assertEq(
            formula.ratePerSecond(half, type(uint256).max),
            _expected(MAX_RATE, Utilisation.compute(half, type(uint256).max))
        );
        assertApproxEqAbs(formula.ratePerSecond(half, type(uint256).max), _expected(MAX_RATE, 0.5e18), 1);
    }

    // ------------------------------------------------------------------ the centre over the caller's span

    /// @dev A reading delivered while a market is idle moves the centre from the block of its
    ///      delivery: a caller that answers `lastAccrual()` as a market does is charged the mean of
    ///      the centre over the time since, not the centre as it stands.
    function test_centre_isAveragedSinceTheCallersLastAccrual() public {
        AccruingCaller caller = new AccruingCaller();
        caller.accrueAt(T0);
        // The centre moves from R to 3R at T0 + 24 hours, the block of the second reading's delivery.
        _setCentre(3 * R);
        assertEq(block.timestamp, T0 + 24 hours);
        vm.warp(T0 + 48 hours);
        assertEq(formula.ratePerSecond(80, 100), 3 * R, "asked without a last accrual: the centre as it stands");
        assertEq(caller.rate(formula, 80, 100), 2 * R, "a day at R and a day at 3R: the mean");
        assertEq(caller.rate(formula, 0, 100), 2 * R * FLOOR / WAD);
        assertEq(caller.rate(formula, 100, 100), 2 * R * (WAD + FULL) / WAD);
        assertEq(caller.rate(formula, 90, 100), _expected(2 * R, 0.9e18));
        assertEq(caller.rate(formula, 40, 100), _expected(2 * R, 0.4e18));
        // Accrued at the step itself, or after it: the new centre alone.
        caller.accrueAt(T0 + 24 hours);
        assertEq(caller.rate(formula, 80, 100), 3 * R);
        caller.accrueAt(T0 + 36 hours);
        assertEq(caller.rate(formula, 80, 100), 3 * R);
        // Accrued before the step: the mean, weighted by time.
        caller.accrueAt(T0 + 12 hours);
        assertEq(caller.rate(formula, 80, 100), (12 hours * R + 24 hours * 3 * R) / 36 hours);
        // Accrued in this block, or at a time not yet reached: the centre as it stands.
        caller.accrueAt(T0 + 48 hours);
        assertEq(caller.rate(formula, 80, 100), 3 * R);
        caller.accrueAt(T0 + 100 days);
        assertEq(caller.rate(formula, 80, 100), 3 * R);
        // Accrued before the record was made: time before its creation is not counted.
        caller.accrueAt(T0 - 10 days);
        assertEq(caller.rate(formula, 80, 100), 2 * R);
    }

    /// @dev A caller that does not answer `lastAccrual()`, or answers it with the wrong width, is
    ///      charged the centre as it stands, and nothing reverts.
    function test_centre_asItStandsWhenTheCallerDoesNotAnswer() public {
        _setCentre(3 * R);
        vm.warp(T0 + 48 hours);
        vm.prank(stranger);
        assertEq(formula.ratePerSecond(80, 100), 3 * R, "an account without code");
        OddCaller odd = new OddCaller();
        assertEq(odd.rate(formula, 80, 100), 3 * R, "an answer of the wrong width");
        assertEq(formula.ratePerSecond(80, 100), 3 * R, "a contract without the function");
    }

    /// @dev The rate is linear in the centre, so charging the mean centre over a span charges exactly
    ///      the mean of the rates the span's parts would have been charged on their own.
    function testFuzz_meanCentreGivesMeanRate(uint256 c2, uint256 loans, uint256 deposits, uint256 split) public {
        c2 = bound(c2, 1, MAX_RATE);
        deposits = bound(deposits, 1, 1e40);
        loans = bound(loans, 0, deposits);
        split = bound(split, 1, 24 hours - 1);
        AccruingCaller caller = new AccruingCaller();
        _setCentre(c2);
        uint256 stepAt = block.timestamp;
        caller.accrueAt(stepAt - split);
        vm.warp(stepAt + 1 hours);
        uint256 meanCentre = record.centreOver(stepAt - split, stepAt + 1 hours);
        assertEq(meanCentre, (split * INITIAL_CENTRE + 1 hours * c2) / (split + 1 hours));
        assertEq(caller.rate(formula, loans, deposits), _expected(meanCentre, Utilisation.compute(loans, deposits)));
    }

    // ------------------------------------------------------------------ a stale record (security reading finding 2)

    /// @dev The record's centre is a stored figure that silence leaves as it is, and before the fix
    ///      the formula charged it at any age: a last reading at a spike was charged for ever. Now a
    ///      centre whose last reading is more than STALE_AFTER old, by its `asOf`, gives way to the
    ///      resting centre until a reading is accepted again.
    function test_stale_restsAtTheInitialCentreAfterSevenDaysOfSilence() public {
        _setCentre(MAX_RATE);
        uint256 lastAsOf = record.lastAsOf();
        assertEq(formula.ratePerSecond(80, 100), MAX_RATE);

        // A week old to the second: still the record's centre.
        vm.warp(lastAsOf + 7 days);
        assertEq(formula.ratePerSecond(80, 100), MAX_RATE, "at seven days the centre is still charged");
        // One second older: the resting centre, at every utilisation, and the record is untouched.
        vm.warp(lastAsOf + 7 days + 1);
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE, "past seven days the resting centre");
        assertEq(formula.ratePerSecond(0, 100), INITIAL_CENTRE * FLOOR / WAD);
        assertEq(formula.ratePerSecond(100, 100), INITIAL_CENTRE * (WAD + FULL) / WAD);
        assertEq(formula.ratePerSecond(40, 100), _expected(INITIAL_CENTRE, 0.4e18));
        assertEq(record.centre(), MAX_RATE, "the record's own centre is what it was");
        vm.warp(lastAsOf + 365 days);
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE, "and stays at rest however long the silence");

        // A reading accepted again makes the record fresh from that block: the centre is charged once more.
        _submitAt(block.timestamp, _uniform(MAX_RATE));
        assertEq(record.centre(), MAX_RATE);
        assertEq(formula.ratePerSecond(80, 100), MAX_RATE, "fresh again");
        vm.warp(block.timestamp + 7 days);
        assertEq(formula.ratePerSecond(80, 100), MAX_RATE);
        vm.warp(block.timestamp + 1);
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE, "and stale again a week later");
    }

    /// @dev A silence at a low centre is bounded the same way: lenders are not left at nothing.
    function test_stale_restsAtTheInitialCentreFromBelowToo() public {
        _setCentre(1);
        vm.warp(record.lastAsOf() + 7 days + 1);
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE);
    }

    /// @dev Before any reading the record's last `asOf` is zero, so it is stale from the start, and the
    ///      resting centre is the initial centre the record answers anyway: the two agree.
    function test_stale_beforeAnyReadingTheRestingCentreIsTheRecordsCentre() public {
        assertEq(record.lastAsOf(), 0);
        assertEq(record.centre(), INITIAL_CENTRE);
        assertEq(formula.restingCentre(), record.centre());
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE);
        AccruingCaller caller = new AccruingCaller();
        caller.accrueAt(T0 - 30 days);
        assertEq(caller.rate(formula, 80, 100), INITIAL_CENTRE);
        // The first reading alone leaves the centre at the initial centre and makes the record fresh.
        _submitAt(T0, _uniform(MAX_RATE));
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE);
    }

    /// @dev A caller whose span crosses the moment the record went stale is charged the record's
    ///      centre for the time before it and the resting centre for the time after it.
    function test_stale_spanAcrossTheMomentOfStalenessIsChargedPiecewise() public {
        AccruingCaller caller = new AccruingCaller();
        _setCentre(3 * R);
        uint256 staleAt = record.lastAsOf() + 7 days;

        // Two days before and two days after: the mean of 3R and R, equally weighted.
        caller.accrueAt(staleAt - 2 days);
        vm.warp(staleAt + 2 days);
        assertEq(caller.rate(formula, 80, 100), 2 * R, "two days at 3R, two days at R");
        assertEq(caller.rate(formula, 100, 100), 2 * R * (WAD + FULL) / WAD);
        assertEq(caller.rate(formula, 40, 100), _expected(2 * R, 0.4e18));
        assertEq(formula.ratePerSecond(80, 100), R, "asked without a last accrual: at rest");
        // Six days before and two after: weighted by time.
        caller.accrueAt(staleAt - 6 days);
        assertEq(caller.rate(formula, 80, 100), (6 days * 3 * R + 2 days * R) / 8 days);
        // Accrued at the moment of staleness, or after it: the resting centre alone.
        caller.accrueAt(staleAt);
        assertEq(caller.rate(formula, 80, 100), R);
        caller.accrueAt(staleAt + 1 days);
        assertEq(caller.rate(formula, 80, 100), R);
        // A span that ends at or before the moment of staleness is untouched by it.
        vm.warp(staleAt);
        caller.accrueAt(staleAt - 2 days);
        assertEq(caller.rate(formula, 80, 100), 3 * R);
        vm.warp(staleAt - 1);
        assertEq(caller.rate(formula, 80, 100), 3 * R);
        // A span across the change of the centre and across the moment of staleness: the checkpoints
        // before, the resting centre after.
        vm.warp(staleAt + 1 days);
        caller.accrueAt(T0);
        // The centre moved from R to 3R at T0 + 24 hours; it went stale 7 days after that. The mean
        // up to that moment is the record's, rounded down, and the resting centre is weighed in after.
        assertEq(staleAt, T0 + 24 hours + 7 days);
        uint256 before = record.centreOver(T0, staleAt);
        assertEq(before, (1 days * R + 7 days * 3 * R) / 8 days);
        assertEq(caller.rate(formula, 80, 100), (before * 8 days + 1 days * R) / 9 days);
    }

    /// @dev The mock's clock: a stand-in that answers a last reading in the past is at rest like the
    ///      real record, and its resting centre is lowered to the ceiling.
    function test_stale_withTheMockRecord() public {
        MockRateRecord mock = new MockRateRecord(MAX_RATE, 3 * R);
        mock.setInitialCentre(MAX_RATE + 1);
        FollowingRateFormula f = new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
        assertEq(f.restingCentre(), MAX_RATE);
        assertEq(f.ratePerSecond(80, 100), 3 * R, "fresh at creation");
        vm.warp(T0 + 7 days + 1);
        assertEq(f.ratePerSecond(80, 100), MAX_RATE, "stale: the resting centre");
        mock.setLastAsOf(_u64(block.timestamp));
        assertEq(f.ratePerSecond(80, 100), 3 * R, "fresh again");
    }
}
