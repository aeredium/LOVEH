// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";

import {FoundationTill} from "../src/FoundationTill.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {KinkedRateFormula} from "../src/rates/KinkedRateFormula.sol";
import {LovehInputs} from "./DeployTill.s.sol";

/// @title DeployLoveh1
/// @notice Deploys LOVEH1: the first family of markets, with the foundation's till as its fee
///         recipient and the kinked rate formula as its one permitted formula. In this order: one
///         FoundationTill, one KinkedRateFormula, one MarketFactory. The linear formula is not
///         deployed and not listed.
///
///         Inputs: LOVEH_BENEFICIARY (address); LOVEH_KINKED_BASE_RATE, LOVEH_KINKED_SLOPE_BELOW,
///         LOVEH_KINKED_SLOPE_ABOVE (per-second rates scaled by 1e18) and
///         LOVEH_KINKED_TARGET_UTILISATION (scaled by 1e18, strictly between 0 and 1e18), as the
///         formula takes them.
contract DeployLoveh1 is LovehInputs {
    function run() external returns (FoundationTill till, KinkedRateFormula formula, MarketFactory factory) {
        address beneficiary = _addressInput("LOVEH_BENEFICIARY");
        uint256 baseRate = _uintInput("LOVEH_KINKED_BASE_RATE");
        uint256 slopeBelow = _uintInput("LOVEH_KINKED_SLOPE_BELOW");
        uint256 slopeAbove = _uintInput("LOVEH_KINKED_SLOPE_ABOVE");
        uint256 targetUtilisation = _uintInput("LOVEH_KINKED_TARGET_UTILISATION");

        vm.startBroadcast();
        till = new FoundationTill(beneficiary);
        formula = new KinkedRateFormula(baseRate, slopeBelow, slopeAbove, targetUtilisation);
        address[] memory permitted = new address[](1);
        permitted[0] = address(formula);
        factory = new MarketFactory(address(till), permitted);
        vm.stopBroadcast();

        // Read back what was deployed and stop if anything differs.
        if (factory.feeRecipient() != address(till)) revert("the factory's fee recipient differs from the till");
        address[] memory listed = factory.permittedRateFormulas();
        if (listed.length != 1) revert("the factory lists more or fewer than one rate formula");
        if (listed[0] != address(formula)) revert("the factory's one rate formula differs from the kinked formula");
        if (till.beneficiary() != beneficiary) revert("the till's beneficiary differs from LOVEH_BENEFICIARY");

        console2.log("FoundationTill", address(till));
        console2.log("KinkedRateFormula", address(formula));
        console2.log("MarketFactory", address(factory));
    }
}
