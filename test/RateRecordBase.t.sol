// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IRateRecord} from "../interfaces/IRateRecord.sol";
import {RateRecord} from "../src/rates/RateRecord.sol";

/// @notice Common fixture for the rate record: one record over ten labelled candidates, a signer
///         whose signing seed the test holds, and helpers that build, sign and deliver instructions.
abstract contract RateRecordBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant T0 = 1_700_000_000;
    /// @dev 100 percent a year, per second.
    uint256 internal constant MAX_RATE = 1e18 / YEAR;
    /// @dev 5 percent a year, per second.
    uint256 internal constant INITIAL_CENTRE = 0.05e18 / YEAR;

    address internal signer;
    uint256 internal signerSeed;
    address internal other;
    uint256 internal otherSeed;
    address internal stranger = makeAddr("stranger");

    RateRecord internal record;
    bytes32[10] internal labels;
    uint256 internal idCount;

    function setUp() public virtual {
        vm.warp(T0);
        (signer, signerSeed) = makeAddrAndKey("AERKey signer");
        (other, otherSeed) = makeAddrAndKey("someone else");
        for (uint256 i = 0; i < 10; ++i) {
            labels[i] = keccak256(abi.encodePacked("candidate ", i));
        }
        record = new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, signer);
    }

    // ------------------------------------------------------------------ building

    function _id() internal returns (bytes32) {
        return keccak256(abi.encodePacked("instruction ", ++idCount));
    }

    /// @dev Deposits ranking the candidates in index order: candidate 0 the largest, 9 the smallest.
    function _descendingDeposits() internal pure returns (uint256[10] memory d) {
        for (uint256 i = 0; i < 10; ++i) {
            d[i] = (10 - i) * 1e24;
        }
    }

    function _uniform(uint256 rate) internal pure returns (uint256[10] memory r) {
        for (uint256 i = 0; i < 10; ++i) {
            r[i] = rate;
        }
    }

    /// @dev Narrow a timestamp to the record's width.
    function _u64(uint256 x) internal pure returns (uint64) {
        // casting to 'uint64' is safe because the tests never date a reading beyond type(uint64).max
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(x);
    }

    function _reading(uint256 asOf, uint256[10] memory deposits, uint256[10] memory rates)
        internal
        returns (IRateRecord.Reading memory r)
    {
        r.id = _id();
        r.asOf = _u64(asOf);
        r.deposits = deposits;
        r.rates = rates;
        r.deadline = block.timestamp + 1 hours;
    }

    function _rotate(address next) internal returns (IRateRecord.Rotate memory r) {
        r.id = _id();
        r.next = next;
        r.deadline = block.timestamp + 1 hours;
    }

    // ------------------------------------------------------------------ signing and delivering

    function _sign(bytes32 digest, uint256 seed) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(seed, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signReading(IRateRecord.Reading memory r, uint256 seed) internal view returns (bytes memory) {
        return _sign(record.readingDigest(r), seed);
    }

    function _signRotate(IRateRecord.Rotate memory r, uint256 seed) internal view returns (bytes memory) {
        return _sign(record.rotateDigest(r), seed);
    }

    /// @dev Deliver a reading signed by the signer, from a stranger.
    function _submit(IRateRecord.Reading memory r) internal {
        bytes memory signature = _signReading(r, signerSeed);
        vm.prank(stranger);
        record.submitReading(r, signature);
    }

    /// @dev Move the clock to `asOf` if it is behind, and deliver a reading of `rates` with the
    ///      descending deposits (leaders 0, 1, 2).
    function _submitAt(uint256 asOf, uint256[10] memory rates) internal {
        _reach(asOf);
        _submit(_reading(asOf, _descendingDeposits(), rates));
    }

    function _submitAt(uint256 asOf, uint256[10] memory deposits, uint256[10] memory rates) internal {
        _reach(asOf);
        _submit(_reading(asOf, deposits, rates));
    }

    /// @dev Move the clock forward to `t` if it is behind.
    function _reach(uint256 t) internal {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < t) vm.warp(t);
    }

    function _queueRotate(address next) internal returns (bytes32 id) {
        IRateRecord.Rotate memory r = _rotate(next);
        bytes memory signature = _signRotate(r, signerSeed);
        vm.prank(stranger);
        record.submitRotate(r, signature);
        return r.id;
    }

    // ------------------------------------------------------------------ reference arithmetic

    /// @dev The average of one candidate over the window ending at reading `n`, computed from the
    ///      full list of readings the test kept, by the stated rule: a rate counts forward from its
    ///      reading until the next one; the window starts 24 hours before reading `n`, or at the first
    ///      reading still kept if that is later.
    function _referenceAverage(uint64[] memory asOfs, uint256[] memory rates, uint256 n, uint256 oldestKept)
        internal
        pure
        returns (uint256)
    {
        uint256 end = asOfs[n];
        uint256 start = end > 24 hours ? end - 24 hours : 0;
        if (start < asOfs[oldestKept]) start = asOfs[oldestKept];
        uint256 area;
        for (uint256 k = 0; k < n; ++k) {
            uint256 from = asOfs[k] > start ? asOfs[k] : start;
            uint256 to = asOfs[k + 1] < end ? asOfs[k + 1] : end;
            if (to > from) area += rates[k] * (to - from);
        }
        return area / (end - start);
    }
}
