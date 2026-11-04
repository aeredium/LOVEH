// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {LinearRateFormula} from "../src/rates/LinearRateFormula.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

contract FactoryTest is BaseTest {
    function test_construction() public view {
        assertEq(factory.feeRecipient(), feeRecipient);
        address[] memory formulas = factory.permittedRateFormulas();
        assertEq(formulas.length, 2);
        assertEq(formulas[0], address(linear));
        assertEq(formulas[1], address(kinked));
        assertTrue(factory.isPermittedRateFormula(address(linear)));
        assertTrue(factory.isPermittedRateFormula(address(kinked)));
        assertFalse(factory.isPermittedRateFormula(stranger));
        assertEq(factory.marketCount(), 1);
        assertEq(factory.markets(0), address(market));
        assertTrue(factory.isMarket(address(market)));
        assertFalse(factory.isMarket(stranger));
        assertEq(
            factory.marketFor(address(loan), address(coll), address(price), LIMIT, address(linear)), address(market)
        );
        assertEq(factory.marketFor(address(loan), address(coll), address(price), LIMIT, address(kinked)), address(0));
    }

    function test_constructor_rejects() public {
        address[] memory formulas = new address[](1);
        formulas[0] = address(linear);
        vm.expectRevert(IMarketFactory.ZeroAddress.selector);
        new MarketFactory(address(0), formulas);
        vm.expectRevert(IMarketFactory.NoRateFormulas.selector);
        new MarketFactory(feeRecipient, new address[](0));
        address[] memory withZero = new address[](2);
        withZero[0] = address(linear);
        vm.expectRevert(IMarketFactory.ZeroAddress.selector);
        new MarketFactory(feeRecipient, withZero);
        address[] memory dup = new address[](2);
        dup[0] = address(linear);
        dup[1] = address(linear);
        vm.expectRevert(IMarketFactory.DuplicateRateFormula.selector);
        new MarketFactory(feeRecipient, dup);
    }

    function test_createMarket_byAnyone_emitsAndLists() public {
        vm.expectEmit(false, true, true, true);
        emit IMarketFactory.MarketCreated(
            address(0), address(loan), address(coll), address(price), 0.5e18, address(kinked)
        );
        vm.prank(stranger);
        address m = factory.createMarket(address(loan), address(coll), address(price), 0.5e18, address(kinked));
        assertEq(factory.marketCount(), 2);
        assertEq(factory.markets(1), m);
        assertTrue(factory.isMarket(m));
        assertEq(Market(m).loanToken(), address(loan));
        assertEq(Market(m).collateralToken(), address(coll));
        assertEq(Market(m).priceSource(), address(price));
        assertEq(Market(m).borrowingLimit(), 0.5e18);
        assertEq(Market(m).rateFormula(), address(kinked));
        assertEq(Market(m).feeRecipient(), feeRecipient);
        assertEq(factory.marketFor(address(loan), address(coll), address(price), 0.5e18, address(kinked)), m);
    }

    function test_createMarket_rejects() public {
        vm.expectRevert(IMarketFactory.ZeroAddress.selector);
        factory.createMarket(address(0), address(coll), address(price), LIMIT, address(linear));
        vm.expectRevert(IMarketFactory.ZeroAddress.selector);
        factory.createMarket(address(loan), address(0), address(price), LIMIT, address(linear));
        vm.expectRevert(IMarketFactory.ZeroAddress.selector);
        factory.createMarket(address(loan), address(coll), address(0), LIMIT, address(linear));
        vm.expectRevert(IMarketFactory.RateFormulaNotPermitted.selector);
        factory.createMarket(address(loan), address(coll), address(price), LIMIT, address(0));
        vm.expectRevert(IMarketFactory.SameToken.selector);
        factory.createMarket(address(loan), address(loan), address(price), LIMIT, address(linear));
        vm.expectRevert(IMarketFactory.InvalidBorrowingLimit.selector);
        factory.createMarket(address(loan), address(coll), address(price), 0, address(linear));
        vm.expectRevert(IMarketFactory.InvalidBorrowingLimit.selector);
        factory.createMarket(address(loan), address(coll), address(price), 1e18, address(linear));
        vm.expectRevert(IMarketFactory.InvalidBorrowingLimit.selector);
        factory.createMarket(address(loan), address(coll), address(price), 2e18, address(linear));
        LinearRateFormula rogue = new LinearRateFormula(0, 1);
        vm.expectRevert(IMarketFactory.RateFormulaNotPermitted.selector);
        factory.createMarket(address(loan), address(coll), address(price), LIMIT, address(rogue));
        vm.expectRevert(IMarketFactory.DuplicateMarket.selector);
        factory.createMarket(address(loan), address(coll), address(price), LIMIT, address(linear));
    }

    function test_sameTokensDifferentTermsAreDifferentMarkets() public {
        address a = factory.createMarket(address(loan), address(coll), address(price), 0.5e18, address(linear));
        address b = factory.createMarket(address(loan), address(coll), address(price), 0.5e18, address(kinked));
        MockPriceSource other = new MockPriceSource(PRICE);
        address c = factory.createMarket(address(loan), address(coll), address(other), 0.5e18, address(linear));
        address d = factory.createMarket(address(coll), address(loan), address(price), 0.5e18, address(linear));
        assertTrue(a != b && b != c && c != d && a != c && a != d && b != d);
        assertEq(factory.marketCount(), 5);
    }

    function testFuzz_createMarket_limitBounds(uint256 limit) public {
        if (limit == 0 || limit >= 1e18) {
            vm.expectRevert(IMarketFactory.InvalidBorrowingLimit.selector);
            factory.createMarket(address(loan), address(coll), address(price), limit, address(kinked));
        } else {
            address m = factory.createMarket(address(loan), address(coll), address(price), limit, address(kinked));
            assertEq(Market(m).borrowingLimit(), limit);
        }
    }
}
