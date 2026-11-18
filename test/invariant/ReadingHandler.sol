// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IRateRecord} from "../../interfaces/IRateRecord.sol";
import {RateRecord} from "../../src/rates/RateRecord.sol";

/// @notice Drives one rate record through random valid readings signed by its signer: random rates
///         up to the highest, random deposits, random leaders. Never reverts. A reading is skipped,
///         not refused, when the least interval since the last one has not passed, or when the
///         block is within the hour before the moment the record goes stale, where no reading is
///         dated (the record's check 7, `AcrossTheMoment`).
contract ReadingHandler is Test {
    RateRecord public record;
    uint256 internal signerSeed;
    uint256 public accepted;
    uint256 public skipped;
    uint256 public highestCentre;

    constructor(RateRecord record_, uint256 signerSeed_) {
        record = record_;
        signerSeed = signerSeed_;
    }

    function submit(uint256 salt, uint256[10] memory rates, uint256[10] memory deposits) external {
        uint256 asOf = block.timestamp;
        if (record.readingCount() != 0) {
            uint256 last = record.lastAsOf();
            if (asOf < last + record.MIN_INTERVAL()) {
                ++skipped;
                return;
            }
            uint256 staleAt = last + record.STALE_AFTER();
            if (asOf <= staleAt && asOf + record.MAX_AGE() > staleAt) {
                ++skipped;
                return;
            }
        }
        uint256 maxRate = record.maxRate();
        for (uint256 i = 0; i < 10; ++i) {
            rates[i] = bound(rates[i], 0, maxRate);
            // Sometimes the highest rate, sometimes nothing deposited; always three or more above zero.
            if (salt % 7 == i) rates[i] = maxRate;
            deposits[i] = bound(deposits[i], 0, 1e30);
        }
        uint256 first = salt % 10;
        deposits[first] = bound(deposits[first], 1, 1e30);
        deposits[(first + 1) % 10] = bound(deposits[(first + 1) % 10], 1, 1e30);
        deposits[(first + 2) % 10] = bound(deposits[(first + 2) % 10], 1, 1e30);

        // casting to 'uint64' is safe because the handler's clock never leaves the uint64 range
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 dated = uint64(asOf);
        IRateRecord.Reading memory r = IRateRecord.Reading({
            id: keccak256(abi.encode(salt, asOf, record.readingCount())),
            asOf: dated,
            deposits: deposits,
            rates: rates,
            deadline: asOf
        });
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(signerSeed, record.readingDigest(r));
        record.submitReading(r, abi.encodePacked(rr, ss, v));
        ++accepted;
        if (record.centre() > highestCentre) highestCentre = record.centre();
    }

    // Time passes only through the market handler's own `warp`, so that the market invariants'
    // "last call was a borrower action" flag keeps its meaning: a reading never moves the clock, and
    // a change of the centre alone changes no loan until time passes.
}
