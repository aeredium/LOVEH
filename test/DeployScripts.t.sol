// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {DeployLoveh1} from "../script/DeployLoveh1.s.sol";
import {DeployTill} from "../script/DeployTill.s.sol";
import {FoundationTill} from "../src/FoundationTill.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {KinkedRateFormula} from "../src/rates/KinkedRateFormula.sol";
import {LinearRateFormula} from "../src/rates/LinearRateFormula.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";

/// @dev DeployTill with its inputs supplied by the test rather than by the process environment, so
///      that a missing or malformed input can be tried without touching the environment other tests read.
contract DeployTillHarness is DeployTill {
    mapping(string name => string value) internal inputs;

    function give(string memory name, string memory value) external {
        inputs[name] = value;
    }

    function _raw(string memory name) internal view override returns (bool present, string memory value) {
        value = inputs[name];
        present = bytes(value).length != 0;
    }
}

/// @dev DeployLoveh1 with its inputs supplied by the test, for the same reason.
contract DeployLoveh1Harness is DeployLoveh1 {
    mapping(string name => string value) internal inputs;

    function give(string memory name, string memory value) external {
        inputs[name] = value;
    }

    function _raw(string memory name) internal view override returns (bool present, string memory value) {
        value = inputs[name];
        present = bytes(value).length != 0;
    }
}

