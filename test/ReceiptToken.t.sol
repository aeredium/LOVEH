// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {IReceiptToken} from "../interfaces/IReceiptToken.sol";
import {ReceiptToken} from "../src/ReceiptToken.sol";

contract ReceiptTokenTest is BaseTest {
    uint256 internal receipts;

    function setUp() public override {
        super.setUp();
        receipts = _deposit(market, lender, 100e18);
    }

    function test_onlyMarketMintsAndBurns() public {
        vm.prank(stranger);
        vm.expectRevert(IReceiptToken.NotMarket.selector);
        receipt.mint(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(IReceiptToken.NotMarket.selector);
        receipt.burn(lender, 1);
        vm.prank(lender);
        vm.expectRevert(IReceiptToken.NotMarket.selector);
        receipt.mint(lender, 1);
        // The market itself cannot mint to nobody.
        vm.prank(address(market));
        vm.expectRevert(IReceiptToken.ZeroAddress.selector);
        receipt.mint(address(0), 1);
        vm.prank(address(market));
        vm.expectRevert(IReceiptToken.InsufficientBalance.selector);
        receipt.burn(lender, receipts + 1);
    }

    function test_transfer() public {
        vm.prank(lender);
        vm.expectEmit(true, true, true, true);
        emit IReceiptToken.Transfer(lender, lender2, receipts / 4);
        assertTrue(receipt.transfer(lender2, receipts / 4));
        assertEq(receipt.balanceOf(lender), receipts - receipts / 4);
        assertEq(receipt.balanceOf(lender2), receipts / 4);
        assertEq(receipt.totalSupply(), receipts);
        // The receiver can withdraw with them: the claim travels with the receipt.
        vm.prank(lender2);
        assertEq(market.withdraw(receipts / 4, lender2), 25e18);
        vm.prank(lender);
        vm.expectRevert(IReceiptToken.InsufficientBalance.selector);
        receipt.transfer(lender2, receipts);
        vm.prank(lender);
        vm.expectRevert(IReceiptToken.ZeroAddress.selector);
        receipt.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(lender);
        vm.expectEmit(true, true, true, true);
        emit IReceiptToken.Approval(lender, stranger, receipts / 2);
        assertTrue(receipt.approve(stranger, receipts / 2));
        assertEq(receipt.allowance(lender, stranger), receipts / 2);
        vm.prank(stranger);
        vm.expectRevert(IReceiptToken.InsufficientAllowance.selector);
        receipt.transferFrom(lender, stranger, receipts / 2 + 1);
        vm.prank(stranger);
        assertTrue(receipt.transferFrom(lender, stranger, receipts / 2));
        assertEq(receipt.allowance(lender, stranger), 0);
        assertEq(receipt.balanceOf(stranger), receipts / 2);
        vm.prank(lender);
        vm.expectRevert(IReceiptToken.ZeroAddress.selector);
        receipt.approve(address(0), 1);
    }

    function test_infiniteAllowanceIsNotReduced() public {
        vm.prank(lender);
        receipt.approve(stranger, type(uint256).max);
        vm.prank(stranger);
        receipt.transferFrom(lender, lender2, receipts / 10);
        assertEq(receipt.allowance(lender, stranger), type(uint256).max);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, receipts);
        vm.prank(lender);
        receipt.transfer(lender2, amount);
        assertEq(receipt.balanceOf(lender) + receipt.balanceOf(lender2), receipts);
        assertEq(receipt.totalSupply(), receipts);
    }
}
