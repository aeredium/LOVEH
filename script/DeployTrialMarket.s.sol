// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

// TEST NETWORK ONLY. This script deploys mock coins and a mock price source that anyone can mint or
// move. It exists to try a LOVEH2 market on the test network and must never be run against a live
// network: `run()` reverts unless the chain id is one of the two test networks named below.

import {Script, console2} from "forge-std/Script.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {TrialCoin} from "./trial/TrialCoin.sol";
import {TrialPriceSource} from "./trial/TrialPriceSource.sol";

/// @title DeployTrialMarket
/// @notice Deploys two trial coins and one trial price source, and creates one market in the given
///         factory with the given formula. The sender is supplied on the command line.
///
/// Inputs, each an environment variable, each required:
///   LOVEH_FACTORY          the market factory
///   LOVEH_RATE_FORMULA     a formula the factory permits
///   LOVEH_BORROWING_LIMIT  the market's borrowing limit, scaled by 1e18, strictly between 0 and 1e18
///
/// The trial coins have 18 decimals; the trial price is 2000e36, so one whole collateral coin is
/// worth 2000 whole loan coins. These are test values, fixed here.
///
/// The script runs on a test network only: on any chain whose id is not one of the two named below it
/// reverts before deploying anything. No main network's id is ever on the list.
contract DeployTrialMarket is Script {
    uint8 internal constant TRIAL_DECIMALS = 18;
    uint256 internal constant TRIAL_PRICE = 2000e36;

    /// @dev The Foundry local chain (anvil, and the chain `forge test` runs on).
    uint256 internal constant FOUNDRY_LOCAL_CHAIN_ID = 31337;
    /// @dev The AEREDIUM test network.
    uint256 internal constant AEREDIUM_TEST_CHAIN_ID = 2237;

    function run()
        external
        returns (TrialCoin loanCoin, TrialCoin collateralCoin, TrialPriceSource priceSource, address market)
    {
        if (block.chainid != FOUNDRY_LOCAL_CHAIN_ID && block.chainid != AEREDIUM_TEST_CHAIN_ID) {
            revert("DeployTrialMarket runs on a test network only");
        }
        address factory = _address("LOVEH_FACTORY");
        address rateFormula = _address("LOVEH_RATE_FORMULA");
        uint256 borrowingLimit = _uint("LOVEH_BORROWING_LIMIT");

        vm.startBroadcast();
        loanCoin = new TrialCoin("Trial Loan Coin", "TLOAN", TRIAL_DECIMALS);
        collateralCoin = new TrialCoin("Trial Collateral Coin", "TCOLL", TRIAL_DECIMALS);
        priceSource = new TrialPriceSource(TRIAL_PRICE);
        market = MarketFactory(factory)
            .createMarket(address(loanCoin), address(collateralCoin), address(priceSource), borrowingLimit, rateFormula);
        vm.stopBroadcast();

        console2.log("TrialCoin (loan)", address(loanCoin));
        console2.log("TrialCoin (collateral)", address(collateralCoin));
        console2.log("TrialPriceSource", address(priceSource));
        console2.log("Market", market);
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
}
