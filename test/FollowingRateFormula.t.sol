// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {RateRecordBase} from "./RateRecordBase.t.sol";
import {FollowingRateFormula} from "../src/rates/FollowingRateFormula.sol";
import {Utilisation} from "../src/rates/Utilisation.sol";
import {MockRateRecord} from "./mocks/MockRateRecord.sol";

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
    ///      highest rate, or a random history.
    function testFuzz_neverReverts(uint256 loans, uint256 deposits, uint256[10] calldata seeds, uint8 state) public {
        state = uint8(bound(state, 0, 3));
        if (state == 1) {
            _setCentre(MAX_RATE);
        } else if (state == 2) {
            _submitAt(T0, _uniform(MAX_RATE));
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
}
