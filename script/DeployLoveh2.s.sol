// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {FollowingRateFormula} from "../src/rates/FollowingRateFormula.sol";
import {RateRecord} from "../src/rates/RateRecord.sol";

/// @title DeployLoveh2
/// @notice Deploys the LOVEH2 family: one rate record, one following rate formula on it, and one
///         market factory whose single permitted formula is that formula. The sender is supplied on
///         the command line; the script holds nothing of it.
///
/// Inputs, each an environment variable, each required:
///   LOVEH_FEE_RECIPIENT       address paid the protocol fee by every market of this factory
///   LOVEH_SIGNER              the first signer of the rate record
///   LOVEH_CANDIDATES          ten bytes32 labels, comma separated
///   LOVEH_MAX_RATE            highest per-second rate a reading may state, scaled by 1e18
///   LOVEH_INITIAL_CENTRE      the centre before the record has a history, scaled by 1e18
///   LOVEH_TARGET_UTILISATION  utilisation at which the rate is the centre, scaled by 1e18
///   LOVEH_FLOOR_FRACTION      fraction of the centre charged at zero utilisation, scaled by 1e18
///   LOVEH_FULL_MULTIPLE       centres added between the target and full utilisation, scaled by 1e18
contract DeployLoveh2 is Script {
    function run() external returns (RateRecord record, FollowingRateFormula formula, MarketFactory factory) {
        address feeRecipient = _address("LOVEH_FEE_RECIPIENT");
        address signer = _address("LOVEH_SIGNER");
        bytes32[10] memory candidates = _candidates("LOVEH_CANDIDATES");
        uint256 maxRate = _uint("LOVEH_MAX_RATE");
        uint256 initialCentre = _uint("LOVEH_INITIAL_CENTRE");
        uint256 targetUtilisation = _uint("LOVEH_TARGET_UTILISATION");
        uint256 floorFraction = _uint("LOVEH_FLOOR_FRACTION");
        uint256 fullMultiple = _uint("LOVEH_FULL_MULTIPLE");

        vm.startBroadcast();
        record = new RateRecord(candidates, maxRate, initialCentre, signer);
        formula = new FollowingRateFormula(address(record), targetUtilisation, floorFraction, fullMultiple);
        address[] memory formulas = new address[](1);
        formulas[0] = address(formula);
        factory = new MarketFactory(feeRecipient, formulas);
        vm.stopBroadcast();

        console2.log("RateRecord", address(record));
        console2.log("FollowingRateFormula", address(formula));
        console2.log("MarketFactory", address(factory));
    }

    // ------------------------------------------------------------------ inputs

    function _present(string memory name) internal view {
        if (!vm.envExists(name) || bytes(vm.envString(name)).length == 0) {
            revert(string.concat(name, " is not set"));
        }
    }

    function _address(string memory name) internal view returns (address) {
        _present(name);
        return vm.envAddress(name);
    }

    function _uint(string memory name) internal view returns (uint256) {
        _present(name);
        return vm.envUint(name);
    }

    function _candidates(string memory name) internal view returns (bytes32[10] memory out) {
        _present(name);
        bytes32[] memory values = vm.envBytes32(name, ",");
        if (values.length != 10) revert(string.concat(name, " must hold exactly ten values"));
        for (uint256 i = 0; i < 10; ++i) {
            out[i] = values[i];
        }
    }
}
