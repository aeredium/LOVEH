// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "./Base.t.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {Market} from "../src/Market.sol";
import {ReceiptToken} from "../src/ReceiptToken.sol";
import {FreezableToken} from "./mocks/FreezableToken.sol";
import {RefusingToken} from "./mocks/RefusingToken.sol";

/// @notice A loan token whose issuer has frozen the fee recipient. The fee cannot be sent, so it stays
///         owed; a lender's withdrawal is never stopped by it, and the fee is paid once the token lets it.
contract FrozenFeeRecipientTest is BaseTest {
    FreezableToken internal frz;
    Market internal m;
    ReceiptToken internal r;

    function setUp() public override {
        super.setUp();
        frz = new FreezableToken();
        m = Market(factory.createMarket(address(frz), address(coll), address(price), LIMIT, address(linear)));
        r = ReceiptToken(m.receiptToken());
        frz.mint(lender, 10_000e18);
        vm.startPrank(lender);
        frz.approve(address(m), type(uint256).max);
        m.deposit(10_000e18, lender);
        vm.stopPrank();
        _depositCollateral(m, borrower, 1e18);
        vm.prank(borrower);
        m.borrow(1000e18, borrower);
        vm.warp(block.timestamp + YEAR);
        m.accrue();
    }

    function test_withdrawalSucceedsAndFeeStaysOwedWhenFeeRecipientIsFrozen() public {
        uint256 owed = m.feeOwed();
        assertGt(owed, 0);
        assertLt(owed, m.unlent(), "the unlent funds would allow the whole fee");
        frz.setFrozen(feeRecipient, true);

        uint256 unlentBefore = m.unlent();
        uint256 depositsBefore = m.deposits();
        vm.prank(lender);
        uint256 amount = m.withdraw(1000e18, lender);

        assertGt(amount, 0);
        assertEq(frz.balanceOf(lender), amount, "the lender received the withdrawal in full");
        assertEq(m.feeOwed(), owed, "the fee stays owed, whole");
        assertEq(m.feePaid(), 0);
        assertEq(frz.balanceOf(feeRecipient), 0);
        assertEq(m.unlent(), unlentBefore - amount, "nothing was set aside for a fee that was not sent");
        assertEq(m.deposits(), depositsBefore - amount);
        _assertIdentityFrz();
    }

    function test_noFeePaidEventWhenThePaymentIsRefused() public {
        frz.setFrozen(feeRecipient, true);
        vm.recordLogs();
        vm.prank(lender);
        m.withdraw(1000e18, lender);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feePaidTopic = keccak256("FeePaid(address,uint256)");
        assertGt(logs.length, 0);
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != feePaidTopic, "no FeePaid for a fee that was not sent");
        }
    }

    function test_everyLenderCanLeaveInFullWhileFeeRecipientIsFrozen() public {
        frz.setFrozen(feeRecipient, true);
        // The borrower repays everything, so every deposit is unlent.
        uint256 debt = m.loanOf(borrower);
        frz.mint(borrower, debt + 1e18);
        vm.startPrank(borrower);
        frz.approve(address(m), type(uint256).max);
        m.repay(debt + 1e18, borrower);
        vm.stopPrank();
        assertEq(m.loanOf(borrower), 0);

        uint256 owed = m.feeOwed();
        uint256 receipts = r.balanceOf(lender);
        vm.prank(lender);
        m.withdraw(receipts, lender);
        assertEq(r.totalSupply(), 0, "the lender left with every receipt");
        assertEq(m.feeOwed(), owed, "the fee waits in the market");
        assertEq(frz.balanceOf(address(m)), m.unlent());
        assertGe(m.unlent(), owed, "the fee owed is still held by the market");
    }

    function test_feeIsPaidOnceTheRecipientIsNoLongerFrozen() public {
        frz.setFrozen(feeRecipient, true);
        vm.prank(lender);
        m.withdraw(1000e18, lender);
        uint256 owed = m.feeOwed();

        // While frozen, the explicit payment is refused by the token and changes nothing.
        vm.expectRevert(bytes("frozen"));
        m.payFee();
        assertEq(m.feeOwed(), owed);

        frz.setFrozen(feeRecipient, false);
        // The next withdrawal pays it automatically, with its event.
        vm.expectEmit(true, false, false, true, address(m));
        emit IMarket.FeePaid(feeRecipient, owed);
        vm.prank(lender);
        m.withdraw(1e18, lender);
        assertEq(frz.balanceOf(feeRecipient), owed);
        assertEq(m.feePaid(), owed);
        assertEq(m.feeOwed(), 0);
        _assertIdentityFrz();
    }

    function test_payFeeWorksAgainAfterUnfreezing() public {
        frz.setFrozen(feeRecipient, true);
        vm.prank(lender);
        m.withdraw(1000e18, lender);
        uint256 owed = m.feeOwed();
        frz.setFrozen(feeRecipient, false);
        vm.prank(stranger);
        assertEq(m.payFee(), owed);
        assertEq(frz.balanceOf(feeRecipient), owed);
        _assertIdentityFrz();
    }

    function test_frozenReceiverStillStopsTheWithdrawalItself() public {
        // Only the fee payment is tolerant. A withdrawal to an address the token refuses still reverts.
        frz.setFrozen(stranger, true);
        vm.prank(lender);
        vm.expectRevert(bytes("frozen"));
        m.withdraw(1000e18, stranger);
    }

    function test_tokenThatReturnsFalse_feeStaysOwed() public {
        _refusingTokenCase(false);
    }

    function test_tokenThatReturnsAnOddWord_feeStaysOwed() public {
        _refusingTokenCase(true);
    }

    function _refusingTokenCase(bool oddWord) internal {
        RefusingToken rfs = new RefusingToken();
        Market rm = Market(factory.createMarket(address(rfs), address(coll), address(price), LIMIT, address(linear)));
        rfs.mint(lender, 10_000e18);
        vm.startPrank(lender);
        rfs.approve(address(rm), type(uint256).max);
        rm.deposit(10_000e18, lender);
        vm.stopPrank();
        _depositCollateral(rm, borrower, 1e18);
        vm.prank(borrower);
        rm.borrow(1000e18, borrower);
        vm.warp(block.timestamp + YEAR);
        rm.accrue();
        uint256 owed = rm.feeOwed();
        assertGt(owed, 0);

        rfs.setRefused(feeRecipient, true);
        rfs.setAnswerWithOddWord(oddWord);
        vm.prank(lender);
        uint256 amount = rm.withdraw(1000e18, lender);
        assertEq(rfs.balanceOf(lender), amount);
        assertEq(rm.feeOwed(), owed);
        assertEq(rm.feePaid(), 0);
        assertEq(rfs.balanceOf(feeRecipient), 0);
        assertEq(rfs.balanceOf(address(rm)), rm.unlent());
        assertEq(rm.unlent() + rm.loans(), rm.deposits() + rm.feeOwed());

        rfs.setRefused(feeRecipient, false);
        vm.prank(lender);
        rm.withdraw(1e18, lender);
        assertEq(rfs.balanceOf(feeRecipient), owed);
        assertEq(rm.feeOwed(), 0);
    }

    function testFuzz_withdrawalNeverStoppedByFrozenFeeRecipient(uint256 receiptAmount, uint256 wait) public {
        wait = bound(wait, 0, 5 * YEAR);
        vm.warp(block.timestamp + wait);
        frz.setFrozen(feeRecipient, true);
        // At most eight tenths of the receipts: nine tenths of the deposits are unlent.
        receiptAmount = bound(receiptAmount, 1e6, r.balanceOf(lender) * 8 / 10);
        m.accrue();
        uint256 owed = m.feeOwed();
        vm.prank(lender);
        uint256 got = m.withdraw(receiptAmount, lender);
        assertEq(frz.balanceOf(lender), got);
        assertEq(m.feeOwed(), owed);
        assertEq(m.feePaid(), 0);
        _assertIdentityFrz();
    }

    function _assertIdentityFrz() internal view {
        assertEq(m.unlent() + m.loans(), m.deposits() + m.feeOwed());
        assertEq(frz.balanceOf(address(m)), m.unlent());
    }
}
