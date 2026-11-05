// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KinkedRateFormula} from "../src/rates/KinkedRateFormula.sol";
import {LinearRateFormula} from "../src/rates/LinearRateFormula.sol";

contract RateFormulasTest is Test {
    uint256 internal constant WAD = 1e18;
    LinearRateFormula internal linear;
    KinkedRateFormula internal kinked;

    function setUp() public {
        linear = new LinearRateFormula(1e9, 10e9);
        kinked = new KinkedRateFormula(1e9, 4e9, 100e9, 0.8e18);
    }

    function test_linear_parametersAndShape() public view {
        assertEq(linear.baseRate(), 1e9);
        assertEq(linear.slope(), 10e9);
        assertEq(linear.ratePerSecond(0, 0), 1e9);
        assertEq(linear.ratePerSecond(0, 100), 1e9);
        assertEq(linear.ratePerSecond(50, 100), 1e9 + 5e9);
        assertEq(linear.ratePerSecond(100, 100), 11e9);
        assertEq(linear.ratePerSecond(200, 100), 11e9, "capped at full utilisation");
        assertEq(linear.ratePerSecond(100, 0), 11e9, "loans without deposits count as full utilisation");
    }

    function test_kinked_parametersAndShape() public view {
        assertEq(kinked.baseRate(), 1e9);
        assertEq(kinked.slopeBelow(), 4e9);
        assertEq(kinked.slopeAbove(), 100e9);
        assertEq(kinked.targetUtilisation(), 0.8e18);
        assertEq(kinked.ratePerSecond(0, 100), 1e9);
        assertEq(kinked.ratePerSecond(40, 100), 1e9 + 1.6e9);
        assertEq(kinked.ratePerSecond(80, 100), 1e9 + 3.2e9);
        assertEq(kinked.ratePerSecond(90, 100), 1e9 + 3.2e9 + 10e9);
        assertEq(kinked.ratePerSecond(100, 100), 1e9 + 3.2e9 + 20e9);
        assertEq(kinked.ratePerSecond(300, 100), 1e9 + 3.2e9 + 20e9, "capped at full utilisation");
        assertEq(kinked.ratePerSecond(5, 0), 1e9 + 3.2e9 + 20e9);
    }

    function test_constructors_reject() public {
        vm.expectRevert(LinearRateFormula.ZeroSlope.selector);
        new LinearRateFormula(0, 0);
        vm.expectRevert(KinkedRateFormula.ZeroSlope.selector);
        new KinkedRateFormula(0, 0, 1, 0.5e18);
        vm.expectRevert(KinkedRateFormula.SlopeAboveNotSteeper.selector);
        new KinkedRateFormula(0, 2, 2, 0.5e18);
        vm.expectRevert(KinkedRateFormula.SlopeAboveNotSteeper.selector);
        new KinkedRateFormula(0, 3, 2, 0.5e18);
        vm.expectRevert(KinkedRateFormula.InvalidTarget.selector);
        new KinkedRateFormula(0, 1, 2, 0);
        vm.expectRevert(KinkedRateFormula.InvalidTarget.selector);
        new KinkedRateFormula(0, 1, 2, 1e18);
    }

    /// @dev The higher the utilisation, the higher the rate, for both formulas.
    function testFuzz_monotone(uint256 deposits, uint256 loansA, uint256 loansB) public view {
        deposits = bound(deposits, 1, 1e40);
        loansA = bound(loansA, 0, deposits);
        loansB = bound(loansB, loansA, deposits);
        assertLe(linear.ratePerSecond(loansA, deposits), linear.ratePerSecond(loansB, deposits));
        assertLe(kinked.ratePerSecond(loansA, deposits), kinked.ratePerSecond(loansB, deposits));
    }

    function testFuzz_strictlyIncreasingAcrossOnePercent(uint256 u) public view {
        u = bound(u, 0, 98);
        assertLt(linear.ratePerSecond(u, 100), linear.ratePerSecond(u + 1, 100));
        assertLt(kinked.ratePerSecond(u, 100), kinked.ratePerSecond(u + 1, 100));
    }

    function testFuzz_kinkIsSteeperAbove(uint256 below, uint256 above) public view {
        below = bound(below, 0, 0.8e18 - 1e12);
        above = bound(above, 0.8e18, WAD - 1e12);
        uint256 slopeBelow = kinked.ratePerSecond(below + 1e12, WAD) - kinked.ratePerSecond(below, WAD);
        uint256 slopeAbove = kinked.ratePerSecond(above + 1e12, WAD) - kinked.ratePerSecond(above, WAD);
        assertGt(slopeAbove, slopeBelow);
    }

    function testFuzz_bounded(uint256 loans, uint256 deposits) public view {
        assertLe(linear.ratePerSecond(loans, deposits), linear.baseRate() + linear.slope());
        assertLe(
            kinked.ratePerSecond(loans, deposits),
            kinked.baseRate() + kinked.slopeBelow() * kinked.targetUtilisation() / WAD + kinked.slopeAbove()
                * (WAD - kinked.targetUtilisation()) / WAD
        );
    }
}
