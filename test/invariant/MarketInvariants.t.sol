// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IRateFormula} from "../../interfaces/IRateFormula.sol";
import {Market} from "../../src/Market.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {ReceiptToken} from "../../src/ReceiptToken.sol";
import {KinkedRateFormula} from "../../src/rates/KinkedRateFormula.sol";
import {LinearRateFormula} from "../../src/rates/LinearRateFormula.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceSource} from "../mocks/MockPriceSource.sol";
import {Handler} from "./Handler.sol";

/// @notice Invariants held under random sequences of every action. Run once per rate formula.
abstract contract MarketInvariantsBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant PRICE = 2000e36;
    uint256 internal constant YEAR = 365 days;

    address internal feeRecipient = makeAddr("AEREDIUM Foundation Limited");
    MockERC20 internal loan;
    MockERC20 internal coll;
    MockPriceSource internal price;
    MarketFactory internal factory;
    Market internal market;
    ReceiptToken internal receipt;
    Handler internal handler;
    /// @dev A second market with the same tokens, untouched by the handler: its figures never move.
    Market internal bystander;
    uint256 internal bystanderDeposits;
    uint256 internal bystanderLoans;

    function _formula() internal virtual returns (address);

    function setUp() public {
        vm.warp(1_700_000_000);
        loan = new MockERC20("Loan Token", "LOAN", 18);
        coll = new MockERC20("Collateral Token", "COLL", 18);
        price = new MockPriceSource(PRICE);
        address formula = _formula();
        address[] memory formulas = new address[](1);
        formulas[0] = formula;
        factory = new MarketFactory(feeRecipient, formulas);
        market = Market(factory.createMarket(address(loan), address(coll), address(price), 0.86e18, formula));
        receipt = ReceiptToken(market.receiptToken());
        bystander = Market(factory.createMarket(address(loan), address(coll), address(price), 0.5e18, formula));

        // Give the bystander a position so it has figures that could move if isolation were broken.
        address other = makeAddr("bystander user");
        loan.mint(other, 1000e18);
        coll.mint(other, 1e18);
        vm.startPrank(other);
        loan.approve(address(bystander), type(uint256).max);
        coll.approve(address(bystander), type(uint256).max);
        bystander.deposit(1000e18, other);
        bystander.depositCollateral(1e18, other);
        bystander.borrow(500e18, other);
        vm.stopPrank();
        bystander.accrue();

        handler = new Handler(market, price, PRICE);
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------ 1. accounting identities

    /// @notice Unlent loan token plus loans equals deposits plus fee owed.
    function invariant_unlentPlusLoansEqualsDepositsPlusFeeOwed() public view {
        assertEq(market.unlent() + market.loans(), market.deposits() + market.feeOwed());
    }

    /// @notice The market's loan-token balance equals the unlent loan token: the deposits not lent
    ///         plus the fee owed (tokens sent directly to the market are credited to nobody and are
    ///         counted separately by the handler).
    function invariant_balanceEqualsUnlent() public view {
        assertEq(loan.balanceOf(address(market)), market.unlent() + handler.ghostDonations());
        assertEq(
            int256(loan.balanceOf(address(market)) - handler.ghostDonations()),
            int256(market.deposits()) - int256(market.loans()) + int256(market.feeOwed())
        );
    }

    /// @notice The fee paid plus the fee owed equals exactly 10 percent of all interest accrued. Only
    ///         when a loss has exceeded every deposit in the market is part of the unpaid fee written
    ///         off, and then the three together are exactly 10 percent.
    function invariant_feeIsExactlyTenPercentOfInterest() public view {
        uint256 tenPercent = market.totalInterest() * market.FEE() / WAD;
        assertEq(market.feePaid() + market.feeOwed() + market.feeWrittenOff(), tenPercent);
        if (!handler.ghostLossExceededDeposits()) {
            assertEq(market.feeWrittenOff(), 0);
            assertEq(market.feePaid() + market.feeOwed(), tenPercent);
        }
        assertEq(loan.balanceOf(feeRecipient), market.feePaid(), "fee reaches the recipient and nobody else");
        assertGe(market.feePaid(), handler.ghostFeePaidByHandler(), "payFee is counted in the fee paid");
    }

    // ------------------------------------------------------------------ 2. borrowing limit

    /// @notice No loan above the limit after any borrower action (borrow or collateral withdrawal).
    function invariant_noLoanAboveLimitAfterBorrowerAction() public view {
        if (!handler.lastWasBorrowerAction()) return;
        address a = handler.lastBorrowerActor();
        (bool ok, uint256 maxLoan) = market.maxLoanOf(a);
        assertTrue(ok, "a borrower action succeeded without a price");
        assertLe(market.loanOf(a), maxLoan);
    }

    // ------------------------------------------------------------------ 3. sums and sets

    function invariant_collateralSums() public view {
        assertEq(coll.balanceOf(address(market)), market.collateral());
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            sum += market.collateralOf(handler.actors(i));
        }
        assertEq(sum, market.collateral());
    }

    function invariant_loanUnitsAndBorrowerSet() public view {
        uint256 units;
        uint256 open;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            units += market.loanUnitsOf(a);
            if (market.loanUnitsOf(a) != 0) {
                ++open;
                assertGt(market.loanOf(a), 0);
            } else {
                assertEq(market.loanOf(a), 0);
            }
        }
        assertEq(units, market.totalLoanUnits());
        assertEq(open, market.borrowerCount());
        for (uint256 i = 0; i < market.borrowerCount(); ++i) {
            assertGt(market.loanUnitsOf(market.borrowerAt(i)), 0);
        }
        if (market.totalLoanUnits() == 0) assertEq(market.loans(), 0);
    }

    function invariant_receiptsAreBackedAndNeverFavourTheLender() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            sum += receipt.balanceOf(a);
        }
        assertEq(sum, receipt.totalSupply());
        // The value of every receipt together never exceeds the deposits.
        assertLe(market.valueOf(receipt.totalSupply()), market.deposits());
        // The loans charged to borrowers together never fall below the loans recorded.
        uint256 charged;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            charged += market.loanOf(handler.actors(i));
        }
        assertGe(charged, market.loans());
    }

    function invariant_lossOnlyWhenCollateralExhausted() public view {
        if (handler.ghostLossEvents() == 0) assertEq(market.totalLoss() + market.feeWrittenOff(), 0);
    }

    // ------------------------------------------------------------------ 4. isolation

    function invariant_bystanderMarketUnchanged() public view {
        assertEq(bystander.loans(), bystanderLoansNow());
        assertEq(bystander.totalLoss(), 0);
        assertEq(bystander.collateral(), 1e18);
        assertEq(bystander.borrowerCount(), 1);
        assertEq(bystander.unlent(), 500e18);
        assertEq(bystander.feePaid(), 0);
        assertEq(loan.balanceOf(address(bystander)), 500e18);
    }

    /// @dev The bystander only accrues interest with time, which the handler's warps also move.
    function bystanderLoansNow() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - bystander.lastAccrual();
        uint256 rate = IRateFormula(bystander.rateFormula()).ratePerSecond(500e18, 1000e18);
        return 500e18 + 500e18 * rate * elapsed / WAD;
    }

    // ------------------------------------------------------------------ 5. terms never move

    function invariant_termsNeverMove() public view {
        assertEq(market.loanToken(), address(loan));
        assertEq(market.collateralToken(), address(coll));
        assertEq(market.priceSource(), address(price));
        assertEq(market.borrowingLimit(), 0.86e18);
        assertEq(market.rateFormula(), _formulaView());
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(market.FEE(), 0.1e18);
        assertEq(factory.feeRecipient(), feeRecipient);
        assertEq(factory.permittedRateFormulas().length, 1);
    }

    function _formulaView() internal view returns (address) {
        return factory.permittedRateFormulas()[0];
    }

    function invariant_callSummary() public view {
        // Keep the handler honest: a run that never succeeds at anything would prove nothing.
        if (handler.calls() > 50) assertGt(handler.successes(), 0);
    }

    /// @dev Shown with -vv: how far each run got (liquidations and losses are the interesting paths).
    function afterInvariant() public view {
        console2.log(
            "calls / successes / liquidations / losses / fee written off:",
            handler.calls(),
            handler.successes(),
            handler.ghostLiquidations()
        );
        console2.log("  losses, lossExceededDeposits:", handler.ghostLossEvents(), handler.ghostLossExceededDeposits());
        console2.log(
            "  deposits / collateral deposits / borrows:",
            handler.ghostDeposits(),
            handler.ghostCollateralDeposits(),
            handler.ghostBorrows()
        );
    }
}

contract MarketInvariantsLinearTest is MarketInvariantsBase {
    function _formula() internal override returns (address) {
        return address(new LinearRateFormula(0.01e18 / YEAR, 0.2e18 / YEAR));
    }
}

contract MarketInvariantsKinkedTest is MarketInvariantsBase {
    function _formula() internal override returns (address) {
        return address(new KinkedRateFormula(0.01e18 / YEAR, 0.04e18 / YEAR, 2e18 / YEAR, 0.8e18));
    }
}
