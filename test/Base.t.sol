// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IMarket} from "../interfaces/IMarket.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {IReceiptToken} from "../interfaces/IReceiptToken.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ReceiptToken} from "../src/ReceiptToken.sol";
import {KinkedRateFormula} from "../src/rates/KinkedRateFormula.sol";
import {LinearRateFormula} from "../src/rates/LinearRateFormula.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// @notice Common fixture: a factory with both formulas permitted, two plain tokens, a price source
///         and one market on the linear formula.
abstract contract BaseTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant PRICE_SCALE = 1e36;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant LIMIT = 0.86e18;
    /// @dev One collateral unit (1e18) is worth 2000 loan units (2000e18): price per smallest unit, scaled 1e36.
    uint256 internal constant PRICE = 2000e36;

    address internal feeRecipient = makeAddr("AEREDIUM Foundation Limited");
    address internal lender = makeAddr("lender");
    address internal lender2 = makeAddr("lender2");
    address internal borrower = makeAddr("borrower");
    address internal borrower2 = makeAddr("borrower2");
    address internal liquidator = makeAddr("liquidator");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal loan;
    MockERC20 internal coll;
    MockPriceSource internal price;
    LinearRateFormula internal linear;
    KinkedRateFormula internal kinked;
    MarketFactory internal factory;
    Market internal market;
    ReceiptToken internal receipt;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        loan = new MockERC20("Loan Token", "LOAN", 18);
        coll = new MockERC20("Collateral Token", "COLL", 18);
        price = new MockPriceSource(PRICE);
        // 10 percent a year at full utilisation.
        linear = new LinearRateFormula(0, 0.1e18 / YEAR);
        // 4 percent a year up to 80 percent utilisation, then 100 percent a year on the excess.
        kinked = new KinkedRateFormula(0, 0.04e18 / YEAR, 1e18 / YEAR, 0.8e18);
        address[] memory formulas = new address[](2);
        formulas[0] = address(linear);
        formulas[1] = address(kinked);
        factory = new MarketFactory(feeRecipient, formulas);
        market = Market(factory.createMarket(address(loan), address(coll), address(price), LIMIT, address(linear)));
        receipt = ReceiptToken(market.receiptToken());
    }

    // ------------------------------------------------------------------ helpers

    function _fund(MockERC20 token, address who, uint256 amount, address spender) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(spender, type(uint256).max);
    }

    function _deposit(Market m, address who, uint256 amount) internal returns (uint256) {
        _fund(MockERC20(m.loanToken()), who, amount, address(m));
        vm.prank(who);
        return m.deposit(amount, who);
    }

    function _depositCollateral(Market m, address who, uint256 amount) internal {
        _fund(MockERC20(m.collateralToken()), who, amount, address(m));
        vm.prank(who);
        m.depositCollateral(amount, who);
    }

    function _borrow(Market m, address who, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return m.borrow(amount, who);
    }

    function _repay(Market m, address who, uint256 amount, address onBehalf) internal returns (uint256) {
        _fund(MockERC20(m.loanToken()), who, amount, address(m));
        vm.prank(who);
        return m.repay(amount, onBehalf);
    }

    function _liquidate(Market m, address who, address target, uint256 amount) internal returns (uint256, uint256) {
        _fund(MockERC20(m.loanToken()), who, amount, address(m));
        vm.prank(who);
        return m.liquidate(target, amount);
    }

    /// @dev Open a position: 1 collateral unit, borrow `amount` against it.
    function _openPosition(address who, uint256 collateralAmount, uint256 amount) internal {
        _depositCollateral(market, who, collateralAmount);
        _borrow(market, who, amount);
    }

    function _maxLoan(uint256 collateralAmount, uint256 p) internal pure returns (uint256) {
        return (collateralAmount * p / PRICE_SCALE) * LIMIT / WAD;
    }

    /// @dev The accounting identity every market keeps: unlent + loans == deposits + fee owed.
    function _assertIdentity(Market m) internal view {
        assertEq(m.unlent() + m.loans(), m.deposits() + m.feeOwed(), "identity: unlent + loans == deposits + fee owed");
        assertEq(MockERC20(m.loanToken()).balanceOf(address(m)), m.unlent(), "balance == unlent");
        assertEq(
            m.feePaid() + m.feeOwed() + m.feeWrittenOff(),
            m.totalInterest() * m.FEE() / WAD,
            "fee paid + owed + written off == 10 percent of interest"
        );
    }
}
