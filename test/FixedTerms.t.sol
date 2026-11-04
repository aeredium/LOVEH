// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {SurfaceTest} from "./Surface.t.sol";

/// @notice Fixed terms: every external function of every contract is listed against an approved list,
///         with its state mutability. The terms, the fee, the fee recipient, the discount and the
///         permitted formulas are read by view functions only; the state-changing functions are the
///         market actions and nothing else. Any function added to any contract fails this test until
///         it is listed here on purpose.
contract FixedTermsTest is SurfaceTest {
    // ------------------------------------------------------------------ approved lists

    function _approved(string memory contractName)
        internal
        pure
        returns (string[] memory views, string[] memory actions)
    {
        if (_eq(contractName, "MarketFactory")) {
            views = new string[](7);
            views[0] = "feeRecipient";
            views[1] = "permittedRateFormulas";
            views[2] = "isPermittedRateFormula";
            views[3] = "marketCount";
            views[4] = "markets";
            views[5] = "marketFor";
            views[6] = "isMarket";
            actions = new string[](1);
            actions[0] = "createMarket";
        } else if (_eq(contractName, "Market")) {
            views = new string[](32);
            // the terms, all immutable
            views[0] = "loanToken";
            views[1] = "collateralToken";
            views[2] = "priceSource";
            views[3] = "borrowingLimit";
            views[4] = "rateFormula";
            views[5] = "feeRecipient";
            views[6] = "liquidationIncentive";
            views[7] = "receiptToken";
            views[8] = "FEE";
            // audit views
            views[9] = "deposits";
            views[10] = "loans";
            views[11] = "unlent";
            views[12] = "collateral";
            views[13] = "collateralValue";
            views[14] = "feePaid";
            views[15] = "feeOwed";
            views[16] = "feeWrittenOff";
            views[17] = "totalInterest";
            views[18] = "totalLoss";
            views[19] = "lastAccrual";
            views[20] = "totalReceipts";
            views[21] = "totalLoanUnits";
            views[22] = "depositOf";
            views[23] = "loanOf";
            views[24] = "loanUnitsOf";
            views[25] = "collateralOf";
            views[26] = "maxLoanOf";
            views[27] = "receiptsFor";
            views[28] = "valueOf";
            views[29] = "borrowerCount";
            views[30] = "borrowerAt";
            views[31] = "loansAboveLimit";
            actions = new string[](9);
            actions[0] = "deposit";
            actions[1] = "withdraw";
            actions[2] = "depositCollateral";
            actions[3] = "withdrawCollateral";
            actions[4] = "borrow";
            actions[5] = "repay";
            actions[6] = "liquidate";
            actions[7] = "payFee";
            actions[8] = "accrue";
        } else if (_eq(contractName, "ReceiptToken")) {
            views = new string[](7);
            views[0] = "market";
            views[1] = "name";
            views[2] = "symbol";
            views[3] = "decimals";
            views[4] = "totalSupply";
            views[5] = "balanceOf";
            views[6] = "allowance";
            actions = new string[](5);
            actions[0] = "approve";
            actions[1] = "transfer";
            actions[2] = "transferFrom";
            actions[3] = "mint";
            actions[4] = "burn";
        } else if (_eq(contractName, "LinearRateFormula")) {
            views = new string[](3);
            views[0] = "baseRate";
            views[1] = "slope";
            views[2] = "ratePerSecond";
            actions = new string[](0);
        } else if (_eq(contractName, "KinkedRateFormula")) {
            views = new string[](5);
            views[0] = "baseRate";
            views[1] = "slopeBelow";
            views[2] = "slopeAbove";
            views[3] = "targetUtilisation";
            views[4] = "ratePerSecond";
            actions = new string[](0);
        } else {
            revert("unknown contract");
        }
    }

    // ------------------------------------------------------------------ tests

    function test_everyExternalFunctionIsApproved() public view {
        for (uint256 c = 0; c < contracts.length; ++c) {
            string memory name = contracts[c];
            (string[] memory views, string[] memory actions) = _approved(name);
            Fn[] memory fns = _functions(name);
            uint256 counted;
            for (uint256 i = 0; i < fns.length; ++i) {
                bool isView = _eq(fns[i].mutability, "view") || _eq(fns[i].mutability, "pure");
                if (isView) {
                    assertTrue(_has(views, fns[i].name), string.concat(name, ": unapproved view ", fns[i].name));
                } else {
                    assertTrue(_has(actions, fns[i].name), string.concat(name, ": unapproved action ", fns[i].name));
                }
                ++counted;
            }
            // Every approved name is present, so the list cannot drift from the code.
            for (uint256 i = 0; i < views.length; ++i) {
                assertTrue(_present(fns, views[i]), string.concat(name, ": missing view ", views[i]));
            }
            for (uint256 i = 0; i < actions.length; ++i) {
                assertTrue(_present(fns, actions[i]), string.concat(name, ": missing action ", actions[i]));
            }
            assertEq(counted, fns.length);
        }
    }

    /// @dev No function anywhere can change a term, the fee, the fee recipient, the discount or the
    ///      permitted formulas: every state-changing function is a market action or a token move.
    function test_noFunctionChangesAnyTerm() public view {
        string[] memory termWords = new string[](12);
        termWords[0] = "set";
        termWords[1] = "update";
        termWords[2] = "change";
        termWords[3] = "configure";
        termWords[4] = "add";
        termWords[5] = "remove";
        termWords[6] = "permit";
        termWords[7] = "fee";
        termWords[8] = "recipient";
        termWords[9] = "limit";
        termWords[10] = "incentive";
        termWords[11] = "formula";
        for (uint256 c = 0; c < contracts.length; ++c) {
            Fn[] memory fns = _functions(contracts[c]);
            for (uint256 i = 0; i < fns.length; ++i) {
                if (_eq(fns[i].mutability, "view") || _eq(fns[i].mutability, "pure")) continue;
                string memory lower = _lower(fns[i].name);
                for (uint256 w = 0; w < termWords.length; ++w) {
                    // payFee is the one allowed function naming the fee: it pays it, it cannot change it.
                    if (_eq(lower, "payfee") && _eq(termWords[w], "fee")) continue;
                    assertFalse(
                        _contains(lower, termWords[w]),
                        string.concat(contracts[c], ": state-changing function names a term: ", fns[i].name)
                    );
                }
            }
        }
    }

    function test_noPayableFunctions() public view {
        for (uint256 c = 0; c < contracts.length; ++c) {
            Fn[] memory fns = _functions(contracts[c]);
            for (uint256 i = 0; i < fns.length; ++i) {
                assertFalse(_eq(fns[i].mutability, "payable"), string.concat(contracts[c], ": payable ", fns[i].name));
            }
            // No receive or fallback either.
            string memory json = _abi(contracts[c]);
            assertFalse(_hasEntryOfType(json, "receive"), "receive");
            assertFalse(_hasEntryOfType(json, "fallback"), "fallback");
        }
    }

    function _present(Fn[] memory fns, string memory name) internal pure returns (bool) {
        for (uint256 i = 0; i < fns.length; ++i) {
            if (_eq(fns[i].name, name)) return true;
        }
        return false;
    }
}
