// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {Market} from "../src/Market.sol";
import {FreezableToken} from "./mocks/FreezableToken.sol";

/// @notice A loan token that can freeze an address (as some stablecoins do). A frozen borrower cannot
///         borrow or receive; their position can still be liquidated by anyone.
contract FrozenAddressTest is BaseTest {
    FreezableToken internal frz;
    Market internal m;

    function setUp() public override {
        super.setUp();
        frz = new FreezableToken();
        m = Market(factory.createMarket(address(frz), address(coll), address(price), LIMIT, address(linear)));
        frz.mint(lender, 10_000e18);
        vm.startPrank(lender);
        frz.approve(address(m), type(uint256).max);
        m.deposit(10_000e18, lender);
        vm.stopPrank();
        _depositCollateral(m, borrower, 1e18);
    }

    function test_frozenBorrowerCannotBorrowOrReceive() public {
        frz.setFrozen(borrower, true);
        vm.prank(borrower);
        vm.expectRevert(bytes("frozen"));
        m.borrow(100e18, borrower);
        // Nor can anyone else make the loan token reach the frozen address through the market.
        vm.prank(lender);
        vm.expectRevert(bytes("frozen"));
        m.withdraw(1e18, borrower);
        assertEq(m.loans(), 0);
        assertEq(m.borrowerCount(), 0);
        _assertIdentityFrz();
    }

    function test_frozenReceiverCannotReceive() public {
        frz.setFrozen(stranger, true);
        vm.prank(borrower);
        vm.expectRevert(bytes("frozen"));
        m.borrow(100e18, stranger);
        // The market's accounting is untouched by the refused borrow.
        assertEq(m.loans(), 0);
        assertEq(m.borrowerCount(), 0);
        _assertIdentityFrz();
    }

    function test_frozenBorrowerCanStillBeLiquidated() public {
        vm.prank(borrower);
        m.borrow(1700e18, borrower);
        frz.setFrozen(borrower, true);
        // The frozen borrower can no longer repay (their transfers are frozen)...
        vm.prank(borrower);
        frz.approve(address(m), type(uint256).max);
        vm.prank(borrower);
        vm.expectRevert(bytes("frozen"));
        m.repay(100e18, borrower);
        // ...but anyone can liquidate once the price falls, since the loan token moves from the liquidator.
        price.setPrice(PRICE * 9 / 10);
        frz.mint(liquidator, 1000e18);
        vm.startPrank(liquidator);
        frz.approve(address(m), type(uint256).max);
        (uint256 repaid, uint256 seized) = m.liquidate(borrower, 500e18);
        vm.stopPrank();
        assertEq(repaid, 500e18);
        assertGt(seized, 0);
        assertEq(coll.balanceOf(liquidator), seized);
        assertApproxEqAbs(m.loanOf(borrower), 1200e18, 1);
        _assertIdentityFrz();
        // And the whole position can be closed by liquidation, loss and all, with the borrower still frozen.
        price.setPrice(PRICE / 4);
        vm.prank(liquidator);
        m.liquidate(borrower, 500e18);
        assertEq(m.loanOf(borrower), 0);
        assertEq(m.collateralOf(borrower), 0);
        assertGt(m.totalLoss(), 0);
        _assertIdentityFrz();
    }

    function test_frozenBorrowerCollateralStillLeavesToLiquidatorNotBorrower() public {
        vm.prank(borrower);
        m.borrow(1700e18, borrower);
        frz.setFrozen(borrower, true);
        price.setPrice(PRICE * 9 / 10);
        frz.mint(liquidator, 2000e18);
        vm.startPrank(liquidator);
        frz.approve(address(m), type(uint256).max);
        m.liquidate(borrower, 1700e18);
        vm.stopPrank();
        assertEq(m.loanOf(borrower), 0);
        assertEq(coll.balanceOf(borrower), 0);
        assertEq(
            frz.balanceOf(borrower), 1700e18, "the frozen borrower keeps what they borrowed; nothing moved to them"
        );
    }

    function _assertIdentityFrz() internal view {
        assertEq(m.unlent() + m.loans(), m.deposits() + m.feeOwed());
        assertEq(frz.balanceOf(address(m)), m.unlent());
    }
}
