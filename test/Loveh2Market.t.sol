// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {RateRecordBase} from "./RateRecordBase.t.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {FollowingRateFormula} from "../src/rates/FollowingRateFormula.sol";
import {KinkedRateFormula} from "../src/rates/KinkedRateFormula.sol";
import {RateRecord} from "../src/rates/RateRecord.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// @notice A whole market on the following formula: created through an unchanged factory listing
///         only this formula, lent, borrowed, time passed, readings accepted in between, repaid. The
///         interest and the 10 percent fee are what the stated rates give.
contract Loveh2MarketTest is RateRecordBase {
    uint256 internal constant TARGET = 0.8e18;
    uint256 internal constant FLOOR = 0.5e18;
    uint256 internal constant FULL = 4e18;
    uint256 internal constant LIMIT = 0.86e18;
    uint256 internal constant PRICE = 2000e36;
    uint256 internal constant FEE = 0.1e18;
    /// @dev 5 percent a year: the initial centre of the fixture.
    uint256 internal constant R5 = 0.05e18 / YEAR;
    /// @dev 12 percent a year, stated by the readings.
    uint256 internal constant R12 = 0.12e18 / YEAR;

    address internal feeRecipient = makeAddr("AEREDIUM Foundation Limited");
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");

    MockERC20 internal loan;
    MockERC20 internal coll;
    MockPriceSource internal price;
    FollowingRateFormula internal formula;
    MarketFactory internal factory;
    Market internal market;

    // the expected ledger, kept by the test with the market's own arithmetic
    uint256 internal L;
    uint256 internal D;
    uint256 internal F;
    uint256 internal I;
    uint256 internal lastAccrual;

    function setUp() public override {
        super.setUp();
        loan = new MockERC20("Loan Coin", "LOAN", 18);
        coll = new MockERC20("Collateral Coin", "COLL", 18);
        price = new MockPriceSource(PRICE);
        formula = new FollowingRateFormula(address(record), TARGET, FLOOR, FULL);
        address[] memory formulas = new address[](1);
        formulas[0] = address(formula);
        factory = new MarketFactory(feeRecipient, formulas);
        market = Market(factory.createMarket(address(loan), address(coll), address(price), LIMIT, address(formula)));
    }

    // ------------------------------------------------------------------ helpers

    function _fund(MockERC20 coin, address who, uint256 amount) internal {
        coin.mint(who, amount);
        vm.prank(who);
        coin.approve(address(market), type(uint256).max);
    }

    /// @dev Accrue the expected ledger as the market does: at the formula's rate for the stored
    ///      loans and deposits, over the seconds since the last accrual.
    function _expectAccrual() internal {
        uint256 elapsed = block.timestamp - lastAccrual;
        lastAccrual = block.timestamp;
        if (elapsed == 0 || L == 0) return;
        uint256 rate = formula.ratePerSecond(L, D);
        uint256 interest = L * (rate * elapsed) / WAD;
        if (interest == 0) return;
        uint256 fee = (I + interest) * FEE / WAD - I * FEE / WAD;
        L += interest;
        D += interest - fee;
        F += fee;
        I += interest;
    }

    function _assertLedger() internal view {
        assertEq(market.loans(), L, "loans");
        assertEq(market.deposits(), D, "deposits");
        assertEq(market.feeOwed(), F, "fee owed");
        assertEq(market.totalInterest(), I, "total interest");
        assertEq(market.unlent() + market.loans(), market.deposits() + market.feeOwed(), "identity");
        assertEq(
            market.feePaid() + market.feeOwed() + market.feeWrittenOff(),
            market.totalInterest() / 10,
            "fee is 10 percent"
        );
    }

    // ------------------------------------------------------------------ the factory

    function test_factoryListsOnlyThisFormula() public {
        address[] memory formulas = factory.permittedRateFormulas();
        assertEq(formulas.length, 1);
        assertEq(formulas[0], address(formula));
        assertTrue(factory.isPermittedRateFormula(address(formula)));
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(market.rateFormula(), address(formula));
        assertEq(market.feeRecipient(), feeRecipient);
        KinkedRateFormula kinked = new KinkedRateFormula(0, 1, 2, 0.5e18);
        vm.expectRevert(IMarketFactory.RateFormulaNotPermitted.selector);
        factory.createMarket(address(loan), address(coll), address(price), LIMIT, address(kinked));
    }

    /// @dev Two families, two factories: a LOVEH1 factory on a fixed formula and this one; neither
    ///      knows of the other, and each names its own fee recipient.
    function test_twoFamiliesAreIndependent() public {
        address otherRecipient = makeAddr("another fee recipient");
        KinkedRateFormula kinked = new KinkedRateFormula(0, 0.04e18 / YEAR, 1e18 / YEAR, 0.8e18);
        address[] memory formulas = new address[](1);
        formulas[0] = address(kinked);
        MarketFactory loveh1 = new MarketFactory(otherRecipient, formulas);
        Market m1 = Market(loveh1.createMarket(address(loan), address(coll), address(price), LIMIT, address(kinked)));
        assertEq(m1.feeRecipient(), otherRecipient);
        assertEq(market.feeRecipient(), feeRecipient);
        assertFalse(loveh1.isPermittedRateFormula(address(formula)));
        assertFalse(factory.isPermittedRateFormula(address(kinked)));
        assertFalse(loveh1.isMarket(address(market)));
        assertFalse(factory.isMarket(address(m1)));
    }

    // ------------------------------------------------------------------ the life of a loan

    function test_lifecycle_interestAndFeeFollowTheStatedRates() public {
        lastAccrual = block.timestamp;
        _fund(loan, lender, 1000e18);
        vm.prank(lender);
        market.deposit(1000e18, lender);
        D = 1000e18;
        _fund(coll, borrower, 1e18);
        vm.prank(borrower);
        market.depositCollateral(1e18, borrower);
        vm.prank(borrower);
        market.borrow(800e18, borrower);
        L = 800e18;
        _assertLedger();

        // Phase 1: ten days at the initial centre, at the target utilisation: the rate is the centre.
        assertEq(formula.ratePerSecond(800e18, 1000e18), R5);
        skip(10 days);
        market.accrue();
        _expectAccrual();
        _assertLedger();
        assertEq(I, 800e18 * (R5 * 10 days) / WAD, "ten days of 5 percent on 800");

        // Readings arrive: 12 percent a year. The first names the leaders and leaves the centre; the
        // market is accrued before the second so the hour between them is charged at the old rate.
        _submitAt(block.timestamp, _uniform(R12));
        assertEq(record.centre(), R5);
        uint256 hourRate = formula.ratePerSecond(market.loans(), market.deposits());
        uint256 hourLoans = market.loans();
        skip(1 hours);
        market.accrue();
        _expectAccrual();
        _assertLedger();
        uint256 afterHour = I;
        assertEq(afterHour - 800e18 * (R5 * 10 days) / WAD, hourLoans * (hourRate * 1 hours) / WAD);
        _submitAt(block.timestamp, _uniform(R12));
        assertEq(record.centre(), R12, "the centre follows the stated rates");

        // Phase 2: twenty days at the new centre. Utilisation is now a little above the target
        // (interest raised the loans more than the deposits), so the rate is above the centre.
        uint256 rate2 = formula.ratePerSecond(market.loans(), market.deposits());
        assertGt(rate2, R12);
        assertLt(rate2, R12 * (WAD + FULL) / WAD);
        assertGt(rate2, 2 * hourRate, "the stated rates more than doubled the rate");
        uint256 loansBefore = market.loans();
        skip(20 days);
        market.accrue();
        _expectAccrual();
        _assertLedger();
        assertEq(I - afterHour, loansBefore * (rate2 * 20 days) / WAD, "twenty days at the rate the new centre gives");

        // The signer steps the rates down to 5 percent again; the market is accrued first.
        _submitAt(block.timestamp, _uniform(R5));
        skip(24 hours);
        market.accrue();
        _expectAccrual();
        _submitAt(block.timestamp, _uniform(R5));
        assertEq(record.centre(), R5);
        skip(5 days);

        // Repaid in full.
        uint256 owed = market.loanOf(borrower);
        _fund(loan, borrower, owed);
        vm.prank(borrower);
        market.repay(owed, borrower);
        _expectAccrual();
        assertEq(market.loanOf(borrower), 0);
        assertEq(market.loans(), 0);
        assertEq(market.totalInterest(), I);
        assertEq(market.feeOwed(), I / 10, "the fee owed is 10 percent of all interest");
        assertEq(market.unlent(), market.deposits() + market.feeOwed());

        // The fee is paid to the recipient, in the loan coin, by anyone.
        vm.prank(stranger);
        uint256 paid = market.payFee();
        assertEq(paid, I / 10);
        assertEq(loan.balanceOf(feeRecipient), I / 10);
        assertEq(market.feeOwed(), 0);
        // The lender's receipts are worth the deposit plus 90 percent of the interest, less the
        // virtual offset's rounding (a few thousand wei on a thousand coins).
        assertApproxEqAbs(market.depositOf(lender), 1000e18 + I - I / 10, 1e6);
        assertLe(market.depositOf(lender), 1000e18 + I - I / 10);
    }
}
