// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {SurfaceTest} from "./Surface.t.sol";
import {FollowingRateFormula} from "../src/rates/FollowingRateFormula.sol";
import {RateRecord} from "../src/rates/RateRecord.sol";

/// @notice The external surface of the two LOVEH2 contracts, read from the compiled ABI: every
///         function is listed here on purpose with its mutability; the only state-changing functions
///         are the three instructions of the record; no function names an owner, an admin, a pause,
///         an upgrade or a role; nothing is payable; and no deployed bytecode holds SELFDESTRUCT or
///         DELEGATECALL. The only authority is the record's signer, and it changes only by a handover.
contract Loveh2SurfaceTest is SurfaceTest {
    constructor() {
        delete contracts;
        contracts.push("RateRecord");
        contracts.push("FollowingRateFormula");
    }

    function _approved(string memory contractName)
        internal
        pure
        returns (string[] memory views, string[] memory actions)
    {
        if (_eq(contractName, "RateRecord")) {
            views = new string[](18);
            // the figures fixed forever
            views[0] = "CANDIDATES";
            views[1] = "LEADERS";
            views[2] = "WINDOW";
            views[3] = "MIN_INTERVAL";
            views[4] = "HISTORY";
            views[5] = "ROTATE_DELAY";
            views[6] = "maxRate";
            views[7] = "initialCentre";
            views[8] = "candidates";
            // what the record answers
            views[9] = "signer";
            views[10] = "centre";
            views[11] = "leaders";
            views[12] = "lastAsOf";
            views[13] = "readingCount";
            views[14] = "readingAt";
            views[15] = "readingDigest";
            views[16] = "rotateDigest";
            views[17] = "eip712Domain";
            actions = new string[](3);
            actions[0] = "submitReading";
            actions[1] = "submitRotate";
            actions[2] = "executeRotate";
        } else if (_eq(contractName, "FollowingRateFormula")) {
            views = new string[](6);
            views[0] = "record";
            views[1] = "ceiling";
            views[2] = "targetUtilisation";
            views[3] = "floorFraction";
            views[4] = "fullMultiple";
            views[5] = "ratePerSecond";
            actions = new string[](0);
        } else {
            revert("unknown contract");
        }
    }

    function test_everyExternalFunctionIsApproved() public view {
        for (uint256 c = 0; c < contracts.length; ++c) {
            string memory name = contracts[c];
            (string[] memory views, string[] memory actions) = _approved(name);
            Fn[] memory fns = _functions(name);
            for (uint256 i = 0; i < fns.length; ++i) {
                bool isView = _eq(fns[i].mutability, "view") || _eq(fns[i].mutability, "pure");
                if (isView) {
                    assertTrue(_has(views, fns[i].name), string.concat(name, ": unapproved view ", fns[i].name));
                } else {
                    assertTrue(_has(actions, fns[i].name), string.concat(name, ": unapproved action ", fns[i].name));
                }
            }
            for (uint256 i = 0; i < views.length; ++i) {
                assertTrue(_present(fns, views[i]), string.concat(name, ": missing view ", views[i]));
            }
            for (uint256 i = 0; i < actions.length; ++i) {
                assertTrue(_present(fns, actions[i]), string.concat(name, ": missing action ", actions[i]));
            }
        }
    }

    function test_noOwnerAdminPauseUpgradeOrRoleFunction() public view {
        string[] memory forbidden = new string[](26);
        forbidden[0] = "owner";
        forbidden[1] = "admin";
        forbidden[2] = "pause";
        forbidden[3] = "unpause";
        forbidden[4] = "upgrade";
        forbidden[5] = "role";
        forbidden[6] = "governance";
        forbidden[7] = "governor";
        forbidden[8] = "implementation";
        forbidden[9] = "proxy";
        forbidden[10] = "renounce";
        forbidden[11] = "transferownership";
        forbidden[12] = "grant";
        forbidden[13] = "revoke";
        forbidden[14] = "authority";
        forbidden[15] = "operator";
        forbidden[16] = "guardian";
        forbidden[17] = "whitelist";
        forbidden[18] = "blacklist";
        forbidden[19] = "freeze";
        forbidden[20] = "kill";
        forbidden[21] = "destruct";
        forbidden[22] = "cancel";
        forbidden[23] = "suspend";
        forbidden[24] = "setsigner";
        forbidden[25] = "setcentre";
        for (uint256 c = 0; c < contracts.length; ++c) {
            Fn[] memory fns = _functions(contracts[c]);
            for (uint256 i = 0; i < fns.length; ++i) {
                string memory lower = _lower(fns[i].name);
                for (uint256 w = 0; w < forbidden.length; ++w) {
                    assertFalse(
                        _contains(lower, forbidden[w]),
                        string.concat(contracts[c], ": forbidden function ", fns[i].name)
                    );
                }
            }
        }
    }

    /// @dev No state-changing function names a term: the figures, the centre and the signer are read
    ///      by views only, and the signer moves only through the two handover instructions.
    function test_noFunctionChangesAnyTerm() public view {
        string[] memory termWords = new string[](11);
        termWords[0] = "set";
        termWords[1] = "update";
        termWords[2] = "change";
        termWords[3] = "configure";
        termWords[4] = "add";
        termWords[5] = "remove";
        termWords[6] = "centre";
        termWords[7] = "rate";
        termWords[8] = "candidate";
        termWords[9] = "formula";
        termWords[10] = "signer";
        for (uint256 c = 0; c < contracts.length; ++c) {
            Fn[] memory fns = _functions(contracts[c]);
            for (uint256 i = 0; i < fns.length; ++i) {
                if (_eq(fns[i].mutability, "view") || _eq(fns[i].mutability, "pure")) continue;
                string memory lower = _lower(fns[i].name);
                for (uint256 w = 0; w < termWords.length; ++w) {
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
            string memory json = _abi(contracts[c]);
            assertFalse(_hasEntryOfType(json, "receive"), "receive");
            assertFalse(_hasEntryOfType(json, "fallback"), "fallback");
        }
    }

    function test_noSelfdestructOrDelegatecallInBytecode() public {
        bytes32[10] memory labels;
        for (uint256 i = 0; i < 10; ++i) {
            labels[i] = bytes32(i + 1);
        }
        RateRecord record = new RateRecord(labels, uint256(1e18) / 365 days, 1, address(0x1));
        FollowingRateFormula formula = new FollowingRateFormula(address(record), 0.8e18, 0.5e18, 4e18);
        _assertNoOpcode(address(record).code, "RateRecord");
        _assertNoOpcode(address(formula).code, "FollowingRateFormula");
    }

    /// @dev Walks the runtime bytecode, skipping PUSH data, and fails on SELFDESTRUCT (0xff),
    ///      DELEGATECALL (0xf4) or CALLCODE (0xf2).
    function _assertNoOpcode(bytes memory code, string memory name) internal pure {
        assertGt(code.length, 0, "no code");
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0xff) revert(string.concat(name, ": SELFDESTRUCT found"));
            if (op == 0xf4) revert(string.concat(name, ": DELEGATECALL found"));
            if (op == 0xf2) revert(string.concat(name, ": CALLCODE found"));
            if (op >= 0x60 && op <= 0x7f) {
                i += (op - 0x5f) + 1;
            } else {
                ++i;
            }
        }
    }

    function _present(Fn[] memory fns, string memory name) internal pure returns (bool) {
        for (uint256 i = 0; i < fns.length; ++i) {
            if (_eq(fns[i].name, name)) return true;
        }
        return false;
    }
}
