// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IRateRecord} from "../../interfaces/IRateRecord.sol";

/// @title RateRecord
/// @notice The rate record of one loan coin. It follows ten candidate lending protocols on other
///         chains through readings signed by the AERKey signer and delivered by anyone. On each
///         accepted reading it ranks the candidates by deposits, names the three leaders, extends a
///         history of the stated rates and stores one figure, the centre: the mean of the three
///         leaders' average rates over the last 24 hours. A following rate formula reads that figure.
///
/// The record holds no value and moves no coin. It has no owner: the only authority is the signer,
/// and the signer changes only by a handover the signer itself signs, effective 72 hours later and
/// executable by anyone for 72 hours after that, then void. Until a queued handover executes or its
/// window closes, the signer may void it by a second signed instruction, so that a
/// handover to a wrong address need not complete. A void does not recover the record from a stolen
/// key: the void is signed by the same key as the handover and takes effect at once, so whoever holds
/// a copy of the key can void every handover the other holder queues, the rightful signer's rescue
/// included, and go on signing readings. Against a stolen key the remedy is outside the record: the
/// markets that follow it, and the formula that bounds what a reading can charge.
///
/// Averaging. Every accepted reading stores, for each candidate, the rate it states and a running
/// sum: the sum at the previous reading plus the previous reading's rate multiplied by the seconds
/// between the two. A stated rate thus counts forward, from its own reading until the next one, so
/// a silent stretch counts at the last stated rates. The average of a candidate over the window
/// ending at a reading is the difference of the running sums at the window's two ends divided by its
/// length; the sum at the window's start is interpolated from the latest reading at or before it.
///
/// The centre over time. A reading is delivered at some block, and from that block on the markets
/// are charged at the centre it stored. So that a reading prices only the time after its delivery,
/// the record keeps a checkpoint for every change of the centre: the block's time, the centre from
/// then on, and the integral of the centre over time up to then. `centreOver(from, to)` answers the
/// mean of the centre over any span from those checkpoints, and the following formula charges a
/// market at the mean over the time since the market's last accrual.
///
/// A silence. The stored centre is left as it is when readings stop, and the following formula
/// charges it only until the last reading's `asOf` is `STALE_AFTER` old; after that it charges the
/// initial centre, the resting centre. So that a reading which ends such a silence cannot re-price
/// it, the rest is written into the history before the reading is: a reading accepted more than
/// `STALE_AFTER` after the last one first checkpoints the initial centre at the moment the record
/// went stale, `lastAsOf + STALE_AFTER`. A span across a silence that has ended is thus priced as it
/// was while the silence was open, whoever touches what in whatever order. And so that the rates
/// stated before the silence, dead for more than a week, are not put back in force by the reading
/// that ends it, that reading starts a new history, as the first reading ever did: it names the
/// leaders and is stored, but it is averaged over nothing, so the centre stays at the initial centre
/// until the next reading, and the window of every later reading reaches no further back than it.
/// The stored `centre` itself rests only through such a reading: it is the figure of the last
/// reading, and only a reading moves it.
///
/// Widths. `asOf` is a uint64 and every rate is at most `maxRate`, which is below 2^192, so a running
/// sum is below 2^192 * 2^64 = 2^256 over any span of time: no sum can overflow. The centre is at most
/// `maxRate` too, so the integral of the centre is below 2^256 up to any time a uint64 can name.
contract RateRecord is IRateRecord, EIP712 {
    // ------------------------------------------------------------------ constants

    /// @notice The number of candidate protocols the record follows.
    uint256 public constant CANDIDATES = 10;
    /// @notice The number of leaders whose averages make the centre.
    uint256 public constant LEADERS = 3;
    /// @notice The length of the averaging window.
    uint256 public constant WINDOW = 24 hours;
    /// @notice The least time between two accepted readings.
    uint256 public constant MIN_INTERVAL = 30 minutes;
    /// @notice The greatest age of a reading at delivery: how long after its `asOf` it is still accepted.
    uint256 public constant MAX_AGE = 1 hours;
    /// @notice The number of readings kept.
    uint256 public constant HISTORY = 64;
    /// @notice The delay between a handover's submission and its execution.
    uint256 public constant ROTATE_DELAY = 72 hours;
    /// @notice How long after a handover becomes ready it may still be executed; past that it is void,
    ///         so a handover left unexecuted does not stay executable by anyone for ever.
    uint256 public constant ROTATE_WINDOW = 72 hours;
    /// @notice How long after the last accepted reading's `asOf` the stored centre is still in force;
    ///         past it, the record is stale and the initial centre is in force until the reading after
    ///         the one that ends the silence. The following formula charges the same figure, and a
    ///         reading that ends a silence writes the rest into the history at this moment and starts
    ///         a new history, so the rates stated before the silence are never averaged again.
    uint256 public constant STALE_AFTER = 7 days;

    /// @dev The widest rate the running sums can carry over a uint64 span without overflowing.
    uint256 internal constant MAX_RATE_WIDTH = type(uint192).max;

    bytes32 internal constant READING_TYPEHASH =
        keccak256("Reading(bytes32 id,uint64 asOf,uint256[10] deposits,uint256[10] rates,uint256 deadline)");
    bytes32 internal constant ROTATE_TYPEHASH = keccak256("Rotate(bytes32 id,address next,uint256 deadline)");
    bytes32 internal constant VOID_TYPEHASH = keccak256("Void(bytes32 id,bytes32 handover,uint256 deadline)");

    // ------------------------------------------------------------------ fixed at creation

    /// @notice The highest per-second rate, scaled by 1e18, a reading may state for any candidate.
    uint256 public immutable maxRate;
    /// @notice The centre answered before the record has a history.
    uint256 public immutable initialCentre;

    bytes32[10] internal _candidates;

    // ------------------------------------------------------------------ state

    /// @dev One stored reading: when it was taken, the ten rates it stated and the ten running sums
    ///      up to it (see the averaging note above).
    struct Stored {
        uint64 asOf;
        uint256[10] rates;
        uint256[10] sums;
    }

    /// @dev A queued handover. `generation` is the count of executed handovers at queueing time; a
    ///      handover executes only while that count is unchanged, the signer has not voided it, and
    ///      the block is not past `readyAt + ROTATE_WINDOW`.
    struct Handover {
        address next;
        uint256 readyAt;
        uint256 generation;
        bool voided;
    }

    /// @dev One change of the centre: the block's time at which it took effect, the centre from then
    ///      on, and the integral of the centre over time from the record's creation up to `at`.
    struct Checkpoint {
        uint64 at;
        uint192 centre;
        uint256 integral;
    }

    /// @inheritdoc IRateRecord
    address public signer;
    /// @inheritdoc IRateRecord
    uint256 public centre;
    /// @inheritdoc IRateRecord
    uint64 public lastAsOf;
    /// @inheritdoc IRateRecord
    uint256 public readingCount;

    uint256[3] internal _leaders;
    /// @dev The ring of kept readings; reading `n` lives in slot `n % HISTORY`.
    Stored[64] internal _ring;
    mapping(bytes32 id => bool) internal _used;
    mapping(bytes32 id => Handover) internal _handovers;
    uint256 internal _executedHandovers;
    /// @dev Every change of the centre in order of time, the first being the record's creation.
    Checkpoint[] internal _checkpoints;
    /// @dev The position of the first reading of the current history: the first ever, or the latest
    ///      reading that ended a silence. No window reaches further back than it, so rates stated
    ///      before a silence of more than `STALE_AFTER` are never averaged again.
    uint256 internal _historyStart;

    // ------------------------------------------------------------------ construction

    constructor(bytes32[10] memory candidates_, uint256 maxRate_, uint256 initialCentre_, address signer_)
        EIP712("AERKey", "1")
    {
        assert(HISTORY * MIN_INTERVAL > WINDOW);
        for (uint256 i = 0; i < CANDIDATES; ++i) {
            if (candidates_[i] == bytes32(0)) revert BadConfig();
            for (uint256 j = 0; j < i; ++j) {
                if (candidates_[j] == candidates_[i]) revert BadConfig();
            }
        }
        if (maxRate_ == 0 || maxRate_ > MAX_RATE_WIDTH) revert BadConfig();
        if (initialCentre_ == 0 || initialCentre_ > maxRate_) revert BadConfig();
        if (signer_ == address(0)) revert BadConfig();

        _candidates = candidates_;
        maxRate = maxRate_;
        initialCentre = initialCentre_;
        signer = signer_;
        centre = initialCentre_;
        // The clock is the chain's: the history starts at the block of creation.
        // forge-lint: disable-next-line(block-timestamp)
        _checkpoint(block.timestamp, initialCentre_);
    }

    // ------------------------------------------------------------------ readings

    /// @inheritdoc IRateRecord
    function submitReading(Reading calldata r, bytes calldata signature) external {
        _verify(r.id, r.deadline, readingDigest(r), signature);
        // The clock is the chain's; a reading dated after it, or more than MAX_AGE before it, is
        // refused by design: a reading cannot be held back and delivered when its moment suits, nor
        // dated back into a silence to rewrite the window at once.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 now_ = block.timestamp;
        if (r.asOf > now_) revert FromTheFuture(r.asOf);
        if (r.asOf + MAX_AGE < now_) revert Stale(r.asOf);
        uint256 count = readingCount;
        uint64 last = lastAsOf;
        if (count != 0 && r.asOf < last + MIN_INTERVAL) revert TooSoon(r.asOf, last);
        for (uint256 i = 0; i < CANDIDATES; ++i) {
            if (r.rates[i] > maxRate) revert RateTooHigh(i, r.rates[i]);
        }
        uint256[3] memory top = _rank(r.deposits);

        // Accepted: everything below changes state.
        _used[r.id] = true;
        Stored storage s = _ring[count % HISTORY];
        s.asOf = r.asOf;
        if (count == 0) {
            // The first reading starts the history with running sums of zero (fresh storage).
            for (uint256 i = 0; i < CANDIDATES; ++i) {
                s.rates[i] = r.rates[i];
            }
        } else {
            Stored storage p = _ring[(count - 1) % HISTORY];
            uint256 span = r.asOf - p.asOf;
            for (uint256 i = 0; i < CANDIDATES; ++i) {
                s.sums[i] = p.sums[i] + p.rates[i] * span;
                s.rates[i] = r.rates[i];
            }
        }
        _leaders = top;
        lastAsOf = r.asOf;
        readingCount = count + 1;
        // The first reading has no span to average over: the centre stays what it is. A centre that
        // moves takes effect from this block, and is checkpointed so that the time before it stays
        // priced at the centre that was in force.
        if (count != 0) {
            uint256 staleAt = uint256(last) + STALE_AFTER;
            if (now_ > staleAt) {
                // This reading ends a silence: the record went stale before this block, and the
                // initial centre was in force from that moment, so the history must say so. The
                // moment is never before the last checkpoint, which is at most MAX_AGE after the
                // last reading's asOf. A stored centre already at the initial centre rested at
                // nothing: no checkpoint is needed. The rates stated before the silence are dead,
                // more than a week old, and are not put back in force by averaging a window that
                // lies inside the silence: this reading starts a new history instead, as the first
                // reading did, and the centre stays at the initial centre until the next reading,
                // whose window reaches back no further than this one.
                if (centre != initialCentre) _checkpoint(staleAt, initialCentre);
                _historyStart = count;
                centre = initialCentre;
            } else {
                uint256 moved = _centreAt(count, top);
                if (moved != centre) _checkpoint(now_, moved);
                centre = moved;
            }
        }
        emit ReadingAccepted(r.id, r.asOf, top, centre);
    }

    // ------------------------------------------------------------------ handover

    /// @inheritdoc IRateRecord
    function submitRotate(Rotate calldata r, bytes calldata signature) external {
        _verify(r.id, r.deadline, rotateDigest(r), signature);
        if (r.next == address(0)) revert ZeroAddress();

        _used[r.id] = true;
        uint256 readyAt = block.timestamp + ROTATE_DELAY;
        _handovers[r.id] = Handover({next: r.next, readyAt: readyAt, generation: _executedHandovers, voided: false});
        emit SignerRotationQueued(r.id, signer, r.next, readyAt);
    }

    /// @inheritdoc IRateRecord
    function submitVoid(Void calldata v, bytes calldata signature) external {
        _verify(v.id, v.deadline, voidDigest(v), signature);
        Handover storage h = _live(v.handover);

        _used[v.id] = true;
        h.voided = true;
        emit SignerRotationVoided(v.id, v.handover);
    }

    /// @inheritdoc IRateRecord
    function executeRotate(bytes32 id) external {
        Handover storage h = _live(id);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < h.readyAt) revert NotReady(h.readyAt);

        address previous = signer;
        signer = h.next;
        _executedHandovers += 1;
        emit SignerRotated(previous, h.next);
    }

    // ------------------------------------------------------------------ digests

    /// @inheritdoc IRateRecord
    function readingDigest(Reading calldata r) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    READING_TYPEHASH,
                    r.id,
                    r.asOf,
                    keccak256(abi.encode(r.deposits)),
                    keccak256(abi.encode(r.rates)),
                    r.deadline
                )
            )
        );
    }

    /// @inheritdoc IRateRecord
    function rotateDigest(Rotate calldata r) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ROTATE_TYPEHASH, r.id, r.next, r.deadline)));
    }

    /// @inheritdoc IRateRecord
    function voidDigest(Void calldata v) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(VOID_TYPEHASH, v.id, v.handover, v.deadline)));
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IRateRecord
    function leaders() external view returns (uint256[3] memory) {
        return _leaders;
    }

    /// @inheritdoc IRateRecord
    function candidates() external view returns (bytes32[10] memory) {
        return _candidates;
    }

    /// @notice The mean of the centre over the span from `from` to `to`, weighted by time, from the
    ///         record's checkpoints: each centre counts from the block in which the reading that stored
    ///         it was delivered until the next change, and over a silence that a later reading ended,
    ///         the initial centre counts from the moment the record went stale until the block of the
    ///         reading after the one that ended it. A silence still open is not in the history: the
    ///         last centre counts to the end of the span. Time before the record's creation is not
    ///         counted; a span of no length answers the centre in force at `to`. Depends on nothing
    ///         but the stored history and its arguments, and never reverts for a `to` a uint64 can
    ///         name.
    function centreOver(uint256 from, uint256 to) external view returns (uint256) {
        uint256 first = _checkpoints[0].at;
        if (from < first) from = first;
        if (to <= from) return _checkpoints[_checkpointAt(to)].centre;
        return (_integralAt(to) - _integralAt(from)) / (to - from);
    }

    /// @inheritdoc IRateRecord
    function readingAt(uint256 position)
        external
        view
        returns (uint64 asOf, uint256[10] memory rates, uint256[10] memory sums)
    {
        uint256 count = readingCount;
        if (position >= count || position + HISTORY < count) revert NotKept(position);
        Stored storage s = _ring[position % HISTORY];
        return (s.asOf, s.rates, s.sums);
    }

    // ------------------------------------------------------------------ internals

    /// @dev The three checks every instruction passes first, in this order: not expired, id unused,
    ///      signature of the current signer. A malformed signature is a bad signature.
    function _verify(bytes32 id, uint256 deadline, bytes32 digest, bytes calldata signature) internal view {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired(deadline);
        if (_used[id]) revert AlreadyUsed(id);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) revert BadSignature();
    }

    /// @dev The queued handover `id`, if it is still live: refused with `NotQueued` when nothing was
    ///      queued under `id`, and with `Voided` when the signer voided it, another handover has
    ///      executed since it was queued, or its window has closed: the block is past `readyAt` plus
    ///      `ROTATE_WINDOW`. At the last second of the window it is still live.
    function _live(bytes32 id) internal view returns (Handover storage h) {
        h = _handovers[id];
        if (h.next == address(0)) revert NotQueued(id);
        // The clock is the chain's: a handover's window closes by the block's time, by design.
        // forge-lint: disable-next-line(block-timestamp)
        bool expired = block.timestamp > h.readyAt + ROTATE_WINDOW;
        if (h.voided || h.generation != _executedHandovers || expired) revert Voided(id);
    }

    /// @dev The three candidates with the largest deposits among those above zero, in rank order; a
    ///      tie is won by the lower index. Fewer than three above zero is refused.
    function _rank(uint256[10] calldata deposits) internal pure returns (uint256[3] memory top) {
        bool[10] memory taken;
        for (uint256 j = 0; j < LEADERS; ++j) {
            uint256 best = CANDIDATES;
            uint256 bestDeposit = 0;
            for (uint256 i = 0; i < CANDIDATES; ++i) {
                if (taken[i]) continue;
                if (deposits[i] > bestDeposit) {
                    best = i;
                    bestDeposit = deposits[i];
                }
            }
            if (best == CANDIDATES) revert TooFewLeaders();
            taken[best] = true;
            top[j] = best;
        }
    }

    /// @dev Record that the centre is `newCentre` from `at` on, with the integral of the centre up to
    ///      `at` carried forward from the last checkpoint (zero at creation). `at` is this block for a
    ///      centre a reading stores, and the moment the record went stale for a rest; it is never
    ///      before the last checkpoint.
    function _checkpoint(uint256 at, uint256 newCentre) internal {
        uint256 integral = 0;
        uint256 n = _checkpoints.length;
        if (n != 0) {
            Checkpoint storage last = _checkpoints[n - 1];
            integral = last.integral + uint256(last.centre) * (at - last.at);
        }
        // casting to 'uint64' is safe because `at` is at most the chain's time, which fits the width
        // `asOf` has; casting to 'uint192' is safe because the centre is at most `maxRate`, which is
        // below 2^192
        // forge-lint: disable-next-line(unsafe-typecast)
        _checkpoints.push(Checkpoint({at: uint64(at), centre: uint192(newCentre), integral: integral}));
    }

    /// @dev The index of the latest checkpoint at or before `t`, or 0 if `t` is before the first.
    function _checkpointAt(uint256 t) internal view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = _checkpoints.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_checkpoints[mid].at <= t) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    /// @dev The integral of the centre over time from the record's creation to `t`: the integral at
    ///      the latest checkpoint at or before `t`, plus that checkpoint's centre over the time since.
    ///      For a `t` before the first checkpoint, the integral at the first, which is zero.
    function _integralAt(uint256 t) internal view returns (uint256) {
        Checkpoint storage c = _checkpoints[_checkpointAt(t)];
        if (t <= c.at) return c.integral;
        return c.integral + uint256(c.centre) * (t - c.at);
    }

    /// @dev The centre at reading `n` (already stored, later than the first reading of the current
    ///      history): the sum of the leaders' averages over the window ending at `n`, divided by
    ///      three, rounded down.
    function _centreAt(uint256 n, uint256[3] memory top) internal view returns (uint256) {
        Stored storage latest = _ring[n % HISTORY];
        uint256 asOf = latest.asOf;
        uint256 oldest = n + 1 > HISTORY ? n + 1 - HISTORY : 0;
        // No window reaches back past the first reading of the current history: the latest reading
        // that ended a silence, whose rates are the earliest not dead.
        uint256 first = _historyStart;
        if (oldest < first) oldest = first;

        // The window starts WINDOW before this reading, or at the first reading of the history still
        // stored if the history is shorter.
        uint256 start = asOf > WINDOW ? asOf - WINDOW : 0;
        uint256 oldestAsOf = _ring[oldest % HISTORY].asOf;
        if (start < oldestAsOf) start = oldestAsOf;

        // The latest stored reading at or before the start; the oldest qualifies at the latest.
        uint256 k = n - 1;
        while (k > oldest && _ring[k % HISTORY].asOf > start) {
            --k;
        }
        Stored storage base = _ring[k % HISTORY];
        uint256 gap = start - base.asOf;
        uint256 span = asOf - start;

        uint256 total = 0;
        for (uint256 j = 0; j < LEADERS; ++j) {
            uint256 i = top[j];
            uint256 sumAtStart = base.sums[i] + base.rates[i] * gap;
            total += (latest.sums[i] - sumAtStart) / span;
        }
        return total / LEADERS;
    }
}
