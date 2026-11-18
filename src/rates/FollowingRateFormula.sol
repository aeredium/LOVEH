// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IMarket} from "../../interfaces/IMarket.sol";
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
///         Every parameter is fixed at deployment. `ratePerSecond` never reverts, whatever the record
///         does: the constructor asks the record, once, everything the formula will ever ask of it,
///         and refuses a record that does not answer, so no record of another shape can be followed;
///         and afterwards the formula reads the record by guarded static calls, each given a fixed
///         allowance of gas (`ASK_GAS`) and copied only when the answer is exactly one word, so a
///         record that answered at creation and later reverts, loses its code, burns its gas, answers
///         with another width, however wide, or answers a figure no genuine record can answer is
///         charged as a stale record, at the resting centre, until it answers as a record again, and
///         costs the caller at most the allowance per read. A genuine `RateRecord` always answers,
///         well within the allowance.
///
/// Which centre. A market charges the whole time since its last accrual at the one rate this formula
/// answers when it is touched, and a reading delivered in between moves the record's centre. So that
/// such a reading prices only the time after its delivery, `c` is the record's centre averaged over
/// the time since the caller's last accrual: the formula asks its caller for `lastAccrual()`, which
/// every market answers, and reads `centreOver(lastAccrual, now)` from the record. When the caller
/// does not answer, or its last accrual is not before this block, `c` is the centre as it stands.
/// The rate is linear in `c`, so the rate at the mean centre is the mean of the rates over the span.
///
/// A direct quote is not what a market is charged. The answer depends on who asks: a market is
/// answered over its own span, and an account, a contract or an off-chain caller asking the formula
/// directly is answered at the centre as it stands, which differs from the market's charge whenever
/// the centre moved, or the record went stale, within the market's span. To learn what a market
/// will be charged, ask the market: its `loans()` and `loanOf()` price the span as `accrue()` will.
/// A market reads this formula before it writes its last accrual (`Market._accrue`), so its span
/// always has its length; a contract that happens to answer `lastAccrual()` is answered over the
/// span that answer names.
///
/// A stale record. The record's centre is a stored figure that readings move and silence leaves as it
/// is, so a record whose readings have stopped would charge its last centre for ever. This formula
/// bounds that: once the last accepted reading is more than `STALE_AFTER` old, by its `asOf`, the
/// centre charged is the resting centre, the record's `initialCentre` read once at creation, until a
/// reading is accepted again. Over a span that crosses the moment the record went stale, the time
/// before it is charged at the record's centre and the time after it at the resting centre, each
/// weighted by its length. The formula prices the silence itself only while it is open; a reading
/// that ends one writes the rest into the record's history (the record's `STALE_AFTER`, the same
/// figure, read at creation and refused if it differs), so a market untouched across a silence that
/// has ended is charged, through `centreOver`, exactly what it would have been charged during it.
/// The reading that ends a silence also starts the record's history afresh: its stored centre is the
/// initial centre, the resting centre, until the next reading, so the rates stated before the silence,
/// dead for more than a week, are not charged again after it.
contract FollowingRateFormula is IRateFormula {
    error ZeroRecord();
    error InvalidTarget();
    error InvalidFloorFraction();
    error ZeroMultiple();
    error SlopeAboveNotSteeper();
    error BadConfig();

    uint256 internal constant WAD = 1e18;

    /// @notice How long after the last accepted reading's `asOf` the record's centre is still charged;
    ///         past it, the resting centre is charged until a reading is accepted again. The record's
    ///         own `STALE_AFTER` is the same figure: it is where the record writes the rest into its
    ///         history, and a record whose figure differs is refused at creation.
    uint256 public constant STALE_AFTER = 7 days;

    /// @dev The gas each read of the record is given after creation. A genuine record's dearest
    ///      answer is `centreOver`: two binary searches over its checkpoints at about 2,200 gas a
    ///      step, so the allowance covers a history of more than 2^40 checkpoints, which at one every
    ///      thirty minutes is longer than sixty million years. A record that burns its gas, or spends
    ///      it on the width of its answer, costs the caller this much a read and no more.
    uint256 internal constant ASK_GAS = 200_000;

    /// @notice The rate record whose centre this formula follows.
    address public immutable record;
    /// @notice The record's highest rate, read once at creation; a centre above it is lowered to it.
    uint256 public immutable ceiling;
    /// @notice The centre charged while the record is stale: its `initialCentre`, read once at creation
    ///         and lowered to the ceiling if above it.
    uint256 public immutable restingCentre;
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
        // The record must answer, with one word each, everything `ratePerSecond` will ask of it:
        // `maxRate`, `initialCentre`, `centre`, `lastAsOf` and `centreOver`. A record of another shape
        // is refused here, at creation, rather than left to revert every market's accrual later.
        RateRecord r = RateRecord(record_);
        uint256 ceiling_ = _read(record_, abi.encodeWithSelector(r.maxRate.selector));
        uint256 resting = _read(record_, abi.encodeWithSelector(r.initialCentre.selector));
        _read(record_, abi.encodeWithSelector(r.centre.selector));
        _read(record_, abi.encodeWithSelector(r.lastAsOf.selector));
        // forge-lint: disable-next-line(block-timestamp)
        _read(record_, abi.encodeWithSelector(r.centreOver.selector, uint256(0), block.timestamp));
        // The record rests its history at its own staleness figure; the formula prices an open silence
        // at this one. The two must be the same figure, or a silence would be priced twice over or
        // not at all across the moment a reading ends it.
        if (_read(record_, abi.encodeWithSelector(r.STALE_AFTER.selector)) != STALE_AFTER) revert BadConfig();
        // The largest product the formula forms is c * fullMultiple * (u - target) with c at most the
        // ceiling and u - target below 1e18, so ceiling * fullMultiple * 1e18 must fit; then so does
        // ceiling * (1e18 + fullMultiple), the rate at full utilisation times 1e18. The ceiling is
        // also kept below 2^192, as a genuine record's is, so that a centre times a span a uint64 can
        // name fits when a span is priced piecewise across the moment the record went stale: the
        // bound is the formula's own, not an assumption about the record.
        if (ceiling_ == 0 || ceiling_ > type(uint192).max) revert BadConfig();
        if (fullMultiple_ > type(uint256).max / (ceiling_ * WAD)) revert BadConfig();
        // The resting centre is a centre like any other: lowered to the ceiling if above it, so that
        // the span arithmetic below stays within the bound the ceiling gives, and never nothing.
        if (resting == 0) revert BadConfig();
        if (resting > ceiling_) resting = ceiling_;

        record = record_;
        ceiling = ceiling_;
        restingCentre = resting;
        targetUtilisation = targetUtilisation_;
        floorFraction = floorFraction_;
        fullMultiple = fullMultiple_;
    }

    /// @inheritdoc IRateFormula
    function ratePerSecond(uint256 loans, uint256 deposits) external view returns (uint256) {
        uint256 u = Utilisation.compute(loans, deposits);
        uint256 c = _centre();
        if (c > ceiling) c = ceiling;
        if (u <= targetUtilisation) {
            return c * (floorFraction + (WAD - floorFraction) * u / targetUtilisation) / WAD;
        }
        return c + c * fullMultiple * (u - targetUtilisation) / (WAD - targetUtilisation) / WAD;
    }

    /// @dev The centre the caller is charged: the record's centre averaged over the time since the
    ///      caller's last accrual when the caller answers `lastAccrual()` with a time before this
    ///      block, and the centre as it stands otherwise; with the resting centre in place of the
    ///      record's over any time after the record went stale. The ask is a static call that changes
    ///      nothing, and a caller that does not answer it is not a fault. The record is read by
    ///      guarded static calls too, each within `ASK_GAS`: a record that does not answer as a
    ///      record, in this block, is charged as a stale one, at the resting centre, and nothing
    ///      reverts.
    function _centre() internal view returns (uint256) {
        RateRecord r = RateRecord(record);
        // The clock is the chain's: the span ends at this block, and the record is stale once the
        // block is more than STALE_AFTER past the last reading's asOf.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 to = block.timestamp;
        // A last reading wider than the `asOf` a record can store is no record's answer.
        (bool known, uint256 last) = _ask(abi.encodeWithSelector(r.lastAsOf.selector));
        if (!known || last > type(uint64).max) return restingCentre;
        uint256 staleAt = last + STALE_AFTER;
        (bool answered, bytes memory data) = msg.sender.staticcall(abi.encodeCall(IMarket.lastAccrual, ()));
        if (answered && data.length == 32) {
            uint256 from = abi.decode(data, (uint256));
            if (from < to) {
                // The record is fresh: its history holds every centre over the span, the rests of
                // silences that readings have since ended included.
                if (to <= staleAt) return _centreOver(from, to);
                // A silence is open: the history ends at the last centre, and the time since the
                // record went stale is priced here at the resting centre.
                if (staleAt <= from) return restingCentre;
                // The span crosses the moment the record went stale: the record's centre before it,
                // the resting centre after it, each weighted by its length. Both are at most the
                // ceiling, which is below 2^192, and the span is below 2^64, so the weighted sum fits.
                uint256 live = staleAt - from;
                uint256 stale = to - staleAt;
                uint256 before = _centreOver(from, staleAt);
                return (before * live + restingCentre * stale) / (live + stale);
            }
        }
        if (to > staleAt) return restingCentre;
        (bool stands, uint256 c) = _ask(abi.encodeWithSelector(r.centre.selector));
        return stands ? c : restingCentre;
    }

    /// @dev The record's mean centre over the span, lowered to the ceiling; the resting centre if the
    ///      record does not answer `centreOver` with one word.
    function _centreOver(uint256 from, uint256 to) internal view returns (uint256) {
        RateRecord r = RateRecord(record);
        (bool answered, uint256 mean) = _ask(abi.encodeWithSelector(r.centreOver.selector, from, to));
        if (!answered) return restingCentre;
        return mean > ceiling ? ceiling : mean;
    }

    /// @dev One word asked of the record by the static call `data`: whether the record answered with
    ///      exactly one word, and the word. A revert, an account without code, a record that runs out
    ///      of its allowance, and an answer of any other width are all no answer. The call is given
    ///      `ASK_GAS` and no more, and nothing of the answer is copied before its width is known: an
    ///      answer of another width is left where the record put it, whatever its size, so a record
    ///      that spends its allowance on the width of its answer cannot make the formula spend as
    ///      much again to copy it. Only the scratch space is written.
    function _ask(bytes memory data) internal view returns (bool answered, uint256 word) {
        address target = record;
        uint256 allowance = ASK_GAS;
        assembly ("memory-safe") {
            let ok := staticcall(allowance, target, add(data, 32), mload(data), 0, 0)
            if and(ok, eq(returndatasize(), 32)) {
                returndatacopy(0, 0, 32)
                answered := 1
                word := mload(0)
            }
        }
    }

    /// @dev One word read from `record_` by the static call `data`, or `BadConfig` if the record does
    ///      not answer it with exactly one word: used at creation alone, to refuse a record that is
    ///      not shaped as a rate record.
    function _read(address record_, bytes memory data) internal view returns (uint256) {
        (bool answered, bytes memory answer) = record_.staticcall(data);
        if (!answered || answer.length != 32) revert BadConfig();
        return abi.decode(answer, (uint256));
    }
}
