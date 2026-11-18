// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {RateRecordBase} from "./RateRecordBase.t.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {FollowingRateFormula} from "../src/rates/FollowingRateFormula.sol";
import {KinkedRateFormula} from "../src/rates/KinkedRateFormula.sol";
import {RateRecord} from "../src/rates/RateRecord.sol";
import {Utilisation} from "../src/rates/Utilisation.sol";
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

        // Phase 2: twenty days at the new centre, the signer reading the same rates every five days
        // so that the record stays fresh (a silence of more than a week rests the centre: see
        // test_silence_restsTheCentreAfterAWeek). Utilisation is now a little above the target
        // (interest raised the loans more than the deposits), so the rate is above the centre.
        uint256 rate2 = formula.ratePerSecond(market.loans(), market.deposits());
        assertGt(rate2, R12);
        assertLt(rate2, R12 * (WAD + FULL) / WAD);
        assertGt(rate2, 2 * hourRate, "the stated rates more than doubled the rate");
        uint256 loansBefore = market.loans();
        for (uint256 n = 0; n < 3; ++n) {
            skip(5 days);
            _submitAt(block.timestamp, _uniform(R12));
            assertEq(record.centre(), R12, "the same rates leave the centre where it is");
        }
        skip(5 days);
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

    // ------------------------------------------------------------------ a reading while the market is idle

    /// @dev The formula's shape at centre `c` and utilisation `u`, as the formula writes it.
    function _shape(uint256 c, uint256 u) internal pure returns (uint256) {
        if (u <= TARGET) return c * (FLOOR + (WAD - FLOOR) * u / TARGET) / WAD;
        return c + c * FULL * (u - TARGET) / (WAD - TARGET) / WAD;
    }

    /// @dev A reading delivered while the market is untouched moves the centre from the block of its
    ///      delivery. The idle time before it is charged at the centre that was in force then, not at
    ///      the new one: nobody re-prices time that has already passed by delivering a reading.
    function test_readingDeliveredWhileIdle_pricesOnlyTheTimeAfterIt() public {
        _fund(loan, lender, 1000e18);
        vm.prank(lender);
        market.deposit(1000e18, lender);
        _fund(coll, borrower, 1e18);
        vm.prank(borrower);
        market.depositCollateral(1e18, borrower);
        vm.prank(borrower);
        market.borrow(800e18, borrower);
        assertEq(market.lastAccrual(), T0);

        // Ten idle days at the initial centre, then the signer's readings more than double the rates:
        // the first names the leaders, the second, a day later, moves the centre to 12 percent.
        skip(10 days);
        _submitAt(block.timestamp, _uniform(R12));
        skip(24 hours);
        _submitAt(block.timestamp, _uniform(R12));
        assertEq(record.centre(), R12);
        assertEq(formula.ratePerSecond(800e18, 1000e18), R12, "asked without a last accrual: the new centre");
        assertEq(market.lastAccrual(), T0, "untouched throughout");

        // The eleven idle days are charged at 5 percent, the centre in force over all of them.
        uint256 atOldCentre = 800e18 * (R5 * 11 days) / WAD;
        uint256 atNewCentre = 800e18 * (R12 * 11 days) / WAD;
        assertEq(market.loans(), 800e18 + atOldCentre, "the view already prices the idle time at the old centre");
        vm.prank(stranger);
        market.accrue();
        assertEq(market.totalInterest(), atOldCentre, "eleven days at the old centre");
        assertLt(market.totalInterest(), atNewCentre / 2, "not re-priced at the new one");
        assertEq(market.lastAccrual(), block.timestamp);

        // From the delivery on, the new centre is charged.
        uint256 loansBefore = market.loans();
        uint256 rate = formula.ratePerSecond(market.loans(), market.deposits());
        assertEq(rate, _shape(R12, Utilisation.compute(market.loans(), market.deposits())));
        assertGt(rate, R12, "utilisation is now a little above the target");
        skip(5 days);
        market.accrue();
        assertEq(
            market.totalInterest(), atOldCentre + loansBefore * (rate * 5 days) / WAD, "five days at the new centre"
        );

        // A span across a change of the centre: four days at 12 percent, then the readings step the
        // rates down to 5 percent, and two more days at that. The span is charged at the mean.
        uint256 from = block.timestamp;
        loansBefore = market.loans();
        uint256 depositsBefore = market.deposits();
        skip(3 days);
        _submitAt(block.timestamp, _uniform(R5));
        skip(24 hours);
        _submitAt(block.timestamp, _uniform(R5));
        assertEq(record.centre(), R5);
        skip(2 days);
        uint256 mean = record.centreOver(from, block.timestamp);
        assertEq(mean, (4 days * R12 + 2 days * R5) / 6 days);
        uint256 meanRate = _shape(mean, Utilisation.compute(loansBefore, depositsBefore));
        uint256 interestBefore = market.totalInterest();
        market.accrue();
        assertEq(
            market.totalInterest() - interestBefore, loansBefore * (meanRate * 6 days) / WAD, "six days at the mean"
        );
        assertEq(market.unlent() + market.loans(), market.deposits() + market.feeOwed(), "identity");
    }

    // ------------------------------------------------------------------ a direct quote (security reading finding 3)

    /// @dev The formula's answer depends on who asks. A direct quote, from an account or a contract
    ///      without a last accrual, is the rate at the centre as it stands; the market is charged
    ///      over its own span. The two differ across a change of the centre, and what the market will
    ///      be charged is read from the market, not from the formula. The market reads the formula
    ///      before it writes its last accrual, so its span has its length: were the order reversed,
    ///      the span would be empty and the market would be charged the direct quote.
    function test_directQuoteIsNotWhatAMarketIsCharged() public {
        _fund(loan, lender, 1000e18);
        vm.prank(lender);
        market.deposit(1000e18, lender);
        _fund(coll, borrower, 1e18);
        vm.prank(borrower);
        market.depositCollateral(1e18, borrower);
        vm.prank(borrower);
        market.borrow(800e18, borrower);
        assertEq(market.lastAccrual(), T0);

        // Three days at the initial centre, then the readings move the centre to 12 percent, then
        // three more days: the market's span holds both.
        skip(2 days);
        _submitAt(block.timestamp, _uniform(R12));
        skip(24 hours);
        _submitAt(block.timestamp, _uniform(R12));
        assertEq(record.centre(), R12);
        skip(3 days);

        uint256 quote = formula.ratePerSecond(800e18, 1000e18);
        vm.prank(stranger);
        uint256 quoteByAnAccount = formula.ratePerSecond(800e18, 1000e18);
        assertEq(quote, R12, "a direct quote: the centre as it stands");
        assertEq(quoteByAnAccount, R12);
        uint256 charged = (3 days * R5 + 3 days * R12) / 6 days;
        assertEq(record.centreOver(T0, block.timestamp), charged);
        assertLt(charged, quote, "the market is charged less than the quote says");
        assertEq(
            market.loans(), 800e18 + 800e18 * (charged * 6 days) / WAD, "the market's own view says what it is charged"
        );
        assertEq(market.loanOf(borrower), market.loans());
        assertLt(market.loans(), 800e18 + 800e18 * (quote * 6 days) / WAD, "and that is not the quote");

        // The charge is the view's, and the market's last accrual is written after the rate is read.
        market.accrue();
        assertEq(market.totalInterest(), 800e18 * (charged * 6 days) / WAD, "six days at the mean, not at the quote");
        assertEq(market.lastAccrual(), block.timestamp);
        // Touched again in the same block, nothing more is charged: an empty span is the quote, at nothing.
        market.accrue();
        assertEq(market.totalInterest(), 800e18 * (charged * 6 days) / WAD);
    }

    // ------------------------------------------------------------------ a silence (security reading finding 2)

    /// @dev When readings stop, the record's centre stays what it was, and before the fix every market
    ///      charged it for ever: a last reading at a spike was charged until someone repaid. Now the
    ///      formula rests the centre at the record's initial centre once the last reading is more than
    ///      a week old, and a span across that moment is charged at the record's centre before it and
    ///      the resting centre after it.
    function test_silence_restsTheCentreAfterAWeek() public {
        _fund(loan, lender, 1000e18);
        vm.prank(lender);
        market.deposit(1000e18, lender);
        _fund(coll, borrower, 1e18);
        vm.prank(borrower);
        market.depositCollateral(1e18, borrower);
        vm.prank(borrower);
        market.borrow(800e18, borrower);

        // The signer's readings bring the centre to a spike: the highest rate the record allows.
        _submitAt(block.timestamp, _uniform(MAX_RATE));
        skip(24 hours);
        _submitAt(block.timestamp, _uniform(MAX_RATE));
        assertEq(record.centre(), MAX_RATE);
        market.accrue();
        uint256 t2 = block.timestamp;
        assertEq(market.lastAccrual(), t2);
        uint256 loansBefore = market.loans();
        uint256 depositsBefore = market.deposits();
        uint256 u = Utilisation.compute(loansBefore, depositsBefore);
        assertEq(formula.ratePerSecond(loansBefore, depositsBefore), _shape(MAX_RATE, u));

        // Then silence. A week on, the spike is still charged; a second later, the resting centre.
        uint256 staleAt = t2 + formula.STALE_AFTER();
        assertEq(staleAt, t2 + 7 days);
        vm.warp(staleAt);
        assertEq(formula.ratePerSecond(loansBefore, depositsBefore), _shape(MAX_RATE, u), "a week old: still charged");
        vm.warp(staleAt + 1);
        assertEq(formula.ratePerSecond(loansBefore, depositsBefore), _shape(R5, u), "a second older: at rest");
        assertEq(formula.restingCentre(), R5);
        assertEq(record.centre(), MAX_RATE, "the record itself is unchanged");

        // The market, untouched for twenty days, is charged the spike for the week and the resting
        // centre for the thirteen days after it: nobody is charged a dead reading for ever.
        vm.warp(t2 + 20 days);
        uint256 mean = (7 days * MAX_RATE + 13 days * R5) / 20 days;
        uint256 rate = _shape(mean, u);
        uint256 interestBefore = market.totalInterest();
        assertEq(market.loans(), loansBefore + loansBefore * (rate * 20 days) / WAD, "the view prices the span too");
        market.accrue();
        assertEq(
            market.totalInterest() - interestBefore,
            loansBefore * (rate * 20 days) / WAD,
            "a week at the spike, thirteen days at rest"
        );
        assertLt(
            market.totalInterest() - interestBefore,
            loansBefore * (_shape(MAX_RATE, u) * 20 days) / WAD / 2,
            "far less than twenty days at the spike"
        );
        assertEq(market.unlent() + market.loans(), market.deposits() + market.feeOwed(), "identity");

        // Readings resume: the record is fresh from the block of the new reading, and its centre is
        // charged again from then on.
        _submitAt(block.timestamp, _uniform(MAX_RATE));
        assertEq(record.centre(), MAX_RATE);
        loansBefore = market.loans();
        depositsBefore = market.deposits();
        u = Utilisation.compute(loansBefore, depositsBefore);
        assertEq(formula.ratePerSecond(loansBefore, depositsBefore), _shape(MAX_RATE, u), "fresh again");
        skip(1 days);
        interestBefore = market.totalInterest();
        market.accrue();
        assertEq(market.totalInterest() - interestBefore, loansBefore * (_shape(MAX_RATE, u) * 1 days) / WAD);
    }
}
