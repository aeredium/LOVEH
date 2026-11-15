// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {FoundationTill} from "../src/FoundationTill.sol";

/// @title LovehInputs
/// @notice Reads a deployment script's inputs from environment variables. A missing, empty or
///         malformed input stops the script with a message naming the variable. The scripts never
///         hold or name the deployer's signing secret: whoever runs them supplies the sender on the
///         command line.
abstract contract LovehInputs is Script {
    /// @dev The raw text of an input, and whether it is present at all. Virtual so that a test can
    ///      supply inputs without touching the process environment.
    function _raw(string memory name) internal view virtual returns (bool present, string memory value) {
        if (!vm.envExists(name)) return (false, "");
        value = vm.envString(name);
        present = bytes(value).length != 0;
    }

    function _addressInput(string memory name) internal view returns (address parsed) {
        (bool present, string memory value) = _raw(name);
        if (!present) revert(string.concat("missing input: ", name));
        try vm.parseAddress(value) returns (address a) {
            parsed = a;
        } catch {
            revert(string.concat("malformed input, not an address: ", name));
        }
        if (parsed == address(0)) revert(string.concat("malformed input, the zero address: ", name));
    }

    function _uintInput(string memory name) internal view returns (uint256 parsed) {
        (bool present, string memory value) = _raw(name);
        if (!present) revert(string.concat("missing input: ", name));
        try vm.parseUint(value) returns (uint256 u) {
            parsed = u;
        } catch {
            revert(string.concat("malformed input, not an unsigned integer: ", name));
        }
    }
}

/// @title DeployTill
/// @notice Deploys one FoundationTill. Input: LOVEH_BENEFICIARY, the address that alone can collect
///         from the till and name its successor.
contract DeployTill is LovehInputs {
    function run() external returns (FoundationTill till) {
        address beneficiary = _addressInput("LOVEH_BENEFICIARY");

        vm.startBroadcast();
        till = new FoundationTill(beneficiary);
        vm.stopBroadcast();

        if (till.beneficiary() != beneficiary) revert("the till's beneficiary differs from LOVEH_BENEFICIARY");

        console2.log("FoundationTill", address(till));
    }
}
