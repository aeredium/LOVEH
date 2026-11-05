// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Market} from "../src/Market.sol";
import {ReceiptToken} from "../src/ReceiptToken.sol";

/// @notice Two markets with the same tokens and different terms: activity in one leaves the other's
///         figures unchanged.
contract IsolationTest is BaseTest {
    Market internal other;

    struct Figures {
        uint256 deposits;
        uint256 loans;
        uint256 unlent;
        uint256 collateral;
        uint256 collateralValue;
        uint256 feePaid;
        uint256 feeOwed;
        uint256 totalInterest;
        uint256 totalLoss;
        uint256 totalReceipts;
        uint256 receiptValue;
        uint256 borrowerCount;
        uint256 loanOfBorrower;
        uint256 balance;
        uint256 collBalance;
    }

    function setUp() public override {
        super.setUp();
        other = Market(factory.createMarket(address(loan), address(coll), address(price), 0.5e18, address(kinked)));
        assertTrue(other.receiptToken() != market.receiptToken());
        // Both markets get some life.
        _deposit(market, lender, 10_000e18);
        _openPosition(borrower, 2e18, 2000e18);
        _deposit(other, lender2, 10_000e18);
        _depositCollateral(other, borrower2, 2e18);
        _borrow(other, borrower2, 1000e18);
        skip(30 days);
        market.accrue();
        other.accrue();
    }

    function _figures(Market m, address b) internal view returns (Figures memory f) {
        f.deposits = m.deposits();
        f.loans = m.loans();
        f.unlent = m.unlent();
        f.collateral = m.collateral();
        (, f.collateralValue) = m.collateralValue();
        f.feePaid = m.feePaid();
        f.feeOwed = m.feeOwed();
        f.totalInterest = m.totalInterest();
        f.totalLoss = m.totalLoss();
        f.totalReceipts = m.totalReceipts();
        f.receiptValue = m.valueOf(1e24);
        f.borrowerCount = m.borrowerCount();
        f.loanOfBorrower = m.loanOf(b);
        f.balance = loan.balanceOf(address(m));
        f.collBalance = coll.balanceOf(address(m));
    }

    function _assertSame(Figures memory a, Figures memory b) internal pure {
        assertEq(a.deposits, b.deposits, "deposits");
        assertEq(a.loans, b.loans, "loans");
        assertEq(a.unlent, b.unlent, "unlent");
        assertEq(a.collateral, b.collateral, "collateral");
        assertEq(a.collateralValue, b.collateralValue, "collateral value");
        assertEq(a.feePaid, b.feePaid, "fee paid");
        assertEq(a.feeOwed, b.feeOwed, "fee owed");
        assertEq(a.totalInterest, b.totalInterest, "interest");
        assertEq(a.totalLoss, b.totalLoss, "loss");
        assertEq(a.totalReceipts, b.totalReceipts, "receipts");
        assertEq(a.receiptValue, b.receiptValue, "receipt value");
        assertEq(a.borrowerCount, b.borrowerCount, "borrowers");
        assertEq(a.loanOfBorrower, b.loanOfBorrower, "loan of borrower");
        assertEq(a.balance, b.balance, "loan token balance");
        assertEq(a.collBalance, b.collBalance, "collateral balance");
    }

    function test_activityInOneLeavesTheOtherUnchanged() public {
        Figures memory before = _figures(other, borrower2);
        // Every kind of action in `market`.
        _deposit(market, stranger, 500e18);
        _openPosition(stranger, 1e18, 100e18);
        _repay(market, stranger, 50e18, borrower);
        vm.prank(lender);
        market.withdraw(1e24, lender);
        vm.prank(stranger);
        market.withdrawCollateral(0.1e18, stranger);
        market.payFee();
        price.setPrice(PRICE / 4);
        _liquidate(market, liquidator, borrower, 1500e18);
        assertGt(market.totalLoss(), 0);
        price.setPrice(PRICE);
        _assertSame(_figures(other, borrower2), before);
        _assertIdentity(other);
        _assertIdentity(market);
    }

    function test_activityInTheOtherLeavesThisUnchanged() public {
        Figures memory before = _figures(market, borrower);
        _deposit(other, stranger, 500e18);
        _depositCollateral(other, stranger, 1e18);
        _borrow(other, stranger, 100e18);
        _repay(other, stranger, 50e18, borrower2);
        other.payFee();
        price.setPrice(PRICE / 4);
        _liquidate(other, liquidator, borrower2, 900e18);
        assertGt(other.totalLoss(), 0);
        price.setPrice(PRICE);
        _assertSame(_figures(market, borrower), before);
    }

    function test_receiptsAreNotInterchangeable() public {
        ReceiptToken mine = ReceiptToken(market.receiptToken());
        uint256 bal = mine.balanceOf(lender);
        assertGt(bal, 0);
        vm.prank(lender);
        vm.expectRevert();
        other.withdraw(bal, lender); // lender holds no receipts of `other`
        assertEq(ReceiptToken(other.receiptToken()).balanceOf(lender), 0);
    }

    function test_sameTermsDifferentLimitsAreDifferentIncentives() public view {
        assertTrue(market.liquidationIncentive() != other.liquidationIncentive());
        assertEq(market.feeRecipient(), other.feeRecipient());
    }
}