/// @notice The deployment scripts, run on the local test chain with test inputs: each creates what
///         it says, wired as it says, and each refuses a missing or malformed input.
contract DeployScriptsTest is Test {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant BASE_RATE = 0.01e18 / YEAR;
    uint256 internal constant SLOPE_BELOW = 0.04e18 / YEAR;
    uint256 internal constant SLOPE_ABOVE = 1e18 / YEAR;
    uint256 internal constant TARGET = 0.8e18;

    /// @dev One test value for the beneficiary, the same in every test that sets the environment, so
    ///      that tests running side by side never read different values from the one process environment.
    address internal beneficiary = makeAddr("test beneficiary");
    address internal stranger = makeAddr("stranger");

    string[5] internal names = [
        "LOVEH_BENEFICIARY",
        "LOVEH_KINKED_BASE_RATE",
        "LOVEH_KINKED_SLOPE_BELOW",
        "LOVEH_KINKED_SLOPE_ABOVE",
        "LOVEH_KINKED_TARGET_UTILISATION"
    ];

    function _values() internal view returns (string[5] memory values) {
        values[0] = vm.toString(beneficiary);
        values[1] = vm.toString(BASE_RATE);
        values[2] = vm.toString(SLOPE_BELOW);
        values[3] = vm.toString(SLOPE_ABOVE);
        values[4] = vm.toString(TARGET);
    }

    function _setEnvironment() internal {
        string[5] memory values = _values();
        for (uint256 i = 0; i < 5; ++i) {
            vm.setEnv(names[i], values[i]);
        }
    }

    function _loveh1HarnessWithAllInputs() internal returns (DeployLoveh1Harness script) {
        script = new DeployLoveh1Harness();
        string[5] memory values = _values();
        for (uint256 i = 0; i < 5; ++i) {
            script.give(names[i], values[i]);
        }
    }

    // ------------------------------------------------------------------ DeployTill

    function test_deployTill_fromTheEnvironment() public {
        _setEnvironment();
        FoundationTill till = new DeployTill().run();
        assertTrue(address(till).code.length > 0, "a till was created");
        assertEq(till.beneficiary(), beneficiary);
        assertEq(till.successor(), address(0));
    }

    function test_deployTill_fromTestInputs() public {
        DeployTillHarness script = new DeployTillHarness();
        script.give("LOVEH_BENEFICIARY", vm.toString(beneficiary));
        FoundationTill till = script.run();
        assertEq(till.beneficiary(), beneficiary);
        // The till works: the beneficiary collects what reaches it.
        MockERC20 coin = new MockERC20("Coin", "COIN", 18);
        coin.mint(address(till), 3e18);
        vm.prank(beneficiary);
        till.collect(address(coin));
        assertEq(coin.balanceOf(beneficiary), 3e18);
    }

    function test_deployTill_refusesMissingInput() public {
        DeployTillHarness script = new DeployTillHarness();
        vm.expectRevert(bytes("missing input: LOVEH_BENEFICIARY"));
        script.run();
    }

    function test_deployTill_refusesMalformedInput() public {
        DeployTillHarness script = new DeployTillHarness();
        script.give("LOVEH_BENEFICIARY", "not an address");
        vm.expectRevert(bytes("malformed input, not an address: LOVEH_BENEFICIARY"));
        script.run();
        script.give("LOVEH_BENEFICIARY", vm.toString(address(0)));
        vm.expectRevert(bytes("malformed input, the zero address: LOVEH_BENEFICIARY"));
        script.run();
    }

    // ------------------------------------------------------------------ DeployLoveh1

    function test_deployLoveh1_fromTheEnvironment() public {
        _setEnvironment();
        (FoundationTill till, KinkedRateFormula formula, MarketFactory factory) = new DeployLoveh1().run();
        _assertWired(till, formula, factory);
    }

    function test_deployLoveh1_fromTestInputs_wiredAsSaid() public {
        DeployLoveh1Harness script = _loveh1HarnessWithAllInputs();
        (FoundationTill till, KinkedRateFormula formula, MarketFactory factory) = script.run();
        _assertWired(till, formula, factory);
    }

    function test_deployLoveh1_deploysInOrder() public {
        DeployLoveh1Harness script = _loveh1HarnessWithAllInputs();
        (FoundationTill till, KinkedRateFormula formula, MarketFactory factory) = script.run();
        // One sender creates all three in a row, so the three addresses come from three consecutive
        // nonces of that sender: till first, then the formula, then the factory.
        address[2] memory candidates = [address(script), DEFAULT_SENDER];
        bool found;
        for (uint256 c = 0; c < candidates.length && !found; ++c) {
            for (uint64 nonce = 0; nonce < 16; ++nonce) {
                if (vm.computeCreateAddress(candidates[c], nonce) != address(till)) continue;
                found = true;
                assertEq(vm.computeCreateAddress(candidates[c], nonce + 1), address(formula), "formula second");
                assertEq(vm.computeCreateAddress(candidates[c], nonce + 2), address(factory), "factory third");
                break;
            }
        }
        assertTrue(found, "the till was created by the script's sender");
    }

    function test_deployLoveh1_marketWithKinkedFormula_linearRefused() public {
        DeployLoveh1Harness script = _loveh1HarnessWithAllInputs();
        (FoundationTill till, KinkedRateFormula formula, MarketFactory factory) = script.run();

        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 coll = new MockERC20("Collateral", "COLL", 18);
        MockPriceSource price = new MockPriceSource(2000e36);

        // The linear formula is not listed: a market on it is refused, deployed by anyone.
        LinearRateFormula linear = new LinearRateFormula(0, 0.1e18 / YEAR);
        assertFalse(factory.isPermittedRateFormula(address(linear)));
        vm.prank(stranger);
        vm.expectRevert(IMarketFactory.RateFormulaNotPermitted.selector);
        factory.createMarket(address(loan), address(coll), address(price), 0.86e18, address(linear));

        // A market on the kinked formula is created, pays the till, and the beneficiary collects.
        vm.prank(stranger);
        Market market =
            Market(factory.createMarket(address(loan), address(coll), address(price), 0.86e18, address(formula)));
        assertEq(market.rateFormula(), address(formula));
        assertEq(market.feeRecipient(), address(till));

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        loan.mint(lender, 1000e18);
        vm.startPrank(lender);
        loan.approve(address(market), type(uint256).max);
        market.deposit(1000e18, lender);
        vm.stopPrank();
        coll.mint(borrower, 1e18);
        vm.startPrank(borrower);
        coll.approve(address(market), type(uint256).max);
        market.depositCollateral(1e18, borrower);
        market.borrow(800e18, borrower);
        vm.stopPrank();
        skip(YEAR);
        uint256 owed = market.feeOwed();
        assertGt(owed, 0);
        assertEq(owed, market.totalInterest() / 10);
        loan.mint(borrower, 1000e18);
        vm.startPrank(borrower);
        loan.approve(address(market), type(uint256).max);
        market.repay(type(uint256).max, borrower);
        vm.stopPrank();
        market.payFee();
        assertEq(loan.balanceOf(address(till)), owed, "the market paid the till");
        vm.prank(beneficiary);
        till.collect(address(loan));
        assertEq(loan.balanceOf(beneficiary), owed, "the beneficiary collected it");
    }

    function test_deployLoveh1_refusesEachMissingInput() public {
        string[5] memory values = _values();
        for (uint256 missing = 0; missing < 5; ++missing) {
            DeployLoveh1Harness script = new DeployLoveh1Harness();
            for (uint256 i = 0; i < 5; ++i) {
                if (i != missing) script.give(names[i], values[i]);
            }
            vm.expectRevert(bytes(string.concat("missing input: ", names[missing])));
            script.run();
        }
    }

    function test_deployLoveh1_refusesMalformedInputs() public {
        DeployLoveh1Harness script = _loveh1HarnessWithAllInputs();
        script.give("LOVEH_KINKED_SLOPE_BELOW", "fast");
        vm.expectRevert(bytes("malformed input, not an unsigned integer: LOVEH_KINKED_SLOPE_BELOW"));
        script.run();
        script.give("LOVEH_KINKED_SLOPE_BELOW", "-1");
        vm.expectRevert(bytes("malformed input, not an unsigned integer: LOVEH_KINKED_SLOPE_BELOW"));
        script.run();
        script.give("LOVEH_KINKED_SLOPE_BELOW", vm.toString(SLOPE_BELOW));
        script.give("LOVEH_BENEFICIARY", "0x1234");
        vm.expectRevert(bytes("malformed input, not an address: LOVEH_BENEFICIARY"));
        script.run();
    }

    // The figures reach the existing formula unchanged, and its own checks stand. One case per test:
    // a revert inside a broadcast leaves the broadcast open for the rest of the test.

    function test_deployLoveh1_formulaRefusesSlopeAboveNotSteeper() public {
        DeployLoveh1Harness script = _loveh1HarnessWithAllInputs();
        script.give("LOVEH_KINKED_SLOPE_ABOVE", vm.toString(SLOPE_BELOW));
        vm.expectRevert(KinkedRateFormula.SlopeAboveNotSteeper.selector);
        script.run();
    }

    function test_deployLoveh1_formulaRefusesTargetAtOne() public {
        DeployLoveh1Harness script = _loveh1HarnessWithAllInputs();
        script.give("LOVEH_KINKED_TARGET_UTILISATION", vm.toString(uint256(1e18)));
        vm.expectRevert(KinkedRateFormula.InvalidTarget.selector);
        script.run();
    }

    // ------------------------------------------------------------------ helpers

    function _assertWired(FoundationTill till, KinkedRateFormula formula, MarketFactory factory) internal view {
        assertTrue(address(till).code.length > 0, "a till was created");
        assertTrue(address(formula).code.length > 0, "a formula was created");
        assertTrue(address(factory).code.length > 0, "a factory was created");
        assertEq(till.beneficiary(), beneficiary, "the till's beneficiary is the input");
        assertEq(till.successor(), address(0));
        assertEq(factory.feeRecipient(), address(till), "the factory's fee recipient is the till");
        address[] memory listed = factory.permittedRateFormulas();
        assertEq(listed.length, 1, "exactly one permitted formula");
        assertEq(listed[0], address(formula), "the kinked formula");
        assertTrue(factory.isPermittedRateFormula(address(formula)));
        assertEq(factory.marketCount(), 0, "no market yet");
        assertEq(formula.baseRate(), BASE_RATE);
        assertEq(formula.slopeBelow(), SLOPE_BELOW);
        assertEq(formula.slopeAbove(), SLOPE_ABOVE);
        assertEq(formula.targetUtilisation(), TARGET);
    }
}
