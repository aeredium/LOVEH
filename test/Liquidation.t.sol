// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {Market} from "../src/Market.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

contract LiquidationTest is BaseTest {
    uint256 internal incentive;

    function setUp() public override {
        super.setUp();
        incentive = market.liquidationIncentive();
        _deposit(market, lender, 100_000e18);
    }

    function _seizedFor(uint256 repaid, uint256 p) internal view returns (uint256) {
        return (repaid * incentive / WAD) * PRICE_SCALE / p;
    }

    function test_refusedWithinLimit() public {
        _openPosition(borrower, 1e18, 1720e18); // exactly at the limit
        _fund(loan, liquidator, 1000e18, address(market));
        vm.prank(liquidator);
        vm.expectRevert(IMarket.NotLiquidatable.selector);
        market.liquidate(borrower, 100e18);
        // A tiny price fall puts it above the limit.
        price.setPrice(PRICE - 1e30);
        vm.prank(liquidator);
        market.liquidate(borrower, 100e18);
    }

    function test_refusedWithoutLoanOrWithBadArguments() public {
        _fund(loan, liquidator, 1000e18, address(market));
        vm.startPrank(liquidator);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.liquidate(address(0), 1);
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.liquidate(borrower, 0);
        vm.expectRevert(IMarket.NoLoan.selector);
        market.liquidate(borrower, 1);
        vm.stopPrank();
    }

    function test_allowedAboveLimit_collateralEqualsRepayTimesIncentiveAtPrice() public {
        _openPosition(borrower, 1e18, 1700e18);
        uint256 p = PRICE * 9 / 10; // limit becomes 1548 < 1700
        price.setPrice(p);
        uint256 repayAmount = 500e18;
        uint256 expectedSeized = _seizedFor(repayAmount, p);
        _fund(loan, liquidator, repayAmount, address(market));
        vm.expectEmit(true, true, true, true);
        emit IMarket.Liquidated(liquidator, borrower, repayAmount, expectedSeized);
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, repayAmount);
        assertEq(repaid, repayAmount);
        assertEq(seized, expectedSeized);
        assertEq(coll.balanceOf(liquidator), expectedSeized);
        assertEq(market.collateralOf(borrower), 1e18 - expectedSeized);
        assertEq(market.collateral(), 1e18 - expectedSeized);
        assertApproxEqAbs(market.loanOf(borrower), 1200e18, 1);
        assertEq(market.totalLoss(), 0);
        _assertIdentity(market);
        // The value seized is repay * incentive at the price, to rounding.
        assertApproxEqAbs(seized * p / PRICE_SCALE, repayAmount * incentive / WAD, 1e6);
    }

    function test_repayCappedToWholeLoan() public {
        _openPosition(borrower, 1e18, 1700e18);
        price.setPrice(PRICE * 9 / 10);
        uint256 owed = market.loanOf(borrower);
        (uint256 repaid, uint256 seized) = _liquidate(market, liquidator, borrower, owed * 2);
        assertEq(repaid, owed);
        assertEq(loan.balanceOf(liquidator), owed); // the rest never left the liquidator
        assertEq(market.loanOf(borrower), 0);
        assertEq(market.borrowerCount(), 0);
        assertGt(market.collateralOf(borrower), 0);
        assertEq(seized, _seizedFor(owed, PRICE * 9 / 10));
        _assertIdentity(market);
    }

    function test_lossWrittenOffWhenCollateralRunsOut() public {
        _openPosition(borrower, 1e18, 1700e18);
        uint256 depositsBefore = market.deposits();
        uint256 receiptValueBefore = market.valueOf(1e24);
        // Price halves: collateral worth 1000, loan 1700.
        uint256 p = PRICE / 2;
        price.setPrice(p);
        // The liquidator repays 1000; collateral worth 1043.8 is more than there is, so all 1 unit is seized.
        uint256 repayAmount = 1000e18;
        assertGt(_seizedFor(repayAmount, p), 1e18);
        uint256 expectedLoss = 700e18;
        _fund(loan, liquidator, repayAmount, address(market));
        vm.expectEmit(true, true, true, true);
        emit IMarket.LossWrittenOff(borrower, expectedLoss, expectedLoss, 0);
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, repayAmount);
        assertEq(repaid, repayAmount);
        assertEq(seized, 1e18);
        assertEq(market.collateralOf(borrower), 0);
        assertEq(market.loanOf(borrower), 0);
        assertEq(market.loanUnitsOf(borrower), 0);
        assertEq(market.borrowerCount(), 0);
        assertEq(market.loans(), 0);
        assertEq(market.totalLoanUnits(), 0);
        assertEq(market.totalLoss(), expectedLoss);
        assertEq(market.deposits(), depositsBefore - expectedLoss);
        assertLt(market.valueOf(1e24), receiptValueBefore);
        _assertIdentity(market);
    }

    function test_lossBeyondDepositsReducesUnpaidFeeOnly() public {
        // A market whose only lender's deposit is fully lent, so interest makes the loan exceed the deposits.
        Market m = Market(factory.createMarket(address(loan), address(coll), address(price), 0.5e18, address(linear)));
        _deposit(m, lender2, 1000e18);
        _depositCollateral(m, borrower2, 1e18);
        _borrow(m, borrower2, 1000e18);
        skip(10 * YEAR); // loans > deposits + unlent now; fee owed > unlent (which is zero)
        m.accrue();
        assertEq(m.unlent(), 0);
        assertGt(m.loans(), m.deposits());
        uint256 feeOwedBefore = m.feeOwed();
        uint256 depositsBefore = m.deposits();
        uint256 loanBefore = m.loanOf(borrower2);
        price.setPrice(1); // collateral worth nothing
        _fund(loan, liquidator, 1, address(m));
        vm.expectEmit(true, true, true, true);
        emit IMarket.LossWrittenOff(borrower2, loanBefore - 1, depositsBefore, loanBefore - 1 - depositsBefore);
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = m.liquidate(borrower2, 1);
        assertEq(repaid, 1);
        assertEq(seized, 1e18);
        assertEq(m.loans(), 0);
        assertEq(m.deposits(), 0, "every deposit is lost");
        assertEq(m.totalLoss(), depositsBefore, "loss to lenders is every deposit");
        assertEq(m.feeWrittenOff(), loanBefore - 1 - depositsBefore);
        assertEq(m.feeWrittenOff(), feeOwedBefore - m.feeOwed());
        assertGt(m.feeWrittenOff(), 0);
        assertEq(m.feeOwed(), 1); // the one unit repaid backs one unit of fee
        assertEq(m.unlent(), 1);
        _assertIdentity(m);
        price.setPrice(PRICE);
    }

    function test_lossNeverTouchesAnotherMarket() public {
        Market other =
            Market(factory.createMarket(address(loan), address(coll), address(price), 0.5e18, address(linear)));
        _deposit(other, lender2, 5000e18);
        _depositCollateral(other, borrower2, 2e18);
        _borrow(other, borrower2, 1000e18);
        uint256 otherDeposits = other.deposits();
        uint256 otherLoans = other.loans();
        uint256 otherUnlent = other.unlent();
        uint256 otherCollateral = other.collateral();
        uint256 otherValue = other.valueOf(1e24);

        _openPosition(borrower, 1e18, 1700e18);
        price.setPrice(PRICE / 2);
        _liquidate(market, liquidator, borrower, 1000e18);
        assertEq(market.totalLoss(), 700e18);

        assertEq(other.totalLoss(), 0);
        assertEq(other.deposits(), otherDeposits);
        assertEq(other.loans(), otherLoans);
        assertEq(other.unlent(), otherUnlent);
        assertEq(other.collateral(), otherCollateral);
        assertEq(other.valueOf(1e24), otherValue);
        assertEq(other.loanOf(borrower2), 1000e18);
        _assertIdentity(other);
    }

    function test_priceZeroOrFailingNeverPermitsLiquidation() public {
        _openPosition(borrower, 1e18, 1700e18);
        _fund(loan, liquidator, 1000e18, address(market));
        price.setPrice(0);
        vm.prank(liquidator);
        vm.expectRevert(IMarket.PriceUnavailable.selector);
        market.liquidate(borrower, 100e18);
        price.setPrice(PRICE);
        price.setReverting(true);
        vm.prank(liquidator);
        vm.expectRevert(IMarket.PriceUnavailable.selector);
        market.liquidate(borrower, 100e18);
        price.setReverting(false);
        price.setMalformed(true);
        vm.prank(liquidator);
        vm.expectRevert(IMarket.PriceUnavailable.selector);
        market.liquidate(borrower, 100e18);
    }

    function test_anyoneCanLiquidate_nobodyCanStopIt() public {
        _openPosition(borrower, 1e18, 1700e18);
        price.setPrice(PRICE * 9 / 10);
        // The borrower, the lender, a stranger: all may liquidate; nobody has a say.
        _liquidate(market, stranger, borrower, 10e18);
        _liquidate(market, lender, borrower, 10e18);
        _liquidate(market, borrower, borrower, 10e18);
        assertEq(coll.balanceOf(stranger), _seizedFor(10e18, PRICE * 9 / 10));
    }

    function test_interestAccruedMakesLoanLiquidatable() public {
        _openPosition(borrower, 1e18, 1720e18); // at the limit
        skip(1 days);
        assertGt(market.loanOf(borrower), 1720e18);
        (bool ok, address[] memory who,,) = market.loansAboveLimit(0, 10);
        assertTrue(ok);
        assertEq(who.length, 1);
        _liquidate(market, liquidator, borrower, 1e18);
    }

    function testFuzz_liquidation(uint256 loanAmount, uint256 priceDrop, uint256 repayAmount) public {
        loanAmount = bound(loanAmount, 1e18, 1720e18);
        priceDrop = bound(priceDrop, 1, 99);
        _openPosition(borrower, 1e18, loanAmount);
        uint256 p = PRICE * (100 - priceDrop) / 100;
        price.setPrice(p);
        uint256 owed = market.loanOf(borrower);
        bool above = owed > _maxLoan(1e18, p);
        repayAmount = bound(repayAmount, 1, owed * 2);
        _fund(loan, liquidator, repayAmount, address(market));
        if (!above) {
            vm.prank(liquidator);
            vm.expectRevert(IMarket.NotLiquidatable.selector);
            market.liquidate(borrower, repayAmount);
            return;
        }
        uint256 collBefore = market.collateral();
        uint256 depositsBefore = market.deposits();
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, repayAmount);
        assertEq(repaid, repayAmount < owed ? repayAmount : owed);
        uint256 expected = _seizedFor(repaid, p);
        if (expected >= 1e18) {
            assertEq(seized, 1e18);
            assertEq(market.collateralOf(borrower), 0);
            assertEq(market.loanOf(borrower), 0);
            assertEq(market.totalLoss(), depositsBefore - market.deposits());
        } else {
            assertEq(seized, expected);
            assertEq(market.totalLoss(), 0);
        }
        assertEq(coll.balanceOf(liquidator), seized);
        assertEq(market.collateral(), collBefore - seized);
        _assertIdentity(market);
    }
}
