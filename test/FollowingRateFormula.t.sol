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

/// @notice Records of the wrong shape, each missing one thing the formula reads: a bare contract that
///         answers only `maxRate()` and `initialCentre()`, one without `centreOver`, one without
///         `lastAsOf`, and one whose `centreOver` answers with the wrong width.
contract BareRecord {
    uint256 public maxRate;
    uint256 public initialCentre;

    constructor(uint256 maxRate_) {
        maxRate = maxRate_;
        initialCentre = maxRate_;
    }
}

contract RecordWithoutCentreOver is BareRecord {
    uint256 public centre;
    uint64 public lastAsOf;

    constructor(uint256 maxRate_) BareRecord(maxRate_) {
        centre = maxRate_;
    }
}

contract RecordWithoutLastAsOf is BareRecord {
    uint256 public centre;

    constructor(uint256 maxRate_) BareRecord(maxRate_) {
        centre = maxRate_;
    }

    function centreOver(uint256, uint256) external view returns (uint256) {
        return centre;
    }
}

contract RecordWithAWideCentreOver is RecordWithoutCentreOver {
    constructor(uint256 maxRate_) RecordWithoutCentreOver(maxRate_) {}

    function centreOver(uint256, uint256) external view returns (uint256, uint256) {
        return (centre, centre);
    }
}

/// @notice A record of the old shape: everything but the staleness figure.
contract RecordWithoutStaleAfter is RecordWithoutCentreOver {
    constructor(uint256 maxRate_) RecordWithoutCentreOver(maxRate_) {}

    function centreOver(uint256, uint256) external view returns (uint256) {
        return centre;
    }
}

