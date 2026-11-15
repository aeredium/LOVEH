// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {RateRecordBase} from "./RateRecordBase.t.sol";
import {IRateRecord} from "../interfaces/IRateRecord.sol";

/// @notice The handover of the signer: queued by the signer, executed by anyone 72 hours later,
///         never cancelled, and voiding every handover queued before the one executed.
contract RateRecordRotationTest is RateRecordBase {
    uint256 internal constant R = 0.05e18 / YEAR;

    address internal next;
    uint256 internal nextSeed;

    function setUp() public override {
        super.setUp();
        (next, nextSeed) = makeAddrAndKey("the next signer");
    }

    function _submitSigned(uint256 asOf, uint256 seed) internal {
        _reach(asOf);
        IRateRecord.Reading memory r = _reading(asOf, _descendingDeposits(), _uniform(R));
        record.submitReading(r, _signReading(r, seed));
    }

    function _expectReadingRefused(uint256 asOf, uint256 seed) internal {
        _reach(asOf);
        IRateRecord.Reading memory r = _reading(asOf, _descendingDeposits(), _uniform(R));
        bytes memory sig = _signReading(r, seed);
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitReading(r, sig);
    }

    // ------------------------------------------------------------------ queueing

    function test_queue_emitsAndChangesNothingYet() public {
        IRateRecord.Rotate memory r = _rotate(next);
        bytes memory sig = _signRotate(r, signerSeed);
        vm.expectEmit(true, true, true, true, address(record));
        emit IRateRecord.SignerRotationQueued(r.id, signer, next, T0 + 72 hours);
        vm.prank(stranger);
        record.submitRotate(r, sig);
        assertEq(record.signer(), signer, "the signer changes only on execution");
    }

    function test_queue_refusals() public {
        IRateRecord.Rotate memory r = _rotate(address(0));
        bytes memory sig = _signRotate(r, signerSeed);
        vm.expectRevert(IRateRecord.ZeroAddress.selector);
        record.submitRotate(r, sig);

        r = _rotate(next);
        sig = _signRotate(r, otherSeed);
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitRotate(r, sig);
        sig = _signRotate(r, nextSeed);
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitRotate(r, sig);
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitRotate(r, "");

        r.deadline = T0 - 1;
        sig = _signRotate(r, signerSeed);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Expired.selector, T0 - 1));
        record.submitRotate(r, sig);

        r.deadline = T0 + 1 hours;
        sig = _signRotate(r, signerSeed);
        record.submitRotate(r, sig);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.AlreadyUsed.selector, r.id));
        record.submitRotate(r, sig);
        assertEq(record.signer(), signer);
    }

    // ------------------------------------------------------------------ executing

    function test_execute_refusedEarly_executedByStrangerAfter72Hours() public {
        bytes32 id = _queueRotate(next);
        uint256 readyAt = T0 + 72 hours;

        vm.expectRevert(abi.encodeWithSelector(IRateRecord.NotReady.selector, readyAt));
        record.executeRotate(id);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.NotReady.selector, readyAt));
        record.executeRotate(id);
        // Inside the delay the old signer's readings are still accepted.
        _submitSigned(readyAt - 1, signerSeed);
        _expectReadingRefused(readyAt - 1, nextSeed);

        vm.warp(readyAt);
        vm.expectEmit(true, true, true, true, address(record));
        emit IRateRecord.SignerRotated(signer, next);
        vm.prank(stranger);
        record.executeRotate(id);
        assertEq(record.signer(), next);

        // Afterwards the old signer's readings are refused and the new signer's accepted.
        _expectReadingRefused(readyAt + 1 hours, signerSeed);
        _submitSigned(readyAt + 1 hours, nextSeed);
        assertEq(record.readingCount(), 2);

        // A second execution of the same handover is void.
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Voided.selector, id));
        record.executeRotate(id);
    }

    function test_execute_unknownIdRefused() public {
        bytes32 id = keccak256("never queued");
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.NotQueued.selector, id));
        record.executeRotate(id);
        vm.warp(T0 + 100 days);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.NotQueued.selector, id));
        record.executeRotate(id);
    }

    function test_twoQueued_firstExecutedVoidsSecond() public {
        bytes32 first = _queueRotate(next);
        vm.warp(T0 + 1 hours);
        bytes32 second = _queueRotate(other);

        vm.warp(T0 + 73 hours);
        record.executeRotate(first);
        assertEq(record.signer(), next);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Voided.selector, second));
        record.executeRotate(second);
        vm.warp(T0 + 10 days);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Voided.selector, second));
        record.executeRotate(second);
        assertEq(record.signer(), next);
    }

    function test_twoQueued_secondExecutedVoidsFirst() public {
        bytes32 first = _queueRotate(next);
        vm.warp(T0 + 1 hours);
        bytes32 second = _queueRotate(other);
        vm.warp(T0 + 73 hours + 1);
        record.executeRotate(second);
        assertEq(record.signer(), other);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Voided.selector, first));
        record.executeRotate(first);
    }

    function test_handoverQueuedAfterAnExecutionIsLive() public {
        bytes32 first = _queueRotate(next);
        vm.warp(T0 + 72 hours);
        record.executeRotate(first);
        assertEq(record.signer(), next);

        // Only the new signer can queue now.
        IRateRecord.Rotate memory r = _rotate(other);
        bytes memory sig = _signRotate(r, signerSeed);
        vm.expectRevert(IRateRecord.BadSignature.selector);
        record.submitRotate(r, sig);
        sig = _signRotate(r, nextSeed);
        vm.expectEmit(true, true, true, true, address(record));
        emit IRateRecord.SignerRotationQueued(r.id, next, other, block.timestamp + 72 hours);
        record.submitRotate(r, sig);

        vm.expectRevert(abi.encodeWithSelector(IRateRecord.NotReady.selector, block.timestamp + 72 hours));
        record.executeRotate(r.id);
        vm.warp(block.timestamp + 72 hours);
        record.executeRotate(r.id);
        assertEq(record.signer(), other);
    }

    /// @dev A handover to the same address is a handover like any other: it voids the earlier ones.
    function test_handoverToSelfVoidsEarlierOnes() public {
        bytes32 toNext = _queueRotate(next);
        bytes32 toSelf = _queueRotate(signer);
        vm.warp(T0 + 72 hours);
        record.executeRotate(toSelf);
        assertEq(record.signer(), signer);
        vm.expectRevert(abi.encodeWithSelector(IRateRecord.Voided.selector, toNext));
        record.executeRotate(toNext);
    }
}
