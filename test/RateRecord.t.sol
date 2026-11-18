// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {RateRecordBase} from "./RateRecordBase.t.sol";
import {IRateRecord} from "../interfaces/IRateRecord.sol";
import {RateRecord} from "../src/rates/RateRecord.sol";

contract RateRecordTest is RateRecordBase {
    uint256 internal constant HOUR = 1 hours;
    /// @dev 5 percent a year, the steady rate of the worked examples.
    uint256 internal constant R = 0.05e18 / YEAR;
    /// @dev 10 points a year.
    uint256 internal constant TEN_POINTS = 0.1e18 / YEAR;

    struct Snapshot {
        uint256 centre;
        uint256[3] leaders;
        uint64 lastAsOf;
        uint256 readingCount;
        address signer;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.centre = record.centre();
        s.leaders = record.leaders();
        s.lastAsOf = record.lastAsOf();
        s.readingCount = record.readingCount();
        s.signer = record.signer();
    }

    function _assertUnchanged(Snapshot memory before) internal view {
        Snapshot memory now_ = _snapshot();
        assertEq(now_.centre, before.centre, "centre changed");
        assertEq(now_.lastAsOf, before.lastAsOf, "lastAsOf changed");
        assertEq(now_.readingCount, before.readingCount, "readingCount changed");
        assertEq(now_.signer, before.signer, "signer changed");
        for (uint256 j = 0; j < 3; ++j) {
            assertEq(now_.leaders[j], before.leaders[j], "leaders changed");
        }
    }

    function _assertLeaders(uint256 a, uint256 b, uint256 c) internal view {
        uint256[3] memory l = record.leaders();
        assertEq(l[0], a, "leader 0");
        assertEq(l[1], b, "leader 1");
        assertEq(l[2], c, "leader 2");
    }

    /// @dev Hourly readings of `rates` from `from` to `to` inclusive, on the hour from T0.
    function _hourly(uint256 from, uint256 to, uint256[10] memory rates) internal {
        for (uint256 h = from; h <= to; ++h) {
            _submitAt(T0 + h * HOUR, rates);
        }
    }

    // ------------------------------------------------------------------ construction (3.1)

    function test_constants() public view {
        assertEq(record.CANDIDATES(), 10);
        assertEq(record.LEADERS(), 3);
        assertEq(record.WINDOW(), 24 hours);
        assertEq(record.MIN_INTERVAL(), 30 minutes);
        assertEq(record.MAX_AGE(), 1 hours);
        assertEq(record.HISTORY(), 64);
        assertEq(record.ROTATE_DELAY(), 72 hours);
        assertEq(record.ROTATE_WINDOW(), 72 hours);
        assertEq(record.STALE_AFTER(), 7 days);
        assertGt(record.HISTORY() * record.MIN_INTERVAL(), record.WINDOW(), "the ring must cover the window");
        assertGt(record.STALE_AFTER(), record.MAX_AGE(), "the rest is never before the last checkpoint");
    }

    function test_construction() public view {
        assertEq(record.maxRate(), MAX_RATE);
        assertEq(record.initialCentre(), INITIAL_CENTRE);
        assertEq(record.signer(), signer);
        assertEq(record.centre(), INITIAL_CENTRE, "the centre before any history is the initial centre");
        assertEq(record.lastAsOf(), 0);
        assertEq(record.readingCount(), 0);
        bytes32[10] memory c = record.candidates();
        for (uint256 i = 0; i < 10; ++i) {
            assertEq(c[i], labels[i]);
        }
        _assertLeaders(0, 0, 0);
        (, string memory name, string memory version,, address verifying,,) = record.eip712Domain();
        assertEq(name, "AERKey");
        assertEq(version, "1");
        assertEq(verifying, address(record));
    }

    function test_constructor_rejects() public {
        bytes32[10] memory bad = labels;
        bad[3] = bytes32(0);
        vm.expectRevert(IRateRecord.BadConfig.selector);
        new RateRecord(bad, MAX_RATE, INITIAL_CENTRE, signer);

        bad = labels;
        bad[7] = labels[2];
        vm.expectRevert(IRateRecord.BadConfig.selector);
        new RateRecord(bad, MAX_RATE, INITIAL_CENTRE, signer);

        vm.expectRevert(IRateRecord.BadConfig.selector);
        new RateRecord(labels, 0, INITIAL_CENTRE, signer);
        vm.expectRevert(IRateRecord.BadConfig.selector);
        new RateRecord(labels, uint256(type(uint192).max) + 1, 1, signer);
        vm.expectRevert(IRateRecord.BadConfig.selector);
        new RateRecord(labels, MAX_RATE, 0, signer);
        vm.expectRevert(IRateRecord.BadConfig.selector);
        new RateRecord(labels, MAX_RATE, MAX_RATE + 1, signer);
        vm.expectRevert(IRateRecord.BadConfig.selector);
        new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, address(0));

        // The edges are accepted: the widest rate, and a centre equal to the highest rate.
        RateRecord widest = new RateRecord(labels, type(uint192).max, type(uint192).max, signer);
        assertEq(widest.maxRate(), type(uint192).max);
        assertEq(widest.centre(), type(uint192).max);
    }

    // ------------------------------------------------------------------ refusals (3.2, 3.3)

    function test_refuses_expired() public {
        IRateRecord.Reading memory r = _reading(T0, _descendingDeposits(), _uniform(R));
        r.deadline = T0 - 1;
        bytes memory sig = _signReading(r, signerSeed);
        Snapshot memory before = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Expired.selector, T0 - 1));
        record.submitReading(r, sig);
        _assertUnchanged(before);

        // At the deadline itself it is accepted.
        r.deadline = T0;
        record.submitReading(r, _signReading(r, signerSeed));
        assertEq(record.readingCount(), 1);
    }

    function test_refuses_usedId_acrossBothTypes() public {
        IRateRecord.Reading memory r = _reading(T0, _descendingDeposits(), _uniform(R));
        _submit(r);
        // The same reading again, and a different reading under the same id.
        Snapshot memory before = _snapshot();
        bytes memory sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AlreadyUsed.selector, r.id));
        record.submitReading(r, sig);
        IRateRecord.Reading memory r2 = _reading(T0 + 1 hours, _descendingDeposits(), _uniform(R));
        r2.id = r.id;
        vm.warp(T0 + 1 hours);
        sig = _signReading(r2, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AlreadyUsed.selector, r.id));
        record.submitReading(r2, sig);
        _assertUnchanged(before);

        // A handover under a reading's id, and a reading under a handover's id.
        IRateRecord.Rotate memory rot = _rotate(other);
        rot.id = r.id;
        sig = _signRotate(rot, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AlreadyUsed.selector, r.id));
        record.submitRotate(rot, sig);
        bytes32 rotId = _queueRotate(other);
        r2.id = rotId;
        sig = _signReading(r2, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AlreadyUsed.selector, rotId));
        record.submitReading(r2, sig);
    }

    function test_refuses_badSignature() public {
        IRateRecord.Reading memory r = _reading(T0, _descendingDeposits(), _uniform(R));
        Snapshot memory before = _snapshot();
        // Signed by someone else.
        bytes memory sig = _signReading(r, otherSeed);
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitReading(r, sig);
        // Signed by the signer, but over a different reading (one rate differs by a unit).
        r.rates[0] = R + 1;
        sig = _signReading(r, signerSeed);
        r.rates[0] = R;
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitReading(r, sig);
        // Malformed: wrong length, and empty.
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitReading(r, hex"0102");
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitReading(r, "");
        // Malformed: a high s value, refused rather than recovered.
        sig = _signReading(r, signerSeed);
        bytes32 s;
        assembly {
            s := mload(add(sig, 0x40))
        }
        s = bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141) - uint256(s));
        assembly {
            mstore(add(sig, 0x40), s)
        }
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitReading(r, sig);
        _assertUnchanged(before);
        // The good signature is still accepted: nothing above marked the id.
        _submit(r);
        assertEq(record.readingCount(), 1);
    }

    function test_refuses_fromTheFuture() public {
        IRateRecord.Reading memory r = _reading(T0 + 1, _descendingDeposits(), _uniform(R));
        bytes memory sig = _signReading(r, signerSeed);
        Snapshot memory before = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.FromTheFuture.selector, _u64(T0 + 1)));
        record.submitReading(r, sig);
        _assertUnchanged(before);
        // The same id, dated at the block: accepted, so the refusal marked nothing.
        r.asOf = _u64(T0);
        _submit(r);
        assertEq(record.readingCount(), 1);
        assertEq(record.lastAsOf(), T0);
    }

    function test_refuses_tooSoon() public {
        _submitAt(T0, _uniform(R));
        vm.warp(T0 + 30 minutes);
        IRateRecord.Reading memory r = _reading(T0 + 30 minutes - 1, _descendingDeposits(), _uniform(R));
        bytes memory sig = _signReading(r, signerSeed);
        Snapshot memory before = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.TooSoon.selector, _u64(T0 + 30 minutes - 1), _u64(T0)));
        record.submitReading(r, sig);
        // Earlier than the last reading is too soon as well.
        r.asOf = _u64(T0 - 1);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.TooSoon.selector, _u64(T0 - 1), _u64(T0)));
        record.submitReading(r, sig);
        _assertUnchanged(before);
        // Exactly the interval later is accepted.
        r.asOf = _u64(T0 + 30 minutes);
        _submit(r);
        assertEq(record.readingCount(), 2);
    }

    /// @dev A reading more than an hour old at delivery is refused whatever its deadline says: it
    ///      cannot be held back and delivered when its moment suits. At exactly an hour it is accepted.
    function test_refuses_stale() public {
        _submitAt(T0, _uniform(R));
        vm.warp(T0 + 3 hours);
        IRateRecord.Reading memory r = _reading(T0 + 1 hours, _descendingDeposits(), _uniform(R));
        r.deadline = T0 + 10 days;
        bytes memory sig = _signReading(r, signerSeed);
        Snapshot memory before = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Stale.selector, _u64(T0 + 1 hours)));
        record.submitReading(r, sig);
        r.asOf = _u64(T0 + 2 hours - 1);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Stale.selector, _u64(T0 + 2 hours - 1)));
        record.submitReading(r, sig);
        _assertUnchanged(before);
        // Exactly an hour old is accepted, under the same id: the refusals marked nothing.
        r.asOf = _u64(T0 + 2 hours);
        _submit(r);
        assertEq(record.readingCount(), 2);
        assertEq(record.lastAsOf(), T0 + 2 hours);
    }

    /// @dev A silence cannot be rewritten: readings dated back into it are refused, so whoever holds
    ///      signed readings cannot fill the window at once. The silence, shorter than a week, counts at
    ///      the last stated rates, and the next fresh readings move the centre an hour of the window at
    ///      a time. (A silence of more than a week is not averaged at all: see
    ///      `test_average_silenceLongerThanAWeekStartsTheHistoryAfresh`.)
    function test_stale_silenceCannotBeRewrittenByBackdatedReadings() public {
        _hourly(0, 24, _uniform(R));
        assertEq(record.centre(), R);
        uint256 silentUntil = T0 + 24 * HOUR + 6 days;
        vm.warp(silentUntil);
        // Readings dated hourly back into the silence, all at the highest rate, delivered now: every
        // one older than an hour is refused, so only the last gets in.
        for (uint256 h = 24; h >= 1; --h) {
            IRateRecord.Reading memory r =
                _reading(silentUntil - h * HOUR, _descendingDeposits(), _uniform(MAX_RATE));
            r.deadline = silentUntil + 1 hours;
            bytes memory sig = _signReading(r, signerSeed);
            if (h > 1) {
                vm.expectRevert(abi.encodeWithSelector(IRateRecord.Stale.selector, _u64(silentUntil - h * HOUR)));
            }
            record.submitReading(r, sig);
        }
        assertEq(record.readingCount(), 26);
        assertEq(record.centre(), R, "the silence counts at the last stated rate, not at a backdated one");
        // A fresh reading an hour on: one hour of the window at the highest rate, twenty-three at R.
        _submitAt(silentUntil, _uniform(MAX_RATE));
        assertEq(record.centre(), (23 * R + MAX_RATE) / 24, "an hour of the window at a time");
    }

    function test_refuses_rateTooHigh() public {
        uint256[10] memory rates = _uniform(R);
        rates[4] = MAX_RATE + 1;
        IRateRecord.Reading memory r = _reading(T0, _descendingDeposits(), rates);
        bytes memory sig = _signReading(r, signerSeed);
        Snapshot memory before = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.RateTooHigh.selector, 4, MAX_RATE + 1));
        record.submitReading(r, sig);
        _assertUnchanged(before);
        // At the highest rate it is accepted, and the candidate's deposits do not matter to the check.
        r.rates[4] = MAX_RATE;
        r.deposits[4] = 0;
        _submit(r);
        assertEq(record.readingCount(), 1);
    }

    function test_refuses_tooFewLeaders() public {
        uint256[10] memory deposits;
        deposits[1] = 5;
        deposits[8] = 7;
        IRateRecord.Reading memory r = _reading(T0, deposits, _uniform(R));
        bytes memory sig = _signReading(r, signerSeed);
        Snapshot memory before = _snapshot();
        vm.expectRevert(IRateRecord.TooFewLeaders.selector);
        record.submitReading(r, sig);
        _assertUnchanged(before);
        // Exactly three above zero is enough.
        r.deposits[3] = 1;
        _submit(r);
        _assertLeaders(8, 1, 3);
    }

    /// @dev The checks come in the stated order: a reading failing every one of them is refused by
    ///      the first, and by the next as each is mended in turn.
    function test_checksInOrder() public {
        IRateRecord.Reading memory first = _reading(T0, _descendingDeposits(), _uniform(R));
        _submit(first);
        vm.warp(T0 + 1 hours);
        uint256[10] memory deposits;
        deposits[0] = 1;
        uint256[10] memory rates = _uniform(R);
        rates[9] = MAX_RATE + 1;
        IRateRecord.Reading memory r = _reading(T0 + 2 hours, deposits, rates);
        r.id = first.id;
        r.deadline = T0;
        bytes memory sig = _signReading(r, otherSeed);

        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Expired.selector, T0));
        record.submitReading(r, sig);
        r.deadline = T0 + 1 hours;
        sig = _signReading(r, otherSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AlreadyUsed.selector, first.id));
        record.submitReading(r, sig);
        r.id = _id();
        sig = _signReading(r, otherSeed);
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitReading(r, sig);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.FromTheFuture.selector, _u64(T0 + 2 hours)));
        record.submitReading(r, sig);
        r.asOf = _u64(T0 - 1);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Stale.selector, _u64(T0 - 1)));
        record.submitReading(r, sig);
        r.asOf = _u64(T0 + 10 minutes);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.TooSoon.selector, _u64(T0 + 10 minutes), _u64(T0)));
        record.submitReading(r, sig);
        r.asOf = _u64(T0 + 1 hours);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.RateTooHigh.selector, 9, MAX_RATE + 1));
        record.submitReading(r, sig);
        r.rates[9] = MAX_RATE;
        sig = _signReading(r, signerSeed);
        vm.expectRevert(IRateRecord.TooFewLeaders.selector);
        record.submitReading(r, sig);
        r.deposits[5] = 2;
        r.deposits[6] = 3;
        _submit(r);
        assertEq(record.readingCount(), 2);
        _assertLeaders(6, 5, 0);
    }

    function test_anyoneMayDeliver() public {
        IRateRecord.Reading memory r = _reading(T0, _descendingDeposits(), _uniform(R));
        bytes memory sig = _signReading(r, signerSeed);
        vm.prank(other);
        record.submitReading(r, sig);
        assertEq(record.readingCount(), 1);
    }

    // ------------------------------------------------------------------ leaders

    function test_leaders_threeLargest_inRankOrder() public {
        uint256[10] memory deposits = _uniform(1);
        deposits[7] = 5e24;
        deposits[2] = 9e24;
        deposits[4] = 8e24;
        _submitAt(T0, deposits, _uniform(R));
        _assertLeaders(2, 4, 7);
    }

    function test_leaders_tieWonByLowerIndex() public {
        uint256[10] memory deposits = _uniform(1);
        deposits[9] = 9e24;
        deposits[2] = 9e24;
        deposits[7] = 5e24;
        deposits[6] = 5e24;
        _submitAt(T0, deposits, _uniform(R));
        _assertLeaders(2, 9, 6);
        // All equal: the three lowest indexes.
        _submitAt(T0 + 1 hours, _uniform(3), _uniform(R));
        _assertLeaders(0, 1, 2);
    }

    function test_leaders_zeroDepositsNeverLead() public {
        uint256[10] memory deposits;
        deposits[3] = 1;
        deposits[5] = 1;
        deposits[8] = 1;
        uint256[10] memory rates = _uniform(R);
        rates[0] = MAX_RATE; // the highest rate of all, with nothing deposited
        _submitAt(T0, deposits, rates);
        _assertLeaders(3, 5, 8);
        // ... and the centre never takes the zero-deposit candidate's rate.
        _submitAt(T0 + 1 hours, deposits, rates);
        assertEq(record.centre(), R);
    }

    function test_leaders_emitsAndStores() public {
        IRateRecord.Reading memory r = _reading(T0, _descendingDeposits(), _uniform(R));
        uint256[3] memory expected = [uint256(0), 1, 2];
        vm.expectEmit(true, true, true, true, address(record));
        emit IRateRecord.ReadingAccepted(r.id, _u64(T0), expected, INITIAL_CENTRE);
        _submit(r);
        _assertLeaders(0, 1, 2);
        assertEq(record.lastAsOf(), T0);
        assertEq(record.readingCount(), 1);
    }

    // ------------------------------------------------------------------ the first reading and the history

    function test_firstReading_leavesCentreAtInitial() public {
        _submitAt(T0, _uniform(MAX_RATE));
        assertEq(record.centre(), INITIAL_CENTRE);
        (uint64 asOf, uint256[10] memory rates, uint256[10] memory sums) = record.readingAt(0);
        assertEq(asOf, T0);
        for (uint256 i = 0; i < 10; ++i) {
            assertEq(rates[i], MAX_RATE);
            assertEq(sums[i], 0, "the first reading's running sums are zero");
        }
        // Only from the second reading on does the centre move.
        _submitAt(T0 + 1 hours, _uniform(R));
        assertEq(record.centre(), MAX_RATE, "the first reading's rates count forward to the second");
    }

    function test_history_runningSumsCountForward() public {
        uint256[10] memory first = _uniform(R);
        first[0] = 3 * R;
        _submitAt(T0, first);
        _submitAt(T0 + 2 hours, _uniform(R));
        _submitAt(T0 + 3 hours, _uniform(2 * R));
        (uint64 asOf, uint256[10] memory rates, uint256[10] memory sums) = record.readingAt(1);
        assertEq(asOf, T0 + 2 hours);
        assertEq(rates[0], R);
        assertEq(sums[0], 3 * R * 2 hours, "sum at reading 1 is reading 0's rate over the gap");
        assertEq(sums[1], R * 2 hours);
        (asOf, rates, sums) = record.readingAt(2);
        assertEq(asOf, T0 + 3 hours);
        assertEq(rates[0], 2 * R);
        assertEq(sums[0], 3 * R * 2 hours + R * 1 hours);
        assertEq(sums[1], R * 3 hours);
        // The window at reading 2 is 3 hours long: candidate 0 averaged (3R * 2h + R * 1h) / 3h.
        uint256 avg0 = (3 * R * 2 hours + R * 1 hours) / 3 hours;
        assertEq(record.centre(), (avg0 + R + R) / 3);
    }

    function test_readingAt_refusesWhatIsNotKept() public {
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.NotKept.selector, 0));
        record.readingAt(0);
        for (uint256 n = 0; n < 70; ++n) {
            _submitAt(T0 + n * 30 minutes, _uniform(R));
        }
        assertEq(record.readingCount(), 70);
        for (uint256 p = 0; p < 6; ++p) {
            vm.expectRevert(abi.encodeWithSelector(IRateRecord.NotKept.selector, p));
            record.readingAt(p);
        }
        (uint64 asOf,,) = record.readingAt(6);
        assertEq(asOf, T0 + 6 * 30 minutes, "the oldest kept");
        (asOf,,) = record.readingAt(69);
        assertEq(asOf, T0 + 69 * 30 minutes, "the newest");
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.NotKept.selector, 70));
        record.readingAt(70);
    }

    // ------------------------------------------------------------------ averaging (worked figures)

    /// @dev Three leaders steady for 24 hourly readings; one of them 10 points a year higher for
    ///      exactly one hour: the centre moves by 10 points / 24 / 3, and moves back once that hour
    ///      leaves the window.
    function test_average_oneHourSpike() public {
        _hourly(0, 24, _uniform(R));
        assertEq(record.centre(), R, "steady: the centre is the steady rate");

        uint256[10] memory spiked = _uniform(R);
        spiked[0] = R + TEN_POINTS;
        _submitAt(T0 + 25 * HOUR, spiked);
        assertEq(record.centre(), R, "a stated rate counts forward: nothing has moved yet");
        _submitAt(T0 + 26 * HOUR, _uniform(R));
        uint256 expected = R + TEN_POINTS / 24 / 3;
        assertApproxEqAbs(record.centre(), expected, 2, "the spike hour moves the centre by 10 points / 24 / 3");
        assertGt(record.centre(), R);

        // The spike hour stays in the window until 24 hours after it ended.
        _hourly(27, 49, _uniform(R));
        assertApproxEqAbs(record.centre(), expected, 2, "still inside the window");
        _submitAt(T0 + 50 * HOUR, _uniform(R));
        assertEq(record.centre(), R, "the spike hour has left the window");
    }

    /// @dev All three leaders step down together: half of the step after 12 hours, all after 24.
    function test_average_stepFollowedInTwentyFourHours() public {
        uint256 high = 2 * R;
        uint256 low = R;
        _hourly(0, 24, _uniform(high));
        assertEq(record.centre(), high);
        // The step: stated at hour 25, it counts forward from there.
        _submitAt(T0 + 25 * HOUR, _uniform(low));
        assertEq(record.centre(), high, "the new rate counts forward: nothing has moved yet");
        _hourly(26, 36, _uniform(low));
        assertLt(record.centre(), high);
        assertGt(record.centre(), (high + low) / 2);
        _submitAt(T0 + 37 * HOUR, _uniform(low));
        assertEq(record.centre(), (high + low) / 2, "half of the step after 12 hours");
        _hourly(38, 48, _uniform(low));
        assertLt(record.centre(), (high + low) / 2);
        assertGt(record.centre(), low);
        _submitAt(T0 + 49 * HOUR, _uniform(low));
        assertEq(record.centre(), low, "all of the step after 24 hours");
    }

    /// @dev Silence: no reading for six days leaves the centre where it was, and the next reading
    ///      counts the silent stretch at the last stated rates, not at the new ones.
    function test_average_silenceCountsAtLastStatedRates() public {
        _hourly(0, 24, _uniform(R));
        assertEq(record.centre(), R);
        uint256 silentUntil = T0 + 24 * HOUR + 6 days;
        vm.warp(silentUntil);
        assertEq(record.centre(), R, "unchanged through the silence");

        uint256[10] memory fresh = _uniform(3 * R);
        _submitAt(silentUntil, fresh);
        assertEq(record.centre(), R, "the silent stretch counts at the last stated rate");
        _submitAt(silentUntil + HOUR, fresh);
        assertEq(record.centre(), (23 * R + 3 * R) / 24, "one hour of the new rate, 23 of the old");
        // At a week less an hour, the latest a reading may be dated before the moment of staleness
        // (check 7), the record is not yet stale: the silence still counts at the last stated rates,
        // however long the window.
        uint256 lastAsOf = record.lastAsOf();
        _submitAt(lastAsOf + record.STALE_AFTER() - record.MAX_AGE(), _uniform(R));
        assertEq(record.centre(), 3 * R, "a week less an hour: the last stated rates fill the window");
    }

    /// @dev Security reading finding 1 (fourth reading). Before the fix, the reading that ended a
    ///      silence of more than a week averaged a window lying wholly inside the silence, so the
    ///      rates stated before it, dead for more than a week and rested by the formula, became the
    ///      whole centre again from the block of the resumption: in full until the next reading and
    ///      fading over the next 24 hours, or for a whole further week if only that one reading came.
    ///      An outlier stated just before the silence, which had moved the centre only by its share
    ///      of the window, was charged whole. Now the reading that ends such a silence starts the
    ///      history afresh: the centre rests at the initial centre until the next reading, which
    ///      averages the resuming reading's rates alone, and no window reaches back into the silence.
    function test_average_silenceLongerThanAWeekStartsTheHistoryAfresh() public {
        // A day of readings at 2R, then an outlier at the highest rate stated an hour before the
        // silence: the centre has moved by the outlier's one hour of the window only.
        _hourly(0, 23, _uniform(2 * R));
        _submitAt(T0 + 24 * HOUR, _uniform(MAX_RATE));
        assertEq(record.centre(), 2 * R, "the outlier counts forward: nothing has moved yet");
        _submitAt(T0 + 25 * HOUR, _uniform(MAX_RATE));
        uint256 beforeSilence = (23 * 2 * R + MAX_RATE) / 24;
        assertEq(record.centre(), beforeSilence, "an hour of the window at the outlier");
        uint256 lastAsOf = T0 + 25 * HOUR;
        uint256 staleAt = lastAsOf + record.STALE_AFTER();

        // Twenty days of silence, then a reading at 4R. Before the fix the centre became MAX_RATE
        // here: the whole window lay inside the silence, at the outlier's rate.
        uint256 resumedAt = lastAsOf + 20 days;
        _submitAt(resumedAt, _uniform(4 * R));
        assertEq(record.centre(), INITIAL_CENTRE, "the resuming reading starts the history afresh");
        assertEq(record.readingCount(), 27);
        assertEq(record.lastAsOf(), resumedAt, "the record is fresh again");
        assertEq(record.centreOver(staleAt, resumedAt), INITIAL_CENTRE, "the rest");
        assertEq(
            record.centreOver(resumedAt, resumedAt + 1 days), INITIAL_CENTRE, "at rest still, until the next reading"
        );
        assertEq(record.centreOver(staleAt - 1, staleAt), beforeSilence, "the last second before the rest");

        // The running sums carry on across the silence, as every reading's do.
        (uint64 asOf,, uint256[10] memory sums) = record.readingAt(26);
        assertEq(asOf, resumedAt);
        (,, uint256[10] memory sumsBefore) = record.readingAt(25);
        assertEq(sums[0], sumsBefore[0] + MAX_RATE * 20 days);

        // The next reading, half an hour on, averages the resuming reading's rates alone over the time
        // since it: the window reaches back no further than the resumption. Before the fix the window
        // held 47 half-hours at MAX_RATE and one at 4R here, and MAX_RATE faded out over a day.
        _submitAt(resumedAt + 30 minutes, _uniform(4 * R));
        assertEq(record.centre(), 4 * R, "the dead rates are not averaged again");
        assertEq(record.centreOver(resumedAt, resumedAt + 30 minutes), INITIAL_CENTRE, "the rest ran to this reading");
        assertEq(record.centreOver(resumedAt + 30 minutes, resumedAt + 1 days), 4 * R, "then the new centre");

        // Half an hour later again, readings at 3R: the centre is the mean over the time since the
        // resumption, nothing earlier.
        _submitAt(resumedAt + 1 hours, _uniform(3 * R));
        assertEq(record.centre(), 4 * R, "3R counts forward: nothing has moved yet");
        _submitAt(resumedAt + 90 minutes, _uniform(3 * R));
        assertEq(record.centre(), (2 * 4 * R + 3 * R) / 3, "an hour at 4R, half an hour at 3R, nothing before");
        assertEq(record.centreOver(resumedAt + 90 minutes, resumedAt + 2 hours), (2 * 4 * R + 3 * R) / 3);

        // A day on, the window is the usual 24 hours, starting exactly where the history began.
        _submitAt(resumedAt + 24 hours, _uniform(3 * R));
        assertEq(record.centre(), (1 * 4 * R + 23 * 3 * R) / 24, "the window starts at the resumption");
        _submitAt(resumedAt + 25 hours, _uniform(3 * R));
        assertEq(record.centre(), 3 * R, "and a day after it, nothing of the resuming reading is left");

        // If only the resuming reading had come, the centre would have stayed at the initial centre
        // for the whole further week and the record would have rested again: a dead reading is never
        // charged for more than a week. Shown on a second record, made at T0 like the first.
        vm.warp(T0);
        record = new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, signer);
        _hourly(0, 24, _uniform(MAX_RATE));
        assertEq(record.centre(), MAX_RATE);
        lastAsOf = T0 + 24 * HOUR;
        _submitAt(lastAsOf + 10 days, _uniform(MAX_RATE));
        assertEq(record.centre(), INITIAL_CENTRE, "a resumption alone leaves the centre at rest");
        assertEq(record.centreOver(lastAsOf, lastAsOf + 7 days), MAX_RATE, "the week at the dead reading");
        assertEq(record.centreOver(lastAsOf + 7 days, lastAsOf + 30 days), INITIAL_CENTRE, "and nothing after it");
        _submitAt(lastAsOf + 30 days, _uniform(MAX_RATE));
        assertEq(record.centre(), INITIAL_CENTRE, "a second silence ended by a second lone reading: the same");
        assertEq(
            record.centreOver(lastAsOf, lastAsOf + 40 days), (7 days * MAX_RATE + 33 days * INITIAL_CENTRE) / 40 days
        );
    }

    /// @dev A change of leaders: the centre uses the 24-hour averages of the new three, whose history
    ///      the record has been keeping all along.
    function test_average_changeOfLeadersUsesTheirHistory() public {
        uint256[10] memory rates = _uniform(R);
        rates[3] = 4 * R;
        rates[4] = 4 * R;
        rates[5] = 4 * R;
        _hourly(0, 24, rates);
        _assertLeaders(0, 1, 2);
        assertEq(record.centre(), R);

        uint256[10] memory deposits = _descendingDeposits();
        deposits[3] = 100e24;
        deposits[4] = 90e24;
        deposits[5] = 80e24;
        _submitAt(T0 + 25 * HOUR, deposits, rates);
        _assertLeaders(3, 4, 5);
        assertEq(record.centre(), 4 * R, "the new leaders' own 24-hour averages");
    }

    /// @dev More than HISTORY readings at the least interval: the averages stay right across the
    ///      overwrite, checked against a reference kept in full by the test.
    function test_average_ringOverwriteKeepsAveragesRight() public {
        uint256 total = 3 * 64 + 7;
        uint64[] memory asOfs = new uint64[](total);
        uint256[] memory rates0 = new uint256[](total);
        uint256[] memory rates1 = new uint256[](total);
        uint256[] memory rates2 = new uint256[](total);
        for (uint256 n = 0; n < total; ++n) {
            uint256[10] memory rates = _uniform(R);
            // Three different wandering rates for the three leaders.
            rates[0] = R + (n * 7 % 23) * (R / 20);
            rates[1] = R + (n * 11 % 19) * (R / 10);
            rates[2] = (n % 5 == 0) ? MAX_RATE : R / 2;
            asOfs[n] = _u64(T0 + n * 30 minutes);
            rates0[n] = rates[0];
            rates1[n] = rates[1];
            rates2[n] = rates[2];
            _submitAt(asOfs[n], rates);
            if (n == 0) continue;
            uint256 oldestKept = n + 1 > 64 ? n + 1 - 64 : 0;
            uint256 expected =
                (_referenceAverage(asOfs, rates0, n, oldestKept)
                        + _referenceAverage(asOfs, rates1, n, oldestKept)
                        + _referenceAverage(asOfs, rates2, n, oldestKept)) / 3;
            assertEq(record.centre(), expected, string.concat("centre at reading ", vm.toString(n)));
        }
        assertEq(record.readingCount(), total);
    }

    /// @dev Uneven spacing, including gaps longer than the window and a reading exactly at the
    ///      window's start, against the reference.
    function test_average_unevenSpacingAgainstReference() public {
        uint256[] memory gaps = new uint256[](12);
        gaps[0] = 0;
        gaps[1] = 30 minutes;
        gaps[2] = 5 hours;
        gaps[3] = 24 hours;
        gaps[4] = 31 minutes;
        gaps[5] = 3 days;
        gaps[6] = 1 hours;
        gaps[7] = 23 hours;
        gaps[8] = 30 minutes;
        gaps[9] = 30 minutes;
        gaps[10] = 2 days;
        gaps[11] = 24 hours;
        uint64[] memory asOfs = new uint64[](gaps.length);
        uint256[] memory r0 = new uint256[](gaps.length);
        uint256 t = T0;
        for (uint256 n = 0; n < gaps.length; ++n) {
            t += gaps[n];
            asOfs[n] = _u64(t);
            uint256[10] memory rates = _uniform(R);
            rates[0] = (n % 2 == 0) ? 3 * R : R / 3;
            r0[n] = rates[0];
            _submitAt(t, rates);
            if (n == 0) continue;
            uint256 expected = (_referenceAverage(asOfs, r0, n, 0) + 2 * R) / 3;
            assertEq(record.centre(), expected, string.concat("centre at reading ", vm.toString(n)));
        }
    }

    // ------------------------------------------------------------------ the centre over time

    /// @dev The time-weighted mean of the centre over a span, from a full list of the changes the
    ///      test kept: `centres[i]` is in force from `times[i]` until `times[i + 1]`, the last for
    ///      ever; time before `times[0]` is not counted.
    function _referenceCentreOver(
        uint256[] memory times,
        uint256[] memory centres,
        uint256 count,
        uint256 from,
        uint256 to
    ) internal pure returns (uint256) {
        if (from < times[0]) from = times[0];
        if (to <= from) {
            uint256 k = 0;
            while (k + 1 < count && times[k + 1] <= to) {
                ++k;
            }
            return centres[k];
        }
        uint256 area;
        for (uint256 i = 0; i < count; ++i) {
            uint256 start = times[i] > from ? times[i] : from;
            uint256 end = i + 1 < count && times[i + 1] < to ? times[i + 1] : to;
            if (end > start) area += centres[i] * (end - start);
        }
        return area / (to - from);
    }

    function test_centreOver_beforeAnyReadingIsTheInitialCentre() public view {
        assertEq(record.centreOver(T0, T0 + 1 days), INITIAL_CENTRE);
        assertEq(record.centreOver(T0, T0), INITIAL_CENTRE, "a span of no length");
        assertEq(record.centreOver(T0 + 5, T0 + 1), INITIAL_CENTRE, "a span ending before it starts");
        assertEq(record.centreOver(0, T0 - 1), INITIAL_CENTRE, "before the record was made");
        assertEq(record.centreOver(T0 - 1 days, T0 + 1 days), INITIAL_CENTRE, "time before creation is not counted");
    }

    /// @dev A step of the centre counts from the block that stored it: the time before is at the
    ///      old centre, the time after at the new, and a span across it at the time-weighted mean.
    function test_centreOver_stepCountsFromItsDelivery() public {
        _hourly(0, 24, _uniform(2 * R));
        // The centre moved from R to 2R at the second reading, delivered at T0 + 1 hour.
        assertEq(record.centre(), 2 * R);
        assertEq(record.centreOver(T0, T0 + HOUR), R, "the hour before the step");
        assertEq(record.centreOver(T0 + HOUR, T0 + 24 * HOUR), 2 * R, "after the step");
        assertEq(record.centreOver(T0, T0 + 2 * HOUR), (R + 2 * R) / 2, "across the step");
        assertEq(record.centreOver(T0, T0 + 4 * HOUR), (R + 3 * 2 * R) / 4);
        assertEq(record.centreOver(T0 + HOUR - 1, T0 + HOUR), R, "the last second before the step");
        assertEq(record.centreOver(T0 + HOUR, T0 + HOUR + 1), 2 * R, "the first second from the step");
        assertEq(record.centreOver(T0 + 1 days, T0 + 10 days), 2 * R, "the last centre counts for ever");
        assertEq(record.centreOver(T0 - 1 days, T0 + 2 * HOUR), (R + 2 * R) / 2, "creation clamps the start");
        assertEq(record.centreOver(T0 + 5 * HOUR, T0 + HOUR), 2 * R, "no length: the centre in force at the end");
        assertEq(record.centreOver(T0 + 5 * HOUR, T0 + HOUR - 1), R);
    }

    /// @dev What counts is the block in which the reading was delivered, not its `asOf`: a reading
    ///      dated earlier than the block moves the centre from the block on.
    function test_centreOver_countsFromDeliveryNotFromAsOf() public {
        _submitAt(T0, _uniform(2 * R));
        vm.warp(T0 + 2 * HOUR);
        _submit(_reading(T0 + HOUR + 30 minutes, _descendingDeposits(), _uniform(2 * R)));
        assertEq(record.centre(), 2 * R);
        assertEq(record.centreOver(T0, T0 + 2 * HOUR), R, "nothing moved before the delivery");
        assertEq(record.centreOver(T0 + 2 * HOUR, T0 + 3 * HOUR), 2 * R);
        assertEq(record.centreOver(T0 + HOUR + 30 minutes, T0 + 2 * HOUR), R, "not from asOf");
    }

    /// @dev Security reading finding 1 (third reading). The formula rests a stale record at the initial
    ///      centre, but before the fix the record's history knew nothing of it: a reading that ended a
    ///      silence made the record fresh again, and `centreOver` priced the whole silence at the
    ///      stored centre, so a market untouched across it was charged the dead centre for every day
    ///      of the silence. Now a reading that ends a silence first checkpoints the initial centre at
    ///      the moment the record went stale, so the history says what the formula charged during it.
    function test_centreOver_silenceEndedByAReadingIsRestedInTheHistory() public {
        _submitAt(T0, _uniform(3 * R));
        _submitAt(T0 + 24 * HOUR, _uniform(3 * R));
        uint256 step = T0 + 24 * HOUR;
        assertEq(record.centre(), 3 * R);
        uint256 staleAt = step + record.STALE_AFTER();
        assertEq(staleAt, step + 7 days);

        // Twenty days of silence, then a reading at the same rates, and another half an hour later:
        // the history now holds the rest, which runs to the second of them (the first starts the
        // history afresh and leaves the centre at rest: security reading finding 1, fourth reading).
        uint256 resumedAt = step + 20 days;
        _submitAt(resumedAt, _uniform(3 * R));
        assertEq(record.centre(), INITIAL_CENTRE, "the resuming reading starts the history afresh");
        uint256 again = resumedAt + 30 minutes;
        _submitAt(again, _uniform(3 * R));
        assertEq(record.centre(), 3 * R, "the reading after it averages its rates");
        assertEq(record.centreOver(step, staleAt), 3 * R, "the week before the record went stale");
        assertEq(record.centreOver(staleAt, resumedAt), INITIAL_CENTRE, "the thirteen days at rest");
        assertEq(record.centreOver(staleAt - 1, staleAt), 3 * R, "the last second before the rest");
        assertEq(record.centreOver(staleAt, staleAt + 1), INITIAL_CENTRE, "the first second of the rest");
        assertEq(record.centreOver(resumedAt, again), INITIAL_CENTRE, "at rest until the reading after the resumption");
        assertEq(record.centreOver(again, again + 1 days), 3 * R, "that reading's centre from its block");
        assertEq(
            record.centreOver(step, resumedAt),
            (7 days * 3 * R + 13 days * INITIAL_CENTRE) / 20 days,
            "a span across the whole silence: a week at the centre, thirteen days at rest"
        );
        assertEq(record.centreOver(staleAt + 2 days, resumedAt), INITIAL_CENTRE, "a span inside the silence");
        assertEq(
            record.centreOver(step, again + 1 days),
            (8 days * 3 * R + (13 days + 30 minutes) * INITIAL_CENTRE) / (21 days + 30 minutes),
            "a span across the silence and past its end"
        );

        // A second silence at the same centre rests the same way, and the first one is still there.
        uint256 staleAgain = again + 7 days;
        uint256 resumedAgain = again + 10 days;
        _submitAt(resumedAgain, _uniform(3 * R));
        assertEq(record.centreOver(staleAgain, resumedAgain), INITIAL_CENTRE);
        assertEq(record.centreOver(staleAt, resumedAt), INITIAL_CENTRE);
        assertEq(
            record.centreOver(step, resumedAgain),
            (7 days * 3 * R + (13 days + 30 minutes) * INITIAL_CENTRE + 7 days * 3 * R + 3 days * INITIAL_CENTRE)
                / (30 days + 30 minutes)
        );
    }

    /// @dev The rest is dated by the last reading's `asOf` alone, not by the resuming reading's `asOf`
    ///      nor by its block: a reading dated a second after the moment of staleness and delivered
    ///      half an hour after it writes the rest from the moment, since the formula charged the rest
    ///      from there, and starts the history afresh, so the rest runs on to the block of the reading
    ///      after it. A reading dated an hour before the moment and delivered at the moment itself,
    ///      the last block that admits it, writes nothing: the record never went stale.
    function test_centreOver_restIsDatedByTheLastAsOf() public {
        _submitAt(T0, _uniform(3 * R));
        _submitAt(T0 + 24 * HOUR, _uniform(3 * R));
        uint256 step = T0 + 24 * HOUR;
        uint256 staleAt = step + 7 days;

        // Dated an hour before the moment, the latest date accepted on that side (check 7), and
        // delivered at the moment to the second: the record is not yet stale, no rest, averaged.
        vm.warp(staleAt);
        _submit(_reading(staleAt - 1 hours, _descendingDeposits(), _uniform(3 * R)));
        assertEq(record.centreOver(step, staleAt), 3 * R);
        assertEq(record.lastAsOf(), staleAt - 1 hours);
        assertEq(record.centre(), 3 * R, "averaged: the history goes on");

        // The next moment of staleness, by the new asOf. A reading dated one second after it and
        // delivered half an hour after it: the rest is written at the moment, not at the reading's
        // asOf nor at its block, and the reading starts the history afresh, so the rest runs on.
        staleAt = staleAt - 1 hours + 7 days;
        uint256 delivered = staleAt + 30 minutes;
        vm.warp(delivered);
        _submit(_reading(staleAt + 1, _descendingDeposits(), _uniform(3 * R)));
        assertEq(record.centreOver(staleAt - 1 hours, staleAt), 3 * R);
        assertEq(record.centreOver(staleAt, staleAt + 1), INITIAL_CENTRE, "the rest from the moment, not the asOf");
        assertEq(record.centreOver(staleAt + 1, delivered), INITIAL_CENTRE, "and not from the block");
        assertEq(record.centre(), INITIAL_CENTRE, "dated after the moment: the history starts afresh");
        assertEq(record.centreOver(delivered, delivered + 1 hours), INITIAL_CENTRE, "at rest until the next reading");
        assertEq(
            record.centreOver(staleAt - 1, delivered + 1),
            (3 * R + (30 minutes + 1) * INITIAL_CENTRE) / (30 minutes + 2),
            "a second before the moment, then the rest"
        );
        // The reading after it, half an hour on, averages its rates alone from its block.
        _submitAt(delivered + 30 minutes, _uniform(3 * R));
        assertEq(record.centre(), 3 * R);
        assertEq(record.centreOver(delivered, delivered + 30 minutes), INITIAL_CENTRE, "the rest ran to that reading");
        assertEq(record.centreOver(delivered + 30 minutes, delivered + 90 minutes), 3 * R, "then its centre");
        assertEq(
            record.centreOver(staleAt - 1, delivered + 30 minutes + 1),
            (2 * 3 * R + 1 hours * INITIAL_CENTRE) / (1 hours + 2),
            "a second before the moment, the rest to the reading after the resuming one, a second after it"
        );

        // A silence ended by readings at other rates: the rest, which runs to the reading after the
        // resuming one, then the new centre from the block of that reading.
        uint256 lastAsOf = record.lastAsOf();
        staleAt = lastAsOf + 7 days;
        uint256 resumedAt = lastAsOf + 12 days;
        _submitAt(resumedAt, _uniform(2 * R));
        assertEq(record.centre(), INITIAL_CENTRE, "whatever was stated before the silence, the centre is at rest");
        _submitAt(resumedAt + 30 minutes, _uniform(2 * R));
        assertEq(record.centre(), 2 * R, "the next reading averages the resuming reading's rates alone");
        assertEq(record.centreOver(staleAt, resumedAt), INITIAL_CENTRE, "the rest");
        assertEq(record.centreOver(resumedAt, resumedAt + 30 minutes), INITIAL_CENTRE, "still the rest");
        assertEq(record.centreOver(resumedAt + 30 minutes, resumedAt + 2 days), 2 * R, "the new centre from its block");

        // A silence at the initial centre rests at nothing: the history is one centre throughout.
        _submitAt(resumedAt + 24 * HOUR, _uniform(R));
        _submitAt(resumedAt + 48 * HOUR, _uniform(R));
        assertEq(record.centre(), R, "a day of the window at R");
        lastAsOf = record.lastAsOf();
        _submitAt(lastAsOf + 30 days, _uniform(R));
        assertEq(record.centre(), R);
        assertEq(record.centreOver(lastAsOf, lastAsOf + 30 days), R);
        assertEq(record.centreOver(lastAsOf + 7 days - 1, lastAsOf + 7 days + 1), R);
    }

    /// @dev Security reading finding 1 (seventh reading). No reading is dated within the hour before
    ///      the moment of staleness: once a history exists, a reading dated after
    ///      `lastAsOf + STALE_AFTER - MAX_AGE` and at or before `lastAsOf + STALE_AFTER` is refused
    ///      with `AcrossTheMoment`, in whatever block it is delivered, and changes nothing. The check
    ///      comes after `TooSoon` and before the rate and leader checks. Dated exactly an hour before
    ///      the moment a reading is accepted, and a reading dated after the moment is accepted as the
    ///      first of a new history.
    function test_refuses_acrossTheMoment() public {
        _submitAt(T0, _uniform(2 * R));
        uint256 staleAt = T0 + record.STALE_AFTER();
        uint256 gapStart = staleAt - record.MAX_AGE();
        Snapshot memory before = _snapshot();

        // The first second of the gap, delivered at that second.
        vm.warp(gapStart + 1);
        IRateRecord.Reading memory r = _reading(gapStart + 1, _descendingDeposits(), _uniform(2 * R));
        r.deadline = staleAt + 2 hours;
        bytes memory sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AcrossTheMoment.selector, _u64(gapStart + 1), staleAt));
        record.submitReading(r, sig);
        // The moment itself, delivered at the moment.
        vm.warp(staleAt);
        r.asOf = _u64(staleAt);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AcrossTheMoment.selector, _u64(staleAt), staleAt));
        record.submitReading(r, sig);
        // Delivered after the moment, within the hour: refused just the same, whatever the asOf in
        // the gap. Before the fix these two were accepted here, and averaged.
        vm.warp(staleAt + 30 minutes);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AcrossTheMoment.selector, _u64(staleAt), staleAt));
        record.submitReading(r, sig);
        r.asOf = _u64(staleAt - 30 minutes);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(
            abi.encodeWithSelector(IRateRecord.AcrossTheMoment.selector, _u64(staleAt - 30 minutes), staleAt)
        );
        record.submitReading(r, sig);
        // The check precedes the rate and leader checks.
        r.rates[0] = MAX_RATE + 1;
        sig = _signReading(r, signerSeed);
        vm.expectRevert(
            abi.encodeWithSelector(IRateRecord.AcrossTheMoment.selector, _u64(staleAt - 30 minutes), staleAt)
        );
        record.submitReading(r, sig);
        r.rates[0] = 2 * R;
        r.deposits = _uniform(0);
        sig = _signReading(r, signerSeed);
        vm.expectRevert(
            abi.encodeWithSelector(IRateRecord.AcrossTheMoment.selector, _u64(staleAt - 30 minutes), staleAt)
        );
        record.submitReading(r, sig);
        _assertUnchanged(before);
        assertEq(record.readingCount(), 1);

        // Exactly an hour before the moment, delivered at the moment, the last block that admits it:
        // accepted under the same id, so the refusals marked nothing, and averaged.
        vm.warp(staleAt);
        r.asOf = _u64(gapStart);
        r.deposits = _descendingDeposits();
        _submit(r);
        assertEq(record.readingCount(), 2);
        assertEq(record.lastAsOf(), gapStart);
        assertEq(record.centre(), 2 * R, "averaged: the window holds 2R alone");
        assertEq(record.centreOver(staleAt, staleAt + 1), 2 * R, "no rest: the record never went stale");

        // The next moment, by the new asOf. A second after it, delivered then: accepted, as the first
        // of a new history, with the rest at the moment.
        staleAt = gapStart + record.STALE_AFTER();
        vm.warp(staleAt + 1);
        _submit(_reading(staleAt + 1, _descendingDeposits(), _uniform(3 * R)));
        assertEq(record.readingCount(), 3);
        assertEq(record.centre(), INITIAL_CENTRE, "dated after the moment: the history starts afresh");
        assertEq(record.centreOver(staleAt, staleAt + 1), INITIAL_CENTRE, "the rest");
        assertEq(record.centreOver(staleAt - 1, staleAt), 2 * R, "the last second before it");
    }

    /// @dev Security reading finding 1 (seventh reading). Before the fix, whoever held two readings
    ///      outstanding across the moment of staleness, A dated at or before it and B dated after it,
    ///      30 minutes or more apart and both within `MAX_AGE` of the block, chose the centre by the
    ///      order of delivery: A then B averaged A over a window lying wholly inside the silence, so
    ///      the centre became the dead rates in full and faded over the next day across B; B alone
    ///      started the history afresh, the centre was the initial centre, and A was refused for ever
    ///      with `TooSoon`. The two differed by `maxRate` against the initial centre here, and the
    ///      notice said the step could not be moved away. Now no reading is dated within the hour
    ///      before the moment, so A is refused in every block, and a reading dated at or before the
    ///      moment is deliverable only in a block at or before it, where a reading dated after the
    ///      moment is from the future: no block admits readings dated on both sides, and no order of
    ///      delivery chooses a centre.
    function test_stale_noBlockAdmitsReadingsDatedOnBothSidesOfTheMoment() public {
        _hourly(0, 24, _uniform(MAX_RATE));
        uint256 lastAsOf = T0 + 24 * HOUR;
        uint256 staleAt = lastAsOf + record.STALE_AFTER();
        assertEq(record.centre(), MAX_RATE);

        // A dated half an hour before the moment and B half an hour after it, at the block half an
        // hour after the moment, where before the fix both were deliverable: A is exactly an hour old
        // and B is of this second. A is refused in this block, as in every other.
        uint256 at = staleAt + 30 minutes;
        vm.warp(at);
        IRateRecord.Reading memory a = _reading(staleAt - 30 minutes, _descendingDeposits(), _uniform(2 * R));
        IRateRecord.Reading memory b = _reading(staleAt + 30 minutes, _descendingDeposits(), _uniform(2 * R));
        bytes memory sigA = _signReading(a, signerSeed);
        Snapshot memory before = _snapshot();
        vm.expectRevert(
            abi.encodeWithSelector(IRateRecord.AcrossTheMoment.selector, _u64(staleAt - 30 minutes), staleAt)
        );
        record.submitReading(a, sigA);
        _assertUnchanged(before);
        // B alone is possible here: the history starts afresh, at rest, and A is refused after it as
        // before, under TooSoon. Before the fix A first gave MAX_RATE in full and then B across it.
        _submit(b);
        assertEq(record.centre(), INITIAL_CENTRE, "B: the history starts afresh, at rest");
        assertEq(record.centreOver(staleAt, at + 1), INITIAL_CENTRE, "at rest from the moment on");
        assertEq(record.readingCount(), 26);
        before = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.TooSoon.selector, _u64(staleAt - 30 minutes), _u64(at)));
        record.submitReading(a, sigA);
        _assertUnchanged(before);
        _submitAt(at + 30 minutes, _uniform(2 * R));
        assertEq(record.centre(), 2 * R, "B's rates alone: the dead rates are gone for good");

        // The latest reading dated before the moment, A' dated exactly an hour before it, and B. A'
        // is deliverable up to the block at the moment and no later, B from its own second and no
        // earlier: there is no block in which both are. Shown on a second record with the same
        // history, at the moment itself: A' is accepted and averaged, the dead rates in full, as a
        // silence of a week less an hour counts at the last stated rates by design; B is from the
        // future. Half an hour on, B averages across A'. The deliverer of both chose nothing but the
        // block from which each centre counts, within the hour, as every reading's deliverer does.
        vm.warp(T0);
        record = new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, signer);
        _hourly(0, 24, _uniform(MAX_RATE));
        vm.warp(staleAt);
        IRateRecord.Reading memory a1 = _reading(staleAt - 1 hours, _descendingDeposits(), _uniform(2 * R));
        b = _reading(staleAt + 30 minutes, _descendingDeposits(), _uniform(2 * R));
        b.deadline = at + 1 hours;
        bytes memory sigB = _signReading(b, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.FromTheFuture.selector, _u64(staleAt + 30 minutes)));
        record.submitReading(b, sigB);
        _submit(a1);
        assertEq(record.centre(), MAX_RATE, "A' at the moment: averaged, the last stated rates fill the window");
        assertEq(record.centreOver(staleAt, staleAt + 1), MAX_RATE, "and no rest");
        vm.warp(at);
        record.submitReading(b, sigB);
        assertEq(record.centre(), (45 * MAX_RATE + 3 * 2 * R) / 48, "B across A': 22.5 hours at the dead rate");
        assertEq(record.readingCount(), 27);

        // On a third record, at the block half an hour after the moment: A' is stale, B alone starts
        // the history afresh. The side of the moment is decided by the block and by the asOf alike.
        vm.warp(T0);
        record = new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, signer);
        _hourly(0, 24, _uniform(MAX_RATE));
        vm.warp(at);
        a1 = _reading(staleAt - 1 hours, _descendingDeposits(), _uniform(2 * R));
        b = _reading(staleAt + 30 minutes, _descendingDeposits(), _uniform(2 * R));
        bytes memory sigA1 = _signReading(a1, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Stale.selector, _u64(staleAt - 1 hours)));
        record.submitReading(a1, sigA1);
        _submit(b);
        assertEq(record.centre(), INITIAL_CENTRE, "B alone: afresh, at rest");
        assertEq(record.centreOver(staleAt, at + 1), INITIAL_CENTRE, "the rest from the moment");
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Stale.selector, _u64(staleAt - 1 hours)));
        record.submitReading(a1, sigA1);
        assertEq(record.readingCount(), 26);
    }

    /// @dev Security reading finding 2 (fifth reading), as it stands after the seventh reading's
    ///      finding 1. Whether a reading ends a silence is the same question by its signed `asOf` and
    ///      by its block, so one reading gives its deliverer no choice of centre. A reading dated an
    ///      hour before the moment, the latest date accepted on that side, is averaged when delivered
    ///      at the moment and refused as stale a second later; a reading dated a second after the
    ///      moment starts the history afresh whether delivered then or an hour later, with the rest
    ///      from the moment.
    function test_stale_aReadingEndsASilenceByItsAsOfAndByItsBlockAlike() public {
        _hourly(0, 24, _uniform(MAX_RATE));
        uint256 lastAsOf = T0 + 24 * HOUR;
        uint256 staleAt = lastAsOf + record.STALE_AFTER();
        assertEq(record.centre(), MAX_RATE);

        // A reading at 2R dated an hour before the moment, delivered at the moment: averaged, the
        // last stated rates fill the window, and no rest, since the record never went stale.
        IRateRecord.Reading memory ending = _reading(staleAt - 1 hours, _descendingDeposits(), _uniform(2 * R));
        ending.deadline = staleAt + 1 hours;
        bytes memory sig = _signReading(ending, signerSeed);
        vm.warp(staleAt);
        record.submitReading(ending, sig);
        assertEq(record.centre(), MAX_RATE, "dated before the moment: averaged, the dead rates in full");
        assertEq(record.lastAsOf(), staleAt - 1 hours);
        assertEq(record.centreOver(lastAsOf, staleAt + 1), MAX_RATE, "no rest");
        // The next reading, half an hour on, averages across it as any window does.
        _submitAt(staleAt + 30 minutes, _uniform(2 * R));
        assertEq(record.centre(), (45 * MAX_RATE + 3 * 2 * R) / 48, "the window reaches back across it");

        // The same reading delivered one second after the moment is stale: it cannot fall on the
        // other side. Shown on a second record, made at T0.
        vm.warp(T0);
        record = new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, signer);
        _hourly(0, 24, _uniform(MAX_RATE));
        ending = _reading(staleAt - 1 hours, _descendingDeposits(), _uniform(2 * R));
        ending.deadline = staleAt + 1 hours;
        sig = _signReading(ending, signerSeed);
        vm.warp(staleAt + 1);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Stale.selector, _u64(staleAt - 1 hours)));
        record.submitReading(ending, sig);
        assertEq(record.centre(), MAX_RATE);

        // A reading dated one second after the moment, at 4R, delivered then: the history starts
        // afresh, with the rest at the moment, and the next reading averages its rates alone.
        IRateRecord.Reading memory afterTheMoment = _reading(staleAt + 1, _descendingDeposits(), _uniform(4 * R));
        afterTheMoment.deadline = staleAt + 1 hours;
        _submit(afterTheMoment);
        assertEq(record.centre(), INITIAL_CENTRE, "dated after the moment: the history starts afresh");
        assertEq(record.centreOver(lastAsOf, staleAt), MAX_RATE, "the week before the moment");
        assertEq(record.centreOver(staleAt, staleAt + 1), INITIAL_CENTRE, "the rest");
        assertEq(record.centreOver(staleAt + 1, staleAt + 1 hours), INITIAL_CENTRE, "at rest until the next reading");
        _submitAt(staleAt + 1 + 30 minutes, _uniform(3 * R));
        assertEq(record.centre(), 4 * R, "the resuming reading's rates alone: the dead rates are not averaged again");

        // Dated one second after the moment and delivered an hour later: the same fresh start, with
        // the rest from the moment, not from the block.
        uint256 moment = record.lastAsOf() + record.STALE_AFTER();
        afterTheMoment = _reading(moment + 1, _descendingDeposits(), _uniform(2 * R));
        afterTheMoment.deadline = moment + 1 hours + 1;
        vm.warp(moment + 1 hours + 1);
        _submit(afterTheMoment);
        assertEq(record.centre(), INITIAL_CENTRE, "delivered an hour on: afresh all the same");
        assertEq(record.centreOver(moment, moment + 1 hours + 1), INITIAL_CENTRE, "the rest from the moment");
        assertEq(record.centreOver(moment - 1, moment), 4 * R, "the last second before it: the centre as it stood");
    }

    /// @dev A reading that leaves the centre unchanged makes no checkpoint, and a reading that moves
    ///      it makes one; over a long wandering history of more changes than the ring keeps, every
    ///      span agrees with a reference kept in full by the test.
    function test_centreOver_manyChangesAgainstReference() public {
        uint256 total = 3 * 64 + 7;
        uint256[] memory times = new uint256[](total + 1);
        uint256[] memory centres = new uint256[](total + 1);
        times[0] = T0;
        centres[0] = INITIAL_CENTRE;
        uint256 changes = 1;
        for (uint256 n = 0; n < total; ++n) {
            uint256[10] memory rates = _uniform(R);
            rates[0] = R + (n * 7 % 23) * (R / 20);
            rates[1] = (n % 9 < 3) ? 3 * R : R;
            rates[2] = (n % 5 == 0) ? MAX_RATE : R / 2;
            uint256 before = record.centre();
            _submitAt(T0 + n * 30 minutes, rates);
            if (record.centre() != before) {
                times[changes] = block.timestamp;
                centres[changes] = record.centre();
                ++changes;
            }
        }
        assertGt(changes, 64, "more changes than the ring of readings keeps");
        uint256 last = T0 + (total - 1) * 30 minutes;
        for (uint256 k = 0; k < 40; ++k) {
            uint256 from = T0 - 1 hours + (uint256(keccak256(abi.encode("from", k))) % (last + 2 hours - T0));
            uint256 to = T0 - 1 hours + (uint256(keccak256(abi.encode("to", k))) % (last + 2 hours - T0));
            assertEq(
                record.centreOver(from, to),
                _referenceCentreOver(times, centres, changes, from, to),
                string.concat("span ", vm.toString(k))
            );
        }
        // The spans the formula asks for: from any past change to the present.
        for (uint256 i = 0; i < changes; i += 7) {
            assertEq(record.centreOver(times[i], last), _referenceCentreOver(times, centres, changes, times[i], last));
            assertEq(
                record.centreOver(times[i] - 1, last), _referenceCentreOver(times, centres, changes, times[i] - 1, last)
            );
        }
        assertEq(record.centreOver(last, last), record.centre());
        assertEq(
            record.centreOver(0, last + 1 days), _referenceCentreOver(times, centres, changes, 0, last + 1 days)
        );
    }

    // ------------------------------------------------------------------ widths

    /// @dev The widest rate held for a hundred years, and over the whole span a uint64 can name:
    ///      no sum overflows and the centre is exact. A reading that ends a century of silence
    ///      starts the history afresh, so the widest centre is made by the reading half an hour after
    ///      each resumption.
    function test_noOverflow_atWidestRateForAHundredYears() public {
        uint256 widest = type(uint192).max;
        record = new RateRecord(labels, widest, 1, signer);
        _submitAt(T0, _uniform(widest));
        _submitAt(T0 + 100 * YEAR, _uniform(widest));
        assertEq(record.centre(), 1, "a century of silence ended: the history begins afresh, at rest");
        (,, uint256[10] memory sums) = record.readingAt(1);
        assertEq(sums[0], widest * (100 * YEAR), "the running sum carries the widest rate over the century");
        _submitAt(T0 + 100 * YEAR + 30 minutes, _uniform(widest));
        assertEq(record.centre(), widest);
        // A further century, then the last second a uint64 can hold.
        _submitAt(T0 + 200 * YEAR, _uniform(widest));
        assertEq(record.centre(), 1);
        _submitAt(T0 + 200 * YEAR + 30 minutes, _uniform(widest));
        assertEq(record.centre(), widest);
        _submitAt(type(uint64).max, _uniform(widest));
        assertEq(record.centre(), 1);
        (,, sums) = record.readingAt(5);
        assertEq(sums[0], widest * (type(uint64).max - T0));
        assertLe(record.centre(), record.maxRate());
        // The integral of the centre does not overflow either, and is exact over the whole span a
        // uint64 can name. The history: the centre was 1 for the first century and the half hour
        // after the resumption; the widest rate from the reading after it for a week, then at rest
        // (the initial centre, 1) until the reading after the next resumption; the widest rate again
        // for a week, then at rest to the last second, where the last resumption leaves it at rest.
        uint256 week = record.STALE_AFTER();
        uint256 a = T0 + 100 * YEAR + 30 minutes;
        uint256 b = T0 + 200 * YEAR + 30 minutes;
        uint256 c = type(uint64).max;
        assertEq(record.centreOver(a - 30 minutes, a), 1, "at rest until the reading after the resumption");
        assertEq(record.centreOver(a, a + week), widest, "the widest centre for the week after that reading");
        assertEq(record.centreOver(a + week, b), 1, "then at rest until the next");
        assertEq(record.centreOver(b, b + week), widest);
        assertEq(record.centreOver(b + week, c), 1);
        assertEq(record.centreOver(c, c), 1, "at rest at the last second: a lone resuming reading");
        assertEq(record.centreOver(T0, b), ((a - T0) + widest * week + (b - a - week)) / (b - T0));
        assertEq(
            record.centreOver(T0, c),
            (2 * widest * week + (c - T0 - 2 * week)) / (c - T0),
            "the integral over the widest span"
        );
    }

    /// @dev The widest centre held without a silence for the longest stretch the record allows, to
    ///      the last second a uint64 can name: the integral of the centre never overflows. A reading
    ///      every week less an hour, the latest a reading may be dated before the moment of
    ///      staleness, keeps the record fresh, so the widest centre is in force throughout.
    function test_noOverflow_integralAtWidestCentreWithoutASilence() public {
        uint256 widest = type(uint192).max;
        record = new RateRecord(labels, widest, widest, signer);
        assertEq(record.centreOver(T0, type(uint64).max), widest, "the initial centre, never rested");
        _submitAt(T0, _uniform(widest));
        _submitAt(T0 + 7 days - 1 hours, _uniform(widest));
        assertEq(record.centre(), widest);
        assertEq(record.centreOver(T0, type(uint64).max), widest, "the widest centre over the widest span");
        assertEq(record.centreOver(T0 + 7 days - 1 hours, type(uint64).max), widest);
        // The last second a uint64 can name: no rest is written when the stored centre is the initial
        // centre already, so the widest centre is in force over the whole span.
        _submitAt(type(uint64).max, _uniform(widest));
        assertEq(record.centreOver(T0, type(uint64).max), widest);
    }

    // ------------------------------------------------------------------ digests (3.2)

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AERKey"),
                keccak256("1"),
                block.chainid,
                address(record)
            )
        );
    }

    function test_readingDigest_matchesEip712() public {
        IRateRecord.Reading memory r = _reading(T0, _descendingDeposits(), _uniform(R));
        r.rates[3] = 77;
        r.deposits[9] = 0;
        bytes memory depositsEncoded;
        bytes memory ratesEncoded;
        for (uint256 i = 0; i < 10; ++i) {
            depositsEncoded = bytes.concat(depositsEncoded, bytes32(r.deposits[i]));
            ratesEncoded = bytes.concat(ratesEncoded, bytes32(r.rates[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Reading(bytes32 id,uint64 asOf,uint256[10] deposits,uint256[10] rates,uint256 deadline)"),
                r.id,
                uint256(r.asOf),
                keccak256(depositsEncoded),
                keccak256(ratesEncoded),
                r.deadline
            )
        );
        bytes32 expected = keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
        assertEq(record.readingDigest(r), expected);
        // The digest signed by the signer is the one the record accepts.
        record.submitReading(r, _sign(expected, signerSeed));
        assertEq(record.readingCount(), 1);
    }

    function test_rotateDigest_matchesEip712() public {
        IRateRecord.Rotate memory r = _rotate(other);
        bytes32 structHash = keccak256(
            abi.encode(keccak256("Rotate(bytes32 id,address next,uint256 deadline)"), r.id, r.next, r.deadline)
        );
        bytes32 expected = keccak256(abi.encodePacked(hex"1901", _domainSeparator(), structHash));
        assertEq(record.rotateDigest(r), expected);
        record.submitRotate(r, _sign(expected, signerSeed));
    }

    function test_digests_boundToChainAndRecord() public {
        IRateRecord.Reading memory r = _reading(T0, _descendingDeposits(), _uniform(R));
        bytes32 here = record.readingDigest(r);
        RateRecord twin = new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, signer);
        assertNotEq(twin.readingDigest(r), here, "another record, another digest");
        bytes memory sig = _signReading(r, signerSeed);
        vm.expectRevert(IRateRecord.BadSignature.selector);
        twin.submitReading(r, sig);
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        assertNotEq(record.readingDigest(r), here, "another chain, another digest");
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitReading(r, sig);
        vm.chainId(chain);
        record.submitReading(r, sig);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Any sequence of valid readings keeps the centre at or below the highest rate, and the
    ///      centre never reverts.
    function testFuzz_centreBoundedAndNeverReverts(uint256[10] calldata seedRates, uint256[10] calldata seedGaps)
        public
    {
        uint256 t = T0;
        for (uint256 n = 0; n < 10; ++n) {
            uint256[10] memory rates;
            uint256[10] memory deposits;
            for (uint256 i = 0; i < 10; ++i) {
                rates[i] = bound(uint256(keccak256(abi.encode(seedRates[n], i))), 0, MAX_RATE);
                deposits[i] = uint256(keccak256(abi.encode(seedGaps[n], i, "d"))) % 4;
            }
            deposits[n % 10] = 1;
            deposits[(n + 3) % 10] = 2;
            deposits[(n + 6) % 10] = 3;
            if (n != 0) t += bound(seedGaps[n], 30 minutes, 40 days);
            _submitAt(t, deposits, rates);
            assertLe(record.centre(), MAX_RATE);
            uint256[3] memory l = record.leaders();
            assertTrue(l[0] != l[1] && l[1] != l[2] && l[0] != l[2]);
        }
        assertEq(record.readingCount(), 10);
        assertEq(record.lastAsOf(), t);
    }
}
