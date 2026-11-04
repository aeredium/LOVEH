// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Market} from "../src/Market.sol";
import {ReceiptToken} from "../src/ReceiptToken.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice A token that takes a fee on transfer: receipts, collateral and repayments are credited
///         only for the amount actually received.
contract FeeOnTransferTest is BaseTest {
    FeeOnTransferToken internal fot;
    Market internal m; // fee-on-transfer loan token, plain collateral
    Market internal mc; // plain loan token, fee-on-transfer collateral

    function setUp() public override {
        super.setUp();
        fot = new FeeOnTransferToken(100); // 1 percent
        m = Market(factory.createMarket(address(fot), address(coll), address(price), LIMIT, address(linear)));
        mc = Market(factory.createMarket(address(loan), address(fot), address(price), LIMIT, address(linear)));
    }

    function _received(uint256 sent) internal pure returns (uint256) {
        return sent - sent / 100;
    }

    function test_depositMintsOnlyForAmountReceived() public {
        fot.mint(lender, 1000e18);
        vm.startPrank(lender);
        fot.approve(address(m), type(uint256).max);
        uint256 receipts = m.deposit(1000e18, lender);
        vm.stopPrank();
        assertEq(receipts, _received(1000e18) * 1e6);
        assertEq(m.deposits(), _received(1000e18));
        assertEq(m.unlent(), _received(1000e18));
        assertEq(fot.balanceOf(address(m)), _received(1000e18));
        assertEq(m.depositOf(lender), _received(1000e18));
        assertEq(ReceiptToken(m.receiptToken()).totalSupply(), receipts);
        _identity(m, fot);
    }

    function testFuzz_depositMintsOnlyForAmountReceived(uint256 amount) public {
        amount = bound(amount, 100, 1e30);
        fot.mint(lender, amount);
        vm.startPrank(lender);
        fot.approve(address(m), type(uint256).max);
        uint256 receipts = m.deposit(amount, lender);
        vm.stopPrank();
        assertEq(receipts, _received(amount) * 1e6);
        assertEq(m.deposits(), fot.balanceOf(address(m)));
        assertLe(m.depositOf(lender), fot.balanceOf(address(m)));
    }

    function test_collateralCreditedOnlyForAmountReceived() public {
        fot.mint(borrower, 10e18);
        vm.startPrank(borrower);
        fot.approve(address(mc), type(uint256).max);
        mc.depositCollateral(10e18, borrower);
        vm.stopPrank();
        assertEq(mc.collateralOf(borrower), _received(10e18));
        assertEq(mc.collateral(), fot.balanceOf(address(mc)));
        (, uint256 maxLoan) = mc.maxLoanOf(borrower);
        assertEq(maxLoan, _maxLoan(_received(10e18), PRICE));
    }

    function test_repaymentCreditedOnlyForAmountReceived() public {
        fot.mint(lender, 10_000e18);
        vm.startPrank(lender);
        fot.approve(address(m), type(uint256).max);
        m.deposit(10_000e18, lender);
        vm.stopPrank();
        _depositCollateral(m, borrower, 1e18);
        vm.prank(borrower);
        m.borrow(1000e18, borrower);
        assertEq(m.loanOf(borrower), 1000e18);
        assertEq(fot.balanceOf(borrower), _received(1000e18), "the borrower receives less; the loan is the full amount");
        // Repaying 500 credits 495.
        fot.mint(borrower, 10e18);
        vm.startPrank(borrower);
        fot.approve(address(m), type(uint256).max);
        uint256 repaid = m.repay(500e18, borrower);
        vm.stopPrank();
        assertEq(repaid, _received(500e18));
        assertApproxEqAbs(m.loanOf(borrower), 1000e18 - _received(500e18), 1);
        _identity(m, fot);
    }

    function test_liquidationCreditedOnlyForAmountReceived() public {
        fot.mint(lender, 10_000e18);
        vm.startPrank(lender);
        fot.approve(address(m), type(uint256).max);
        m.deposit(10_000e18, lender);
        vm.stopPrank();
        _depositCollateral(m, borrower, 1e18);
        vm.prank(borrower);
        m.borrow(1700e18, borrower);
        uint256 p = PRICE * 9 / 10;
        price.setPrice(p);
        fot.mint(liquidator, 1000e18);
        vm.startPrank(liquidator);
        fot.approve(address(m), type(uint256).max);
        (uint256 repaid, uint256 seized) = m.liquidate(borrower, 500e18);
        vm.stopPrank();
        assertEq(repaid, _received(500e18));
        assertEq(seized, (repaid * m.liquidationIncentive() / WAD) * PRICE_SCALE / p);
        assertApproxEqAbs(m.loanOf(borrower), 1700e18 - repaid, 1);
        _identity(m, fot);
    }

    function _identity(Market mk, MockERC20 token) internal view {
        assertEq(mk.unlent() + mk.loans(), mk.deposits() + mk.feeOwed());
        assertEq(token.balanceOf(address(mk)), mk.unlent());
    }
}
