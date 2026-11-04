// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BaseTest} from "./Base.t.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IReceiptToken} from "../interfaces/IReceiptToken.sol";
import {Market} from "../src/Market.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MarketTest is BaseTest {
    // ------------------------------------------------------------------ terms

    function test_terms() public view {
        assertEq(market.loanToken(), address(loan));
        assertEq(market.collateralToken(), address(coll));
        assertEq(market.priceSource(), address(price));
        assertEq(market.borrowingLimit(), LIMIT);
        assertEq(market.rateFormula(), address(linear));
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(market.FEE(), 0.1e18);
        assertEq(receipt.market(), address(market));
        assertEq(receipt.decimals(), 24);
        assertEq(receipt.name(), "LOVEH Receipt");
        assertEq(receipt.symbol(), "LOVEH-R");
        assertEq(market.lastAccrual(), block.timestamp);
    }

    function test_liquidationIncentive_formula() public view {
        // 1 / (0.3 * 0.86 + 0.7) = 1 / 0.958 = 1.04384...
        uint256 expected = 1e36 / (0.3e18 * LIMIT / 1e18 + 0.7e18);
        assertEq(market.liquidationIncentive(), expected);
        assertApproxEqRel(market.liquidationIncentive(), 1.0438e18, 1e14);
    }

    function test_liquidationIncentive_capped() public {
        Market m = new Market(address(loan), address(coll), address(price), 0.01e18, address(linear), feeRecipient);
        // 1 / (0.003 + 0.7) = 1.4225 > 1.15 so the cap applies.
        assertEq(m.liquidationIncentive(), 1.15e18);
    }

    function testFuzz_liquidationIncentive(uint256 limit) public {
        limit = bound(limit, 1, WAD - 1);
        Market m = new Market(address(loan), address(coll), address(price), limit, address(linear), feeRecipient);
        uint256 raw = 1e36 / (0.3e18 * limit / 1e18 + 0.7e18);
        uint256 expected = raw < 1.15e18 ? raw : 1.15e18;
        assertEq(m.liquidationIncentive(), expected);
        assertGe(m.liquidationIncentive(), WAD);
        assertLe(m.liquidationIncentive(), 1.15e18);
    }

    function test_constructor_rejects() public {
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(address(0), address(coll), address(price), LIMIT, address(linear), feeRecipient);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(address(loan), address(0), address(price), LIMIT, address(linear), feeRecipient);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(address(loan), address(coll), address(0), LIMIT, address(linear), feeRecipient);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(address(loan), address(coll), address(price), LIMIT, address(0), feeRecipient);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        new Market(address(loan), address(coll), address(price), LIMIT, address(linear), address(0));
        vm.expectRevert(IMarket.SameToken.selector);
        new Market(address(loan), address(loan), address(price), LIMIT, address(linear), feeRecipient);
        vm.expectRevert(IMarket.InvalidBorrowingLimit.selector);
        new Market(address(loan), address(coll), address(price), 0, address(linear), feeRecipient);
        vm.expectRevert(IMarket.InvalidBorrowingLimit.selector);
        new Market(address(loan), address(coll), address(price), WAD, address(linear), feeRecipient);
    }

    function test_receiptDecimals_fallbackWhenTokenHasNone() public {
        // A loan token with no decimals() falls back to 18 + 6.
        address noDecimals = makeAddr("token without decimals()");
        vm.etch(noDecimals, hex"00");
        Market m = new Market(noDecimals, address(coll), address(price), LIMIT, address(linear), feeRecipient);
        assertEq(IReceiptToken(m.receiptToken()).decimals(), 24);
        MockERC20 six = new MockERC20("Six", "SIX", 6);
        Market m6 = new Market(address(six), address(coll), address(price), LIMIT, address(linear), feeRecipient);
        assertEq(IReceiptToken(m6.receiptToken()).decimals(), 12);
    }

    // ------------------------------------------------------------------ deposit and withdraw

    function test_deposit_mintsReceipts() public {
        uint256 receipts = _deposit(market, lender, 100e18);
        assertEq(receipts, 100e18 * 1e6);
        assertEq(receipt.balanceOf(lender), receipts);
        assertEq(market.deposits(), 100e18);
        assertEq(market.unlent(), 100e18);
        assertEq(market.depositOf(lender), 100e18);
        assertEq(loan.balanceOf(address(market)), 100e18);
        _assertIdentity(market);
    }

    function test_deposit_onBehalf() public {
        _fund(loan, lender, 10e18, address(market));
        vm.prank(lender);
        market.deposit(10e18, lender2);
        assertEq(receipt.balanceOf(lender2), 10e18 * 1e6);
        assertEq(receipt.balanceOf(lender), 0);
    }

    function test_deposit_rejects() public {
        _fund(loan, lender, 10e18, address(market));
        vm.startPrank(lender);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.deposit(1e18, address(0));
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.deposit(0, lender);
        vm.stopPrank();
    }

    function test_withdraw_returnsValue() public {
        uint256 receipts = _deposit(market, lender, 100e18);
        vm.prank(lender);
        uint256 amount = market.withdraw(receipts / 2, lender2);
        assertEq(amount, 50e18);
        assertEq(loan.balanceOf(lender2), 50e18);
        assertEq(receipt.balanceOf(lender), receipts / 2);
        assertEq(market.deposits(), 50e18);
        _assertIdentity(market);
    }

    function test_withdraw_rejects() public {
        uint256 receipts = _deposit(market, lender, 100e18);
        vm.startPrank(lender);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.withdraw(1, address(0));
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.withdraw(0, lender);
        vm.expectRevert(IMarket.InsufficientReceipts.selector);
        market.withdraw(receipts + 1, lender);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(IMarket.InsufficientReceipts.selector);
        market.withdraw(1, stranger);
    }

    function test_withdraw_refusedOnlyWhenUnlentShort() public {
        uint256 receipts = _deposit(market, lender, 100e18);
        _openPosition(borrower, 1e18, 60e18);
        assertEq(market.unlent(), 40e18);
        vm.prank(lender);
        vm.expectRevert(IMarket.InsufficientUnlent.selector);
        market.withdraw(receipts / 2, lender); // 50 > 40 unlent
        vm.prank(lender);
        market.withdraw(receipts * 40 / 100, lender); // exactly the unlent
        assertEq(market.unlent(), 0);
        _assertIdentity(market);
    }

    function test_receiptValueGrowsWithInterest() public {
        uint256 receipts = _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 500e18);
        skip(YEAR);
        // utilisation 50 percent on a 10 percent a year slope: 5 percent on 500 = 25 interest, 22.5 to lenders.
        uint256 interest = 500e18 * linear.ratePerSecond(500e18, 1000e18) * YEAR / WAD;
        assertApproxEqRel(interest, 25e18, 1e9);
        assertEq(market.loans(), 500e18 + interest);
        assertEq(market.deposits(), 1000e18 + interest - interest / 10);
        assertEq(market.feeOwed(), interest / 10);
        assertApproxEqAbs(market.valueOf(receipts), 1000e18 + interest - interest / 10, 1); // paid out rounded down
        _assertIdentity(market);
    }

    function test_firstDepositInflationAttackFails() public {
        // Attacker deposits 1 wei and donates 1e24 directly to the market.
        _deposit(market, stranger, 1);
        loan.mint(address(market), 1e24);
        // Victim deposits 1e18 and must get receipts worth (almost) 1e18 back; the donation is credited to nobody.
        uint256 receipts = _deposit(market, lender, 1e18);
        assertGt(receipts, 0);
        assertApproxEqAbs(market.valueOf(receipts), 1e18, 1);
        assertEq(market.deposits(), 1e18 + 1);
        // Attacker gains nothing from the donation.
        assertLe(market.depositOf(stranger), 2);
    }

    function testFuzz_depositWithdrawRoundTrip_neverFavoursLender(uint256 amount, uint256 donation) public {
        amount = bound(amount, 1, 1e30);
        donation = bound(donation, 0, 1e30);
        loan.mint(address(market), donation);
        uint256 receipts = _deposit(market, lender, amount);
        vm.prank(lender);
        uint256 back = market.withdraw(receipts, lender);
        assertLe(back, amount);
        assertGe(back + 1, amount);
    }

    // ------------------------------------------------------------------ collateral

    function test_collateral_depositAndWithdraw() public {
        _depositCollateral(market, borrower, 3e18);
        assertEq(market.collateralOf(borrower), 3e18);
        assertEq(market.collateral(), 3e18);
        (bool ok, uint256 value) = market.collateralValue();
        assertTrue(ok);
        assertEq(value, 6000e18);
        vm.prank(borrower);
        market.withdrawCollateral(1e18, stranger);
        assertEq(coll.balanceOf(stranger), 1e18);
        assertEq(market.collateralOf(borrower), 2e18);
        assertEq(market.collateral(), 2e18);
    }

    function test_collateral_rejects() public {
        _depositCollateral(market, borrower, 1e18);
        vm.startPrank(borrower);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.depositCollateral(1, address(0));
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.depositCollateral(0, borrower);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.withdrawCollateral(1, address(0));
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.withdrawCollateral(0, borrower);
        vm.expectRevert(IMarket.InsufficientCollateral.selector);
        market.withdrawCollateral(1e18 + 1, borrower);
        vm.stopPrank();
    }

    function test_withdrawCollateral_refusedAboveLimit() public {
        _deposit(market, lender, 10_000e18);
        _openPosition(borrower, 1e18, 1000e18); // max is 1720
        // Leaving 0.5 collateral allows 860; the loan of 1000 would be above the limit.
        vm.prank(borrower);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.withdrawCollateral(0.5e18, borrower);
        // Leaving 0.6 allows 1032 >= 1000.
        vm.prank(borrower);
        market.withdrawCollateral(0.4e18, borrower);
        assertEq(market.collateralOf(borrower), 0.6e18);
    }

    function test_withdrawCollateral_refusedWhenPriceZeroOrFailing_evenWithNoLoan() public {
        _depositCollateral(market, borrower, 1e18);
        price.setPrice(0);
        vm.prank(borrower);
        vm.expectRevert(IMarket.PriceUnavailable.selector);
        market.withdrawCollateral(1, borrower);
        price.setPrice(PRICE);
        price.setReverting(true);
        vm.prank(borrower);
        vm.expectRevert(IMarket.PriceUnavailable.selector);
        market.withdrawCollateral(1, borrower);
        price.setReverting(false);
        price.setMalformed(true);
        vm.prank(borrower);
        vm.expectRevert(IMarket.PriceUnavailable.selector);
        market.withdrawCollateral(1, borrower);
        price.setMalformed(false);
        vm.prank(borrower);
        market.withdrawCollateral(1, borrower);
    }

    function test_priceSourceWithoutCodeIsUnavailable() public {
        address dead = makeAddr("dead price source");
        Market m = new Market(address(loan), address(coll), dead, LIMIT, address(linear), feeRecipient);
        (bool ok, uint256 value) = m.collateralValue();
        assertFalse(ok);
        assertEq(value, 0);
        (bool ok2,) = m.maxLoanOf(borrower);
        assertFalse(ok2);
    }

    // ------------------------------------------------------------------ borrow and repay

    function test_borrow_upToLimit() public {
        _deposit(market, lender, 10_000e18);
        _depositCollateral(market, borrower, 1e18);
        (bool ok, uint256 maxLoan) = market.maxLoanOf(borrower);
        assertTrue(ok);
        assertEq(maxLoan, 1720e18);
        vm.prank(borrower);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.borrow(maxLoan + 1, borrower);
        vm.prank(borrower);
        uint256 units = market.borrow(maxLoan, stranger);
        assertEq(units, maxLoan * 1e6);
        assertEq(loan.balanceOf(stranger), maxLoan);
        assertEq(market.loanOf(borrower), maxLoan);
        assertEq(market.loans(), maxLoan);
        assertEq(market.unlent(), 10_000e18 - maxLoan);
        assertEq(market.borrowerCount(), 1);
        assertEq(market.borrowerAt(0), borrower);
        _assertIdentity(market);
    }

    function test_borrow_rejects() public {
        _deposit(market, lender, 100e18);
        _depositCollateral(market, borrower, 1e18);
        vm.startPrank(borrower);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.borrow(1, address(0));
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.borrow(0, borrower);
        vm.expectRevert(IMarket.InsufficientUnlent.selector);
        market.borrow(100e18 + 1, borrower);
        vm.stopPrank();
        price.setPrice(0);
        vm.prank(borrower);
        vm.expectRevert(IMarket.PriceUnavailable.selector);
        market.borrow(1e18, borrower);
        price.setPrice(PRICE);
        price.setReverting(true);
        vm.prank(borrower);
        vm.expectRevert(IMarket.PriceUnavailable.selector);
        market.borrow(1e18, borrower);
        price.setReverting(false);
        vm.prank(stranger);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.borrow(1, stranger); // no collateral
    }

    function test_repay_partialAndFull_byAnyone() public {
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 500e18);
        skip(30 days);
        uint256 owed = market.loanOf(borrower);
        assertGt(owed, 500e18);
        uint256 repaid = _repay(market, stranger, 100e18, borrower);
        assertEq(repaid, 100e18);
        assertApproxEqAbs(market.loanOf(borrower), owed - 100e18, 1);
        assertEq(market.borrowerCount(), 1);
        // Over-repaying is capped to the loan; the rest stays with the payer.
        uint256 remaining = market.loanOf(borrower);
        uint256 repaid2 = _repay(market, stranger, remaining + 50e18, borrower);
        assertEq(repaid2, remaining);
        assertEq(loan.balanceOf(stranger), 50e18);
        assertEq(market.loanOf(borrower), 0);
        assertEq(market.loanUnitsOf(borrower), 0);
        assertEq(market.borrowerCount(), 0);
        _assertIdentity(market);
    }

    function test_repay_rejects() public {
        _fund(loan, stranger, 10e18, address(market));
        vm.startPrank(stranger);
        vm.expectRevert(IMarket.ZeroAddress.selector);
        market.repay(1, address(0));
        vm.expectRevert(IMarket.ZeroAmount.selector);
        market.repay(0, borrower);
        vm.expectRevert(IMarket.NoLoan.selector);
        market.repay(1, borrower);
        vm.stopPrank();
    }

    function test_borrowerSet_addAndRemove() public {
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 100e18);
        _openPosition(borrower2, 1e18, 100e18);
        _openPosition(stranger, 1e18, 100e18);
        assertEq(market.borrowerCount(), 3);
        _repay(market, borrower, 200e18, borrower);
        assertEq(market.borrowerCount(), 2);
        assertEq(market.borrowerAt(0), stranger); // swapped into the removed slot
        assertEq(market.borrowerAt(1), borrower2);
        _repay(market, borrower2, 200e18, borrower2);
        _repay(market, stranger, 200e18, stranger);
        assertEq(market.borrowerCount(), 0);
        _borrow(market, borrower, 10e18);
        assertEq(market.borrowerCount(), 1);
        assertEq(market.borrowerAt(0), borrower);
    }

    // ------------------------------------------------------------------ interest and fee accrual

    function test_accrual_splitsInterest() public {
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 1000e18); // 100 percent utilisation: 10 percent a year
        skip(YEAR);
        uint256 rate = linear.ratePerSecond(1000e18, 1000e18);
        uint256 interest = 1000e18 * rate * YEAR / WAD;
        assertEq(market.loans(), 1000e18 + interest);
        assertEq(market.feeOwed(), interest / 10);
        assertEq(market.deposits(), 1000e18 + interest - interest / 10);
        assertEq(market.totalInterest(), interest);
        vm.expectEmit(true, true, true, true);
        emit IMarket.Accrued(interest, interest / 10);
        market.accrue();
        assertEq(market.lastAccrual(), block.timestamp);
        _assertIdentity(market);
    }

    function test_accrual_noLoansNoInterest() public {
        _deposit(market, lender, 1000e18);
        skip(YEAR);
        assertEq(market.deposits(), 1000e18);
        assertEq(market.totalInterest(), 0);
        market.accrue();
        assertEq(market.feeOwed(), 0);
    }

    function testFuzz_feeIsExactlyTenPercentOfInterest(uint256 steps, uint256 seed) public {
        steps = bound(steps, 1, 20);
        _deposit(market, lender, 1_000_000e18);
        _openPosition(borrower, 1000e18, 700_000e18);
        for (uint256 i = 0; i < steps; ++i) {
            uint256 dt = uint256(keccak256(abi.encode(seed, i))) % 90 days + 1;
            skip(dt);
            market.accrue();
            assertEq(market.feePaid() + market.feeOwed(), market.totalInterest() / 10);
            _assertIdentity(market);
        }
    }

    function test_roundingChargesBorrowerUp() public {
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 333e18);
        skip(1 days);
        market.accrue();
        // The loan recorded in units, converted back, is never below the loan recorded in total.
        assertGe(market.loanOf(borrower), market.loans());
        assertLe(market.loanOf(borrower), market.loans() + 1);
    }

    // ------------------------------------------------------------------ fee-on-transfer protection

    function test_pullRevertsWhenNothingReceived() public {
        // A token that silently keeps everything must not create receipts.
        MockERC20 swallow = new MockERC20("Swallow", "SWL", 18);
        vm.mockCall(
            address(swallow), abi.encodeWithSignature("transferFrom(address,address,uint256)"), abi.encode(true)
        );
        Market m = new Market(address(swallow), address(coll), address(price), LIMIT, address(linear), feeRecipient);
        vm.prank(lender);
        vm.expectRevert(IMarket.NothingReceived.selector);
        m.deposit(1e18, lender);
    }

    // ------------------------------------------------------------------ audit views

    function test_loansAboveLimit_pagedAndFiltered() public {
        _deposit(market, lender, 10_000e18);
        _openPosition(borrower, 1e18, 1700e18);
        _openPosition(borrower2, 1e18, 100e18);
        _openPosition(stranger, 1e18, 1500e18);
        (bool ok, address[] memory who, uint256[] memory sizes, uint256[] memory limits) = market.loansAboveLimit(0, 10);
        assertTrue(ok);
        assertEq(who.length, 0);
        // Price falls 10 percent: limits become 1548.
        price.setPrice(PRICE * 9 / 10);
        (ok, who, sizes, limits) = market.loansAboveLimit(0, 10);
        assertTrue(ok);
        assertEq(who.length, 1);
        assertEq(who[0], borrower);
        assertEq(sizes[0], 1700e18);
        assertEq(limits[0], 1548e18);
        // Paging: the first page holds only borrower, the second holds nobody above the limit.
        (, who,,) = market.loansAboveLimit(0, 1);
        assertEq(who.length, 1);
        (, who,,) = market.loansAboveLimit(1, 5);
        assertEq(who.length, 0);
        (, who,,) = market.loansAboveLimit(7, 5);
        assertEq(who.length, 0);
        // With no price nothing is above the limit, and the view says so.
        price.setReverting(true);
        (ok, who,,) = market.loansAboveLimit(0, 10);
        assertFalse(ok);
        assertEq(who.length, 0);
    }

    function test_views_includePendingAccrual() public {
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 500e18);
        skip(100 days);
        uint256 loansBefore = market.loans();
        uint256 depositsBefore = market.deposits();
        uint256 feeBefore = market.feeOwed();
        uint256 loanOfBefore = market.loanOf(borrower);
        uint256 receiptsForBefore = market.receiptsFor(1e18);
        market.accrue();
        assertEq(market.loans(), loansBefore);
        assertEq(market.deposits(), depositsBefore);
        assertEq(market.feeOwed(), feeBefore);
        assertEq(market.loanOf(borrower), loanOfBefore);
        assertEq(market.receiptsFor(1e18), receiptsForBefore);
        assertEq(market.totalReceipts(), receipt.totalSupply());
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentrancyGuarded() public {
        ReentrantToken t = new ReentrantToken();
        Market m = new Market(address(t), address(coll), address(price), LIMIT, address(linear), feeRecipient);
        t.setMarket(m);
        t.mint(lender, 1e18);
        vm.startPrank(lender);
        t.approve(address(m), type(uint256).max);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        m.deposit(1e18, lender);
        vm.stopPrank();
        // The same token hook on the way out (withdraw) is also refused.
        t.setMarket(Market(address(0)));
        vm.prank(lender);
        uint256 receipts = m.deposit(1e18, lender);
        t.setMarket(m);
        vm.prank(lender);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        m.withdraw(receipts, lender);
    }
}

/// @dev A token that reenters the market during any transfer that touches the market.
contract ReentrantToken is MockERC20 {
    Market internal market;

    constructor() MockERC20("Reentrant", "RE", 18) {}

    function setMarket(Market m) external {
        market = m;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        if (to == address(market) || from == address(market)) market.accrue();
    }
}
