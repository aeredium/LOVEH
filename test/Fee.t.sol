// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {IMarket} from "../interfaces/IMarket.sol";

contract FeeTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 800e18);
        skip(YEAR);
    }

    function test_feeOwedIsTenPercentOfInterest() public view {
        assertGt(market.totalInterest(), 0);
        assertEq(market.feeOwed(), market.totalInterest() / 10);
        assertEq(market.feePaid(), 0);
    }

    function test_payFee_byAnyone_onlyToRecipient_onlyInLoanToken() public {
        uint256 owed = market.feeOwed();
        uint256 collBefore = coll.balanceOf(feeRecipient);
        vm.expectEmit(true, true, true, true);
        emit IMarket.FeePaid(feeRecipient, owed);
        vm.prank(stranger);
        uint256 paid = market.payFee();
        assertEq(paid, owed);
        assertEq(loan.balanceOf(feeRecipient), owed, "paid in the loan token to the fee recipient");
        assertEq(coll.balanceOf(feeRecipient), collBefore, "nothing in any other token");
        assertEq(loan.balanceOf(stranger), 0, "the caller receives nothing");
        assertEq(market.feeOwed(), 0);
        assertEq(market.feePaid(), owed);
        _assertIdentity(market);
        // Nothing more to pay.
        vm.prank(lender);
        assertEq(market.payFee(), 0);
    }

    function test_payFee_limitedToUnlent() public {
        // Borrow the rest so nothing is unlent, then accrue: the fee waits.
        _depositCollateral(market, borrower2, 10e18);
        uint256 rest = market.unlent();
        _borrow(market, borrower2, rest);
        assertEq(market.unlent(), 0);
        skip(YEAR);
        uint256 owed = market.feeOwed();
        assertGt(owed, 0);
        assertEq(market.payFee(), 0);
        assertEq(market.feeOwed(), owed);
        // A repayment of 1 makes 1 unit of unlent: the fee is paid up to that.
        _repay(market, stranger, 1, borrower);
        assertEq(market.payFee(), 1);
        assertEq(market.feeOwed(), owed - 1);
        assertEq(loan.balanceOf(feeRecipient), 1);
        _assertIdentity(market);
    }

    function test_withdrawPaysFeeWhenUnlentAllows() public {
        uint256 owed = market.feeOwed();
        uint256 receipts = receipt.balanceOf(lender);
        // unlent is 200; withdraw 100 leaves enough for the fee.
        vm.prank(lender);
        market.withdraw(receipts / 10, lender);
        assertEq(loan.balanceOf(feeRecipient), owed);
        assertEq(market.feeOwed(), 0);
        assertEq(market.feePaid(), owed);
        _assertIdentity(market);
    }

    function test_withdrawPaysFeePartlyWhenUnlentShort() public {
        uint256 owed = market.feeOwed();
        uint256 unlentBefore = market.unlent();
        // Withdraw everything unlent but one unit: the fee is paid with that one unit.
        uint256 receipts = market.receiptsFor(unlentBefore - 1);
        vm.prank(lender);
        uint256 amount = market.withdraw(receipts, lender);
        assertLe(amount, unlentBefore - 1);
        assertEq(loan.balanceOf(feeRecipient), unlentBefore - amount);
        assertEq(market.feeOwed(), owed - (unlentBefore - amount));
        assertEq(market.unlent(), 0);
        _assertIdentity(market);
    }

    function test_feeRecipientCannotBeRedirected() public view {
        // The recipient is an immutable with no setter; see FixedTerms.t.sol for the surface check.
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(factory.feeRecipient(), feeRecipient);
    }

    function testFuzz_feePaidPlusOwedIsTenPercent(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1, 200 days);
        b = bound(b, 1, 200 days);
        c = bound(c, 1, 200 days);
        skip(a);
        market.payFee();
        skip(b);
        _repay(market, stranger, 100e18, borrower);
        market.payFee();
        skip(c);
        vm.prank(lender);
        market.withdraw(1e18, lender);
        assertEq(market.feePaid() + market.feeOwed(), market.totalInterest() / 10);
        assertEq(loan.balanceOf(feeRecipient), market.feePaid());
        _assertIdentity(market);
    }
}
