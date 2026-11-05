// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {Market} from "../src/Market.sol";
import {ReceiptToken} from "../src/ReceiptToken.sol";

/// @notice `borrowableOf`: the largest amount `borrow` accepts at this block, exactly, after pending
///         interest and after both roundings in the market's favour. Run once per rate formula.
abstract contract BorrowableBase is BaseTest {
    function _rateFormula() internal view virtual returns (address);

    function setUp() public virtual override {
        super.setUp();
        // The base fixture's market is on the linear formula; any other formula gets its own market.
        if (_rateFormula() == market.rateFormula()) return;
        market = Market(factory.createMarket(address(loan), address(coll), address(price), LIMIT, _rateFormula()));
        receipt = ReceiptToken(market.receiptToken());
    }

    /// @dev The reproduction from the brief: another loan open, time passed, and a borrower asking for
    ///      `maxLoanOf - loanOf` is refused by the two roundings, while `borrowableOf` is accepted.
    function _openTheScene() internal {
        _deposit(market, lender, 1_000_000e18);
        _depositCollateral(market, borrower, 10e18);
        _depositCollateral(market, borrower2, 7e18);
        _borrow(market, borrower2, 3333e18 + 7);
        skip(6561);
    }

    // ------------------------------------------------------------------ the fault and the fix

    function test_maxLoanMinusLoanIsRefused_borrowableIsAccepted() public {
        _openTheScene();
        (bool ok, uint256 maxLoan) = market.maxLoanOf(borrower);
        assertTrue(ok);
        uint256 shown = maxLoan - market.loanOf(borrower);
        (bool ok2, uint256 borrowable) = market.borrowableOf(borrower);
        assertTrue(ok2);
        assertGt(borrowable, 0);
        assertLt(borrowable, shown, "the two roundings take a unit off the room shown");

        vm.prank(borrower);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.borrow(shown, borrower);

        vm.prank(borrower);
        market.borrow(borrowable, borrower);
        assertLe(market.loanOf(borrower), maxLoan);
        _assertIdentity(market);
    }

    // ------------------------------------------------------------------ exactness

    function test_exact_afterTimeWithAnotherLoanOpen() public {
        _openTheScene();
        (bool ok, uint256 amount) = market.borrowableOf(borrower);
        assertTrue(ok);
        assertGt(amount, 0);
        assertLt(amount + 1, market.unlent(), "the refusal below is for the limit, not the unlent balance");

        uint256 snapshot = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.borrow(amount + 1, borrower);
        vm.revertToState(snapshot);

        vm.prank(borrower);
        market.borrow(amount, borrower);
        (, uint256 maxLoan) = market.maxLoanOf(borrower);
        assertLe(market.loanOf(borrower), maxLoan);
        // Nothing more can be borrowed right after.
        (ok, amount) = market.borrowableOf(borrower);
        assertTrue(ok);
        assertEq(amount, 0);
        _assertIdentity(market);
    }

    function test_exact_whenTheBorrowerAlreadyHasALoan() public {
        _openTheScene();
        _borrow(market, borrower, 1234e18 + 5);
        skip(90 days);
        (bool ok, uint256 amount) = market.borrowableOf(borrower);
        assertTrue(ok);
        assertGt(amount, 0);
        assertLt(amount + 1, market.unlent());

        uint256 snapshot = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.borrow(amount + 1, borrower);
        vm.revertToState(snapshot);

        vm.prank(borrower);
        market.borrow(amount, borrower);
        (, uint256 maxLoan) = market.maxLoanOf(borrower);
        assertLe(market.loanOf(borrower), maxLoan);
    }

    /// @dev After enough interest, one loan unit is worth more than one loan token, so the roundings
    ///      can take more than a unit off the room shown and the search has to run. Still exact.
    function test_exact_whenOneLoanUnitIsWorthMoreThanOneToken() public {
        _deposit(market, lender, 1000e18);
        _depositCollateral(market, borrower2, 1e18);
        _borrow(market, borrower2, 800e18); // 80 percent utilisation, then centuries of interest
        for (uint256 i = 0; i < 40; ++i) {
            skip(10 * YEAR);
            market.accrue();
        }
        uint256 unitPrice = (market.loans() + 1) / (market.totalLoanUnits() + 1e6);
        assertGt(unitPrice, 1000, "one loan unit is worth far more than one loan token");

        _depositCollateral(market, stranger, 0.05e18); // a limit of 86e18, below the 200e18 unlent
        (bool ok, uint256 amount) = market.borrowableOf(stranger);
        assertTrue(ok);
        assertGt(amount, 0);
        (, uint256 maxLoan) = market.maxLoanOf(stranger);
        assertEq(maxLoan, 86e18);
        assertLt(amount + 1, maxLoan, "the search ran over more than one unit");
        assertLt(amount + 1, market.unlent());

        uint256 snapshot = vm.snapshotState();
        vm.prank(stranger);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.borrow(amount + 1, stranger);
        vm.revertToState(snapshot);

        vm.prank(stranger);
        market.borrow(amount, stranger);
        assertLe(market.loanOf(stranger), maxLoan);
        _assertIdentity(market);
    }

    function test_sameAnswerWhetherOrNotInterestIsWritten() public {
        _openTheScene();
        (, uint256 pending) = market.borrowableOf(borrower);
        assertGt(market.loans(), 3333e18 + 7, "interest is pending");
        market.accrue();
        (, uint256 written) = market.borrowableOf(borrower);
        assertEq(pending, written);
    }

    function test_cappedByTheUnlentBalance() public {
        _deposit(market, lender, 1000e18);
        _depositCollateral(market, borrower, 10e18); // worth 20,000: the limit is far above the deposit
        _depositCollateral(market, borrower2, 1e18);
        _borrow(market, borrower2, 400e18);
        skip(1 days);
        (bool ok, uint256 amount) = market.borrowableOf(borrower);
        assertTrue(ok);
        assertEq(amount, market.unlent());
        vm.prank(borrower);
        vm.expectRevert(IMarket.InsufficientUnlent.selector);
        market.borrow(amount + 1, borrower);
        vm.prank(borrower);
        market.borrow(amount, borrower);
        assertEq(market.unlent(), 0);
    }

    function test_noCollateral_returnsZero() public {
        _deposit(market, lender, 1000e18);
        (bool ok, uint256 amount) = market.borrowableOf(stranger);
        assertTrue(ok);
        assertEq(amount, 0);
        vm.prank(stranger);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.borrow(1, stranger);
    }

    function test_loanAtTheLimit_returnsZero() public {
        _deposit(market, lender, 10_000e18);
        _depositCollateral(market, borrower, 1e18);
        (, uint256 amount) = market.borrowableOf(borrower);
        assertEq(amount, _maxLoan(1e18, PRICE));
        _borrow(market, borrower, amount);
        skip(1 days); // interest takes the loan above the limit
        (bool ok, uint256 after_) = market.borrowableOf(borrower);
        assertTrue(ok);
        assertEq(after_, 0);
        vm.prank(borrower);
        vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        market.borrow(1, borrower);
    }

    function test_priceOutage_returnsFalseAndZero() public {
        _openTheScene();
        (, uint256 before) = market.borrowableOf(borrower);
        assertGt(before, 0);

        price.setPrice(0);
        (bool ok, uint256 amount) = market.borrowableOf(borrower);
        assertFalse(ok);
        assertEq(amount, 0);

        price.setPrice(PRICE);
        price.setReverting(true);
        (ok, amount) = market.borrowableOf(borrower);
        assertFalse(ok);
        assertEq(amount, 0);

        price.setReverting(false);
        price.setMalformed(true);
        (ok, amount) = market.borrowableOf(borrower);
        assertFalse(ok);
        assertEq(amount, 0);

        price.setMalformed(false);
        (ok, amount) = market.borrowableOf(borrower);
        assertTrue(ok);
        assertEq(amount, before);
    }

    /// @dev Bounded gas, on the path where the roundings refuse the room shown and the search runs,
    ///      and on the path where the unlent balance is the answer.
    function test_gasIsBounded() public {
        _openTheScene();
        (, uint256 maxLoan) = market.maxLoanOf(borrower);
        uint256 shown = maxLoan - market.loanOf(borrower);
        uint256 before = gasleft();
        (bool ok, uint256 amount) = market.borrowableOf(borrower);
        uint256 used = before - gasleft();
        assertTrue(ok);
        assertLt(amount, shown, "the search ran");
        assertLt(used, 30_000, "borrowableOf gas on the search path");

        _depositCollateral(market, stranger, 1e30);
        before = gasleft();
        (ok, amount) = market.borrowableOf(stranger);
        used = before - gasleft();
        assertTrue(ok);
        assertEq(amount, market.unlent());
        assertLt(used, 30_000, "borrowableOf gas on the unlent path");
    }

    // ------------------------------------------------------------------ fuzz: exact under random scenes

    function testFuzz_exact(
        uint256 collateralAmount,
        uint256 otherCollateral,
        uint256 otherLoan,
        uint256 firstLoan,
        uint256 elapsed,
        uint256 deposited,
        uint256 decades
    ) public {
        deposited = bound(deposited, 1e18, 1e27);
        collateralAmount = bound(collateralAmount, 1, 1e24);
        otherCollateral = bound(otherCollateral, 1e12, 1e24);
        elapsed = bound(elapsed, 0, 3 * YEAR);
        // Mostly fresh markets; sometimes centuries old, where one loan unit is worth many tokens.
        decades = decades % 4 == 0 ? bound(decades, 1, 30) : 0;

        _deposit(market, lender, deposited);
        _depositCollateral(market, borrower, collateralAmount);
        _depositCollateral(market, borrower2, otherCollateral);
        (, uint256 otherRoom) = market.borrowableOf(borrower2);
        otherLoan = bound(otherLoan, 0, otherRoom);
        if (otherLoan != 0) _borrow(market, borrower2, otherLoan);
        if (firstLoan % 3 != 0) {
            (, uint256 room) = market.borrowableOf(borrower);
            firstLoan = bound(firstLoan, 0, room);
            if (firstLoan != 0) _borrow(market, borrower, firstLoan);
        }
        for (uint256 i = 0; i < decades; ++i) {
            skip(10 * YEAR);
            market.accrue();
        }
        skip(elapsed);

        (bool ok, uint256 amount) = market.borrowableOf(borrower);
        assertTrue(ok);
        assertLe(amount, market.unlent());
        (, uint256 maxLoan) = market.maxLoanOf(borrower);
        uint256 owed = market.loanOf(borrower);
        assertLe(amount, maxLoan > owed ? maxLoan - owed : 0, "never above the room shown");

        uint256 snapshot = vm.snapshotState();
        vm.prank(borrower);
        if (amount + 1 <= market.unlent()) {
            vm.expectRevert(IMarket.AboveBorrowingLimit.selector);
        } else {
            vm.expectRevert(IMarket.InsufficientUnlent.selector);
        }
        market.borrow(amount + 1, borrower);
        vm.revertToState(snapshot);

        if (amount == 0) return;
        vm.prank(borrower);
        market.borrow(amount, borrower);
        assertLe(market.loanOf(borrower), maxLoan);
        _assertIdentity(market);
    }
}

contract BorrowableLinearTest is BorrowableBase {
    function _rateFormula() internal view override returns (address) {
        return address(linear);
    }
}

contract BorrowableKinkedTest is BorrowableBase {
    function _rateFormula() internal view override returns (address) {
        return address(kinked);
    }
}