/// @notice A record that answers as a record at creation and changes afterwards: it can be made to
///         revert, to answer with the wrong width, to answer a last reading no genuine record can
///         name (security reading finding 2, fourth reading), to answer a block of zeros sized to
///         spend most of the gas it is given, or to burn every unit of gas it is given and answer
///         nothing (security reading finding 1, fifth reading). `lastAsOf` is declared a word wide
///         so that it can answer beyond a uint64; the selector is the same.
contract RecordThatChangesLater {
    enum Mode {
        Answers,
        Reverts,
        WrongWidth,
        Oversized,
        Burns
    }

    uint256 public maxRate;
    uint256 public initialCentre;
    uint256 public STALE_AFTER = 7 days;
    Mode public mode;
    uint256 internal _centre;
    uint256 internal _lastAsOf;

    constructor(uint256 maxRate_, uint256 centre_, uint256 initialCentre_) {
        maxRate = maxRate_;
        initialCentre = initialCentre_;
        _centre = centre_;
        _lastAsOf = block.timestamp;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setCentre(uint256 value) external {
        _centre = value;
    }

    function setLastAsOf(uint256 value) external {
        _lastAsOf = value;
    }

    function centre() external view returns (uint256) {
        return _answer(_centre);
    }

    function lastAsOf() external view returns (uint256) {
        return _answer(_lastAsOf);
    }

    function centreOver(uint256, uint256) external view returns (uint256) {
        return _answer(_centre);
    }

    function _answer(uint256 word) internal view returns (uint256) {
        if (mode == Mode.Reverts) revert("the record no longer answers");
        if (mode == Mode.WrongWidth) {
            // Two words where one is expected.
            assembly {
                mstore(0, word)
                mstore(32, word)
                return(0, 64)
            }
        }
        if (mode == Mode.Oversized) {
            // A block of zeros whose width alone costs nine tenths of the gas on hand: w words of
            // memory cost 3w + w^2 / 512, so w = 256 (sqrt(9 + g / 128) - 3) words cost g. Whoever
            // copies the answer pays about as much again.
            uint256 w = 256 * (_sqrt(9 + gasleft() * 9 / 10 / 128) - 3);
            assembly {
                return(0, mul(w, 32))
            }
        }
        if (mode == Mode.Burns) {
            // Every unit of gas it was given, and no answer.
            assembly {
                for {} 1 {} {}
            }
        }
        return word;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
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
        assertEq(formula.STALE_AFTER(), record.STALE_AFTER(), "the record rests its history at the same figure");
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
        // The ceiling is bounded below 2^192 by the formula itself, as a genuine record's highest
        // rate is, so the piecewise pricing of a span across the moment of staleness cannot overflow
        // whatever the record (security reading finding 2, fourth reading). A multiple of one with a
        // floor and a target a hair below one is steep enough, and leaves room for such a ceiling.
        mock.setMaxRate(uint256(type(uint192).max) + 1);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(mock), WAD - 1, WAD - 1, 1);
        mock.setMaxRate(type(uint192).max);
        FollowingRateFormula atTheWidth = new FollowingRateFormula(address(mock), WAD - 1, WAD - 1, 1);
        assertEq(atTheWidth.ceiling(), type(uint192).max);
        // A record whose initial centre is nothing would rest at nothing: refused.
        mock.setMaxRate(MAX_RATE);
        mock.setInitialCentre(0);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
    }

    /// @dev Security reading finding 4. The constructor once checked the record by `maxRate()` alone,
    ///      so a contract of another shape passed creation and `ratePerSecond` reverted for every
    ///      market on the formula. Now the constructor asks the record everything the formula will
    ///      ask, once, and refuses a record that does not answer each with one word.
    function test_constructor_refusesARecordThatDoesNotAnswerAsARecord() public {
        BareRecord bare = new BareRecord(MAX_RATE);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(bare), TARGET, FLOOR, FULL);

        RecordWithoutCentreOver noCentreOver = new RecordWithoutCentreOver(MAX_RATE);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(noCentreOver), TARGET, FLOOR, FULL);

        RecordWithoutLastAsOf noLastAsOf = new RecordWithoutLastAsOf(MAX_RATE);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(noLastAsOf), TARGET, FLOOR, FULL);

        RecordWithAWideCentreOver wide = new RecordWithAWideCentreOver(MAX_RATE);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(wide), TARGET, FLOOR, FULL);

        RecordWithoutStaleAfter noStaleAfter = new RecordWithoutStaleAfter(MAX_RATE);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(noStaleAfter), TARGET, FLOOR, FULL);

        // An account without code answers nothing at all.
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(stranger, TARGET, FLOOR, FULL);

        // A record that answers everything but rests its history at another figure than the formula
        // prices an open silence at is refused: the two must be the same figure.
        MockRateRecord mock = new MockRateRecord(MAX_RATE, R);
        mock.setStaleAfter(7 days - 1);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
        mock.setStaleAfter(7 days + 1);
        vm.expectRevert(FollowingRateFormula.BadConfig.selector);
        new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
        mock.setStaleAfter(7 days);

        // A record that answers everything is accepted, and a market on it is answered over its span.
        FollowingRateFormula f = new FollowingRateFormula(address(mock), TARGET, FLOOR, FULL);
        AccruingCaller caller = new AccruingCaller();
        caller.accrueAt(T0 - 1 days);
        assertEq(caller.rate(f, 80, 100), R);
        assertEq(f.ratePerSecond(80, 100), R);
    }

    /// @dev Security reading finding 2 (fourth reading). The constructor asks the record once, so a
    ///      record that answered at creation and changed afterwards passed it, and before the fix
    ///      `ratePerSecond` read the record by plain calls, which reverted with it: a record that
    ///      reverted, lost its code, or answered a last reading wider than a uint64 stopped every
    ///      market on the formula. Now the record is read by guarded static calls, and a record that
    ///      does not answer as a record, with one word, is charged as a stale one, at the resting
    ///      centre, until it answers again; nothing reverts.
    function test_aRecordThatStopsAnsweringIsChargedAtTheRestingCentre() public {
        RecordThatChangesLater changing = new RecordThatChangesLater(MAX_RATE, 3 * R, R);
        FollowingRateFormula f = new FollowingRateFormula(address(changing), TARGET, FLOOR, FULL);
        assertEq(f.restingCentre(), R);
        AccruingCaller caller = new AccruingCaller();
        caller.accrueAt(T0 - 1 days);
        assertEq(f.ratePerSecond(80, 100), 3 * R, "the record answers: its centre");
        assertEq(caller.rate(f, 80, 100), 3 * R, "and its centre over the caller's span");

        // The record reverts. Before the fix both of these reverted with it.
        changing.setMode(RecordThatChangesLater.Mode.Reverts);
        assertEq(f.ratePerSecond(80, 100), R, "a record that reverts: the resting centre");
        assertEq(caller.rate(f, 80, 100), R, "over the caller's span too");
        assertEq(f.ratePerSecond(0, 100), R * FLOOR / WAD, "the shape is kept");
        assertEq(f.ratePerSecond(100, 100), R * (WAD + FULL) / WAD);
        assertEq(caller.rate(f, 40, 100), _expected(R, 0.4e18));

        // The record answers with the wrong width.
        changing.setMode(RecordThatChangesLater.Mode.WrongWidth);
        assertEq(f.ratePerSecond(80, 100), R, "a record that answers two words: the resting centre");
        assertEq(caller.rate(f, 80, 100), R);

        // The record answers again: its centre is charged once more.
        changing.setMode(RecordThatChangesLater.Mode.Answers);
        assertEq(f.ratePerSecond(80, 100), 3 * R, "answering again: its centre");
        assertEq(caller.rate(f, 80, 100), 3 * R);

        // The record answers a last reading wider than any `asOf` a record can store: no record's
        // answer, so the resting centre. Before the fix the plain call refused to decode it.
        changing.setLastAsOf(type(uint256).max);
        assertEq(f.ratePerSecond(80, 100), R, "a last reading no record can name: the resting centre");
        assertEq(caller.rate(f, 80, 100), R);
        changing.setLastAsOf(uint256(type(uint64).max));
        assertEq(f.ratePerSecond(80, 100), 3 * R, "the widest a record can name is fresh");
        changing.setLastAsOf(block.timestamp - 8 days);
        assertEq(f.ratePerSecond(80, 100), R, "and one eight days old is stale");
        changing.setLastAsOf(block.timestamp);

        // The record's `centreOver` answers above the ceiling: lowered, over a span and across the
        // moment of staleness alike, so nothing overflows.
        changing.setCentre(type(uint256).max);
        assertEq(caller.rate(f, 80, 100), MAX_RATE, "a mean above the ceiling is lowered to it");
        assertEq(f.ratePerSecond(80, 100), MAX_RATE);
        changing.setLastAsOf(block.timestamp - 7 days - 1 days);
        caller.accrueAt(block.timestamp - 2 days);
        uint256 acrossTheMoment = (1 days * MAX_RATE + 1 days * R) / 2 days;
        assertEq(caller.rate(f, 80, 100), acrossTheMoment, "a day at the ceiling, a day at rest");
        changing.setMode(RecordThatChangesLater.Mode.Reverts);
        assertEq(caller.rate(f, 80, 100), R, "the same span with a record that reverts: at rest throughout");
        changing.setMode(RecordThatChangesLater.Mode.Answers);
        changing.setCentre(3 * R);
        changing.setLastAsOf(block.timestamp);
        caller.accrueAt(T0 - 1 days);

        // The record loses its code. Before the fix a plain call to an account without code reverted.
        vm.etch(address(changing), hex"");
        assertEq(address(changing).code.length, 0);
        assertEq(f.ratePerSecond(80, 100), R, "a record without code: the resting centre");
        assertEq(caller.rate(f, 80, 100), R);
        assertEq(f.ratePerSecond(100, 100), R * (WAD + FULL) / WAD);

        // A genuine record on a formula is read the same way, and answers as before.
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE);
        _setCentre(3 * R);
        assertEq(formula.ratePerSecond(80, 100), 3 * R);
        caller.accrueAt(T0);
        vm.warp(T0 + 48 hours);
        assertEq(caller.rate(formula, 80, 100), 2 * R, "a day at R and a day at 3R, through the guarded calls");
    }

    /// @dev Security reading finding 1 (fifth reading). The guarded reads forwarded all their gas and
    ///      copied the whole answer before comparing its width with one word, so a record that
    ///      answered a block of zeros sized to spend most of the gas it was given left the formula
    ///      with a sixty-fourth of it and about the same memory bill again: `ratePerSecond` ran out
    ///      of gas, and every market on the formula with it. A record that merely burned its gas left
    ///      the caller a sixty-fourth of what it supplied. Now each read is given `ASK_GAS` and no
    ///      more, and nothing is copied until the answer is known to be one word: an answer of any
    ///      other width, however wide, is no answer, and a record that burns its gas or spends it on
    ///      width costs the caller the allowance per read and nothing else.
    function test_aRecordThatAnswersWideOrBurnsItsGasDoesNotMakeTheFormulaRevert() public {
        RecordThatChangesLater changing = new RecordThatChangesLater(MAX_RATE, 3 * R, R);
        FollowingRateFormula f = new FollowingRateFormula(address(changing), TARGET, FLOOR, FULL);
        AccruingCaller caller = new AccruingCaller();
        caller.accrueAt(T0 - 1 days);
        assertEq(f.ratePerSecond(80, 100), 3 * R, "the record answers: its centre");
        assertEq(caller.rate(f, 80, 100), 3 * R);

        // The record answers `lastAsOf()` with a block of zeros sized to its gas. Before the fix both
        // of these ran out of gas while copying the answer; now the answer is not copied, and a
        // record that does not answer with one word is at rest.
        changing.setMode(RecordThatChangesLater.Mode.Oversized);
        assertEq(f.ratePerSecond{gas: 1_000_000}(80, 100), R, "an oversized answer: the resting centre");
        assertEq(caller.rate{gas: 1_000_000}(f, 80, 100), R, "over the caller's span too");
        assertEq(f.ratePerSecond(80, 100), R, "with whatever gas the caller has");
        assertEq(f.ratePerSecond(0, 100), R * FLOOR / WAD, "the shape is kept");
        assertEq(f.ratePerSecond(100, 100), R * (WAD + FULL) / WAD);
        assertEq(caller.rate(f, 40, 100), _expected(R, 0.4e18));

        // The record burns every unit of gas it is given. Before the fix it was given all but a
        // sixty-fourth of what the caller had; now it is given the allowance and no more, so a touch
        // of a market costs the allowance over its usual price, not sixty-three times that price.
        changing.setMode(RecordThatChangesLater.Mode.Burns);
        uint256 before = gasleft();
        uint256 rate = f.ratePerSecond{gas: 1_000_000}(80, 100);
        uint256 spent = before - gasleft();
        assertEq(rate, R, "a record that burns its gas: the resting centre");
        assertGt(spent, 200_000, "the read's whole allowance was burnt");
        assertLt(spent, 300_000, "and nothing beyond the allowance and the formula's own work");
        before = gasleft();
        assertEq(caller.rate{gas: 1_000_000}(f, 80, 100), R, "over the caller's span too");
        spent = before - gasleft();
        assertLt(spent, 300_000);
        assertEq(f.ratePerSecond(100, 100), R * (WAD + FULL) / WAD, "the shape is kept");

        // The record answers again: its centre is charged once more, and a genuine record is read
        // within the allowance over a history of changes and a silence alike.
        changing.setMode(RecordThatChangesLater.Mode.Answers);
        assertEq(f.ratePerSecond(80, 100), 3 * R, "answering again: its centre");
        assertEq(caller.rate(f, 80, 100), 3 * R);
        _setCentre(3 * R);
        uint256 lastAsOf = record.lastAsOf();
        for (uint256 n = 1; n <= 20; ++n) {
            _submitAt(lastAsOf + n * 1 hours, _uniform(n % 2 == 0 ? 3 * R : 2 * R));
        }
        caller.accrueAt(T0);
        vm.warp(record.lastAsOf() + 10 days);
        uint256 staleAt = record.lastAsOf() + 7 days;
        uint256 meanBefore = record.centreOver(T0, staleAt);
        assertEq(
            caller.rate{gas: 1_000_000}(formula, 80, 100),
            (meanBefore * (staleAt - T0) + R * 3 days) / (staleAt - T0 + 3 days),
            "a genuine record with a history of changes, across the moment of staleness, within the allowance"
        );
    }

    /// @dev Security reading finding 2 (seventh reading). A call is given at most sixty-three
    ///      sixty-fourths of the gas on hand, so a caller that entered `ratePerSecond` with too little
    ///      gas left the record less than its allowance, and a genuine, fresh record ran out inside
    ///      `centreOver`. Before the fix `_ask` took that for a record that does not answer and priced
    ///      it at the resting centre: the least gas at which the call answered at all gave the resting
    ///      centre, and so did a band of gas above it. Now a read whose call failed with less than a
    ///      sixty-third of the allowance left fails with it, so at every gas the formula either fails
    ///      or answers the record's rate; a record that truly reverts, with any gas to spare, and one
    ///      that burns its whole allowance are still charged at rest.
    function test_aReadStarvedOfGasByTheCallerFailsInsteadOfPricingTheRecordAtRest() public {
        // A genuine record with a history of changes, read over a span by a caller that answers
        // `lastAccrual()`: the dearest read, `centreOver`, over several checkpoints.
        _setCentre(3 * R);
        uint256 lastAsOf = record.lastAsOf();
        for (uint256 n = 1; n <= 8; ++n) {
            _submitAt(lastAsOf + n * 1 hours, _uniform(n % 2 == 0 ? 3 * R : 2 * R));
        }
        AccruingCaller caller = new AccruingCaller();
        caller.accrueAt(T0);
        vm.warp(record.lastAsOf() + 1 hours);
        uint256 expected = caller.rate(formula, 80, 100);
        assertEq(expected, record.centreOver(T0, block.timestamp), "with gas enough: the record's mean centre");
        assertTrue(expected != formula.restingCentre(), "told apart from the resting centre");

        // Rising gas, 32 at a step, from far too little to 20,000 beyond the least that answers: at
        // every step the formula fails or answers the record's rate, never the resting centre.
        uint256 firstAnswer = 0;
        uint256 answers = 0;
        for (uint256 g = 20_000; g <= 400_000; g += 32) {
            if (firstAnswer != 0 && g > firstAnswer + 20_000) break;
            try caller.rate{gas: g}(formula, 80, 100) returns (uint256 rate) {
                assertEq(rate, expected, "an answer is the record's rate, whatever the gas");
                if (firstAnswer == 0) firstAnswer = g;
                ++answers;
            } catch {}
        }
        assertGt(firstAnswer, 0, "with gas enough the call answers");
        assertGt(answers, 0);

        // A record that truly reverts is charged at rest as before, by a caller with modest gas and
        // with plenty: its call fails with far more than a sixty-third of the allowance left.
        RecordThatChangesLater changing = new RecordThatChangesLater(MAX_RATE, 3 * R, R);
        FollowingRateFormula f = new FollowingRateFormula(address(changing), TARGET, FLOOR, FULL);
        changing.setMode(RecordThatChangesLater.Mode.Reverts);
        assertEq(f.ratePerSecond{gas: 60_000}(80, 100), R, "a record that reverts, read with modest gas: at rest");
        assertEq(f.ratePerSecond(80, 100), R, "and with plenty");
        caller.accrueAt(T0 - 1 days);
        assertEq(caller.rate{gas: 60_000}(f, 80, 100), R, "over the caller's span too");
        // A record that burns its whole allowance, given it in full, is charged at rest as before;
        // given less than it, the call is starved and fails rather than charge the resting centre.
        changing.setMode(RecordThatChangesLater.Mode.Burns);
        assertEq(f.ratePerSecond{gas: 1_000_000}(80, 100), R, "a record that burns its whole allowance: at rest");
        vm.expectRevert();
        f.ratePerSecond{gas: 100_000}(80, 100);
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

        // A reading accepted again makes the record fresh from that block, but it starts the history
        // afresh: the dead spike is not averaged again, and the record's own centre is the initial
        // centre until the next reading (security reading finding 1, fourth reading).
        _submitAt(block.timestamp, _uniform(MAX_RATE));
        assertEq(record.centre(), INITIAL_CENTRE, "the resuming reading leaves the centre at rest");
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE, "fresh again, at the resting centre still");
        // The next reading averages the resuming reading's rates: the spike is charged once more, for
        // a week at the most.
        _submitAt(block.timestamp + 30 minutes, _uniform(MAX_RATE));
        assertEq(record.centre(), MAX_RATE);
        assertEq(formula.ratePerSecond(80, 100), MAX_RATE, "the new readings' centre");
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

    /// @dev Security reading finding 1 (third reading). Before the fix the formula knew staleness only
    ///      as the last reading's `asOf` plus a week, read at the moment of the call, so a reading that
    ///      ended a silence made the record fresh again and a caller untouched across the silence was
    ///      charged the record's stored centre over the whole of it: twenty days at the spike where a
    ///      call one block earlier would have charged a week at the spike and thirteen days at rest.
    ///      Now the record writes the rest into its history when a reading ends a silence, so the
    ///      charge is the same whether the caller is touched before or after the reading.
    function test_stale_silenceEndedByAReadingIsNotRePriced() public {
        AccruingCaller untouched = new AccruingCaller();
        AccruingCaller touchedDuring = new AccruingCaller();
        _setCentre(3 * R);
        uint256 step = block.timestamp;
        untouched.accrueAt(step);
        uint256 staleAt = record.lastAsOf() + 7 days;
        assertEq(staleAt, step + 7 days);
        touchedDuring.accrueAt(staleAt + 2 days);

        // Twenty days on, with the silence still open: a week at 3R and thirteen days at rest.
        vm.warp(step + 20 days);
        uint256 mean = (7 days * 3 * R + 13 days * R) / 20 days;
        assertEq(untouched.rate(formula, 80, 100), mean, "while the silence is open");
        assertEq(touchedDuring.rate(formula, 80, 100), R, "touched during the silence: at rest since");

        // A reading ends the silence in this block, before either caller is touched. Nothing they are
        // charged changes: the rest is in the record's history now. The resuming reading starts the
        // history afresh, so the record's centre is at rest until the next reading (security reading
        // finding 1, fourth reading).
        uint256 resumedAt = block.timestamp;
        _submitAt(resumedAt, _uniform(3 * R));
        assertEq(record.centre(), R, "the resuming reading leaves the centre at rest");
        assertEq(record.lastAsOf(), resumedAt, "fresh again");
        assertEq(formula.ratePerSecond(80, 100), R, "a direct quote: the centre as it stands, at rest");
        assertEq(untouched.rate(formula, 80, 100), mean, "the silence is priced as it was while open");
        assertEq(touchedDuring.rate(formula, 80, 100), R, "and so is the time since a touch inside it");
        assertEq(untouched.rate(formula, 100, 100), mean * (WAD + FULL) / WAD);
        assertEq(untouched.rate(formula, 40, 100), _expected(mean, 0.4e18));

        // The reading after the resuming one, half an hour on, averages its rates: from that block
        // the record's centre is charged again. A day after the resumption the untouched caller's
        // span holds the week at 3R, the thirteen days and a half hour at rest, and the rest of the
        // day at 3R.
        uint256 again = resumedAt + 30 minutes;
        _submitAt(again, _uniform(3 * R));
        assertEq(record.centre(), 3 * R);
        assertEq(formula.ratePerSecond(80, 100), 3 * R, "a direct quote: the new centre");
        vm.warp(resumedAt + 1 days);
        assertEq(
            untouched.rate(formula, 80, 100),
            (7 days * 3 * R + (13 days + 30 minutes) * R + (1 days - 30 minutes) * 3 * R) / 21 days
        );
        uint256 sinceTouch = ((11 days + 30 minutes) * R + (1 days - 30 minutes) * 3 * R) / 12 days;
        assertEq(touchedDuring.rate(formula, 80, 100), sinceTouch, "eleven days and a half hour at rest, then 3R");
        // A caller accrued at the resumption itself sees the rest to the next reading, then the new
        // centre; one accrued at the next reading sees the new centre alone.
        AccruingCaller afterwards = new AccruingCaller();
        afterwards.accrueAt(resumedAt);
        assertEq(afterwards.rate(formula, 80, 100), (30 minutes * R + (1 days - 30 minutes) * 3 * R) / 1 days);
        afterwards.accrueAt(again);
        assertEq(afterwards.rate(formula, 80, 100), 3 * R);
    }

    /// @dev The same with a dead centre below the resting one: the loss would be the lenders'. A
    ///      silence that a reading ends is priced at rest as it was while open, whether or not the
    ///      resuming reading moves the centre.
    function test_stale_silenceEndedByAReadingIsNotRePricedFromBelowEither() public {
        AccruingCaller untouched = new AccruingCaller();
        _setCentre(R / 5);
        uint256 step = block.timestamp;
        untouched.accrueAt(step);
        vm.warp(step + 20 days);
        uint256 mean = (7 days * (R / 5) + 13 days * R) / 20 days;
        assertEq(untouched.rate(formula, 80, 100), mean);
        // The resuming reading states 3R. Before the fix of security reading finding 1 (fourth
        // reading) the silence counted at the last stated rates, so the dead centre R / 5 came back
        // into force from this block until the next reading, a day on; now the resuming reading
        // starts the history afresh, the centre is at rest until the next reading, and the record is
        // fresh with the silence rested in its history.
        _submitAt(block.timestamp, _uniform(3 * R));
        assertEq(record.centre(), R, "at rest, not at the dead centre");
        assertEq(untouched.rate(formula, 80, 100), mean, "not re-priced at the dead centre");
        assertGt(untouched.rate(formula, 80, 100), R / 5, "the lenders are not charged for the silence at it");
        assertEq(formula.ratePerSecond(80, 100), R, "the dead centre is not charged after the resumption either");
        // A day later the readings have moved the centre to 3R from that block: the resuming reading's
        // rates alone, over the day since it.
        _submitAt(block.timestamp + 24 hours, _uniform(3 * R));
        assertEq(record.centre(), 3 * R);
        vm.warp(block.timestamp + 1 days);
        assertEq(
            untouched.rate(formula, 80, 100),
            (7 days * (R / 5) + 13 days * R + 1 days * R + 1 days * 3 * R) / 22 days,
            "the day after the resumption at rest, not at the dead centre"
        );
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
