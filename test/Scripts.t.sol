// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployLoveh2} from "../script/DeployLoveh2.s.sol";
import {DeployTrialMarket} from "../script/DeployTrialMarket.s.sol";
import {TrialCoin} from "../script/trial/TrialCoin.sol";
import {TrialPriceSource} from "../script/trial/TrialPriceSource.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {IRateRecord} from "../interfaces/IRateRecord.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {FollowingRateFormula} from "../src/rates/FollowingRateFormula.sol";
import {RateRecord} from "../src/rates/RateRecord.sol";

/// @notice The two deployment scripts, run on the local test chain with test inputs: each creates
///         what it says, wired as it says, and each refuses a missing input. The inputs are set in
///         the process environment, so each script's checks run in one test, in order.
contract ScriptsTest is Test {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_RATE = 1e18 / YEAR;
    uint256 internal constant INITIAL_CENTRE = 0.05e18 / YEAR;

    address internal feeRecipient = makeAddr("AEREDIUM Foundation Limited");
    address internal signer = makeAddr("AERKey signer");

    string[8] internal loveh2Names = [
        "LOVEH_FEE_RECIPIENT",
        "LOVEH_SIGNER",
        "LOVEH_CANDIDATES",
        "LOVEH_MAX_RATE",
        "LOVEH_INITIAL_CENTRE",
        "LOVEH_TARGET_UTILISATION",
        "LOVEH_FLOOR_FRACTION",
        "LOVEH_FULL_MULTIPLE"
    ];
    string[3] internal trialNames = ["LOVEH_FACTORY", "LOVEH_RATE_FORMULA", "LOVEH_BORROWING_LIMIT"];

    function _candidateList() internal pure returns (string memory list, bytes32[10] memory labels) {
        for (uint256 i = 0; i < 10; ++i) {
            labels[i] = keccak256(abi.encodePacked("candidate ", i));
            list = i == 0 ? vm.toString(labels[i]) : string.concat(list, ",", vm.toString(labels[i]));
        }
    }

    function _setLoveh2Inputs() internal returns (bytes32[10] memory labels) {
        string memory list;
        (list, labels) = _candidateList();
        vm.setEnv("LOVEH_FEE_RECIPIENT", vm.toString(feeRecipient));
        vm.setEnv("LOVEH_SIGNER", vm.toString(signer));
        vm.setEnv("LOVEH_CANDIDATES", list);
        vm.setEnv("LOVEH_MAX_RATE", vm.toString(MAX_RATE));
        vm.setEnv("LOVEH_INITIAL_CENTRE", vm.toString(INITIAL_CENTRE));
        vm.setEnv("LOVEH_TARGET_UTILISATION", vm.toString(uint256(0.8e18)));
        vm.setEnv("LOVEH_FLOOR_FRACTION", vm.toString(uint256(0.5e18)));
        vm.setEnv("LOVEH_FULL_MULTIPLE", vm.toString(uint256(4e18)));
    }

    function test_deployLoveh2() public {
        bytes32[10] memory labels = _setLoveh2Inputs();
        DeployLoveh2 script = new DeployLoveh2();
        (RateRecord record, FollowingRateFormula formula, MarketFactory factory) = script.run();

        // The record, as the inputs say.
        assertEq(record.signer(), signer);
        assertEq(record.maxRate(), MAX_RATE);
        assertEq(record.initialCentre(), INITIAL_CENTRE);
        assertEq(record.centre(), INITIAL_CENTRE);
        bytes32[10] memory stored = record.candidates();
        for (uint256 i = 0; i < 10; ++i) {
            assertEq(stored[i], labels[i]);
        }
        // The formula on that record.
        assertEq(formula.record(), address(record));
        assertEq(formula.ceiling(), MAX_RATE);
        assertEq(formula.targetUtilisation(), 0.8e18);
        assertEq(formula.floorFraction(), 0.5e18);
        assertEq(formula.fullMultiple(), 4e18);
        assertEq(formula.ratePerSecond(80, 100), INITIAL_CENTRE);
        // The factory with that fee recipient and that single formula.
        assertEq(factory.feeRecipient(), feeRecipient);
        address[] memory formulas = factory.permittedRateFormulas();
        assertEq(formulas.length, 1);
        assertEq(formulas[0], address(formula));
        assertEq(factory.marketCount(), 0);

        // Each input missing in turn: refused with a clear message, and nothing deployed.
        for (uint256 i = 0; i < loveh2Names.length; ++i) {
            string memory name = loveh2Names[i];
            vm.setEnv(name, "");
            vm.expectRevert(bytes(string.concat(name, " is not set")));
            script.run();
            _setLoveh2Inputs();
        }
        // A malformed list of candidates is refused too.
        vm.setEnv("LOVEH_CANDIDATES", vm.toString(labels[0]));
        vm.expectRevert(bytes("LOVEH_CANDIDATES must hold exactly ten values"));
        script.run();
        _setLoveh2Inputs();
        // Figures the contracts refuse stop the script with the contract's error. The revert happens
        // inside the broadcast the script opened; the test chain keeps that broadcast open across the
        // revert, so the test closes it before running the script again.
        vm.setEnv("LOVEH_INITIAL_CENTRE", "0");
        vm.expectRevert(IRateRecord.BadConfig.selector);
        script.run();
        vm.stopBroadcast();
        _setLoveh2Inputs();
        (RateRecord again,,) = script.run();
        assertEq(again.signer(), signer);
    }

    function test_deployTrialMarket() public {
        // A factory and a formula made directly, as the trial script expects them to exist already.
        (, bytes32[10] memory labels) = _candidateList();
        RateRecord record = new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, signer);
        FollowingRateFormula formula = new FollowingRateFormula(address(record), 0.8e18, 0.5e18, 4e18);
        address[] memory formulas = new address[](1);
        formulas[0] = address(formula);
        MarketFactory factory = new MarketFactory(feeRecipient, formulas);

        vm.setEnv("LOVEH_FACTORY", vm.toString(address(factory)));
        vm.setEnv("LOVEH_RATE_FORMULA", vm.toString(address(formula)));
        vm.setEnv("LOVEH_BORROWING_LIMIT", vm.toString(uint256(0.86e18)));
        DeployTrialMarket script = new DeployTrialMarket();
        (TrialCoin loanCoin, TrialCoin collateralCoin, TrialPriceSource priceSource, address market) = script.run();

        assertEq(loanCoin.decimals(), 18);
        assertEq(collateralCoin.decimals(), 18);
        assertTrue(address(loanCoin) != address(collateralCoin));
        assertEq(priceSource.price(), 2000e36);
        assertTrue(factory.isMarket(market));
        assertEq(factory.marketCount(), 1);
        Market m = Market(market);
        assertEq(m.loanToken(), address(loanCoin));
        assertEq(m.collateralToken(), address(collateralCoin));
        assertEq(m.priceSource(), address(priceSource));
        assertEq(m.borrowingLimit(), 0.86e18);
        assertEq(m.rateFormula(), address(formula));
        assertEq(m.feeRecipient(), feeRecipient);
        assertEq(m.FEE(), 0.1e18);

        // The trial coins and price source behave as the test mocks do.
        loanCoin.mint(address(this), 5e18);
        assertEq(loanCoin.balanceOf(address(this)), 5e18);
        priceSource.setPrice(1e36);
        assertEq(priceSource.price(), 1e36);
        priceSource.setReverting(true);
        vm.expectRevert(bytes("price source down"));
        priceSource.price();

        // Each input missing in turn: refused with a clear message.
        for (uint256 i = 0; i < trialNames.length; ++i) {
            string memory name = trialNames[i];
            string memory kept = vm.envString(name);
            vm.setEnv(name, "");
            vm.expectRevert(bytes(string.concat(name, " is not set")));
            script.run();
            vm.setEnv(name, kept);
        }
        // A limit the factory refuses stops the script with the factory's error.
        // (The revert happens inside the script's broadcast, which the test closes afterwards.)
        vm.setEnv("LOVEH_BORROWING_LIMIT", vm.toString(uint256(1e18)));
        vm.expectRevert(IMarketFactory.InvalidBorrowingLimit.selector);
        script.run();
        vm.stopBroadcast();
        vm.setEnv("LOVEH_BORROWING_LIMIT", vm.toString(uint256(0.86e18)));
        (,,, address second) = script.run();
        assertEq(factory.marketCount(), 2);
        assertTrue(factory.isMarket(second));
    }

    /// @dev The trial script runs on a test network only: on the Foundry local chain (31337) and on
    ///      the AEREDIUM test network (2237); on any other chain it reverts before deploying anything.
    function test_deployTrialMarket_refusesEveryChainButTheTestNetworks() public {
        (, bytes32[10] memory labels) = _candidateList();
        RateRecord record = new RateRecord(labels, MAX_RATE, INITIAL_CENTRE, signer);
        FollowingRateFormula formula = new FollowingRateFormula(address(record), 0.8e18, 0.5e18, 4e18);
        address[] memory formulas = new address[](1);
        formulas[0] = address(formula);
        MarketFactory factory = new MarketFactory(feeRecipient, formulas);
        vm.setEnv("LOVEH_FACTORY", vm.toString(address(factory)));
        vm.setEnv("LOVEH_RATE_FORMULA", vm.toString(address(formula)));
        vm.setEnv("LOVEH_BORROWING_LIMIT", vm.toString(uint256(0.86e18)));
        DeployTrialMarket script = new DeployTrialMarket();
        uint256 local = block.chainid;
        assertEq(local, 31337, "the test chain is the Foundry local chain");

        uint256[6] memory refused = [uint256(1), 10, 137, 2236, 2238, 31338];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.chainId(refused[i]);
            vm.expectRevert(bytes("DeployTrialMarket runs on a test network only"));
            script.run();
            assertEq(factory.marketCount(), 0, "nothing deployed");
        }

        vm.chainId(2237);
        (,,, address onTestNetwork) = script.run();
        assertTrue(factory.isMarket(onTestNetwork));
        assertEq(factory.marketCount(), 1);

        vm.chainId(local);
        (,,, address onLocal) = script.run();
        assertTrue(factory.isMarket(onLocal));
        assertEq(factory.marketCount(), 2);
    }

    /// @dev The trial mocks are copies of the test mocks and behave as they do.
    function test_trialMocksBehaveLikeTheTestMocks() public {
        TrialCoin coin = new TrialCoin("Trial Coin", "TRIAL", 18);
        assertEq(coin.decimals(), 18);
        coin.mint(address(this), 10e18);
        assertEq(coin.totalSupply(), 10e18);
        assertTrue(coin.approve(signer, 4e18));
        assertEq(coin.allowance(address(this), signer), 4e18);
        assertTrue(coin.transfer(feeRecipient, 1e18));
        assertEq(coin.balanceOf(feeRecipient), 1e18);
        vm.prank(signer);
        assertTrue(coin.transferFrom(address(this), feeRecipient, 3e18));
        assertEq(coin.allowance(address(this), signer), 1e18);
        vm.prank(signer);
        vm.expectRevert(bytes("allowance"));
        coin.transferFrom(address(this), feeRecipient, 2e18);
        vm.expectRevert(bytes("balance"));
        coin.transfer(feeRecipient, 100e18);
        coin.approve(signer, type(uint256).max);
        vm.prank(signer);
        coin.transferFrom(address(this), feeRecipient, 1e18);
        assertEq(coin.allowance(address(this), signer), type(uint256).max, "an infinite allowance is not reduced");

        TrialPriceSource source = new TrialPriceSource(2000e36);
        assertEq(source.price(), 2000e36);
        source.setPrice(7);
        assertEq(source.price(), 7);
        source.setMalformed(true);
        (bool ok, bytes memory data) = address(source).staticcall(abi.encodeWithSignature("price()"));
        assertTrue(ok);
        assertEq(data.length, 1, "malformed answer");
        source.setMalformed(false);
        source.setReverting(true);
        vm.expectRevert(bytes("price source down"));
        source.price();
    }
}
