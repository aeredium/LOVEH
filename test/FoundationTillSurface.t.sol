// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {SurfaceTest} from "./Surface.t.sol";
import {FoundationTill} from "../src/FoundationTill.sol";

/// @notice The till's external surface, read from the compiled ABI: two views and three actions and
///         nothing else; no payable function, no receive, no fallback; no owner, administrative,
///         pause, upgrade or role function; no SELFDESTRUCT, DELEGATECALL or CALLCODE in the bytecode.
contract FoundationTillSurfaceTest is SurfaceTest {
    string internal constant TILL = "FoundationTill";

    function test_everyExternalFunctionIsListed() public view {
        string[] memory views = new string[](2);
        views[0] = "beneficiary";
        views[1] = "successor";
        string[] memory actions = new string[](3);
        actions[0] = "collect";
        actions[1] = "nameSuccessor";
        actions[2] = "acceptHandover";

        Fn[] memory fns = _functions(TILL);
        assertEq(fns.length, views.length + actions.length, "exactly five functions");
        for (uint256 i = 0; i < fns.length; ++i) {
            bool isView = _eq(fns[i].mutability, "view") || _eq(fns[i].mutability, "pure");
            if (isView) {
                assertTrue(_has(views, fns[i].name), string.concat(TILL, ": unlisted view ", fns[i].name));
            } else {
                assertTrue(_eq(fns[i].mutability, "nonpayable"), string.concat(TILL, ": payable ", fns[i].name));
                assertTrue(_has(actions, fns[i].name), string.concat(TILL, ": unlisted action ", fns[i].name));
            }
        }
        for (uint256 i = 0; i < views.length; ++i) {
            assertTrue(_present(fns, views[i]), string.concat(TILL, ": missing view ", views[i]));
        }
        for (uint256 i = 0; i < actions.length; ++i) {
            assertTrue(_present(fns, actions[i]), string.concat(TILL, ": missing action ", actions[i]));
        }
    }

    function test_noReceiveNoFallbackNoPayable() public view {
        string memory json = _abi(TILL);
        assertFalse(_hasEntryOfType(json, "receive"), "receive");
        assertFalse(_hasEntryOfType(json, "fallback"), "fallback");
        Fn[] memory fns = _functions(TILL);
        for (uint256 i = 0; i < fns.length; ++i) {
            assertFalse(_eq(fns[i].mutability, "payable"), string.concat(TILL, ": payable ", fns[i].name));
        }
        // The constructor takes no value either.
        uint256 total = _abiLength(json);
        for (uint256 i = 0; i < total; ++i) {
            string memory path = string.concat("$.abi[", vm.toString(i), "]");
            if (_eq(vm.parseJsonString(json, string.concat(path, ".type")), "constructor")) {
                assertEq(vm.parseJsonString(json, string.concat(path, ".stateMutability")), "nonpayable");
            }
        }
    }

    function test_noOwnerAdminPauseUpgradeOrRoleFunction() public view {
        string[] memory forbidden = new string[](24);
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
        forbidden[22] = "set";
        forbidden[23] = "withdraw";
        Fn[] memory fns = _functions(TILL);
        for (uint256 i = 0; i < fns.length; ++i) {
            string memory lower = _lower(fns[i].name);
            for (uint256 w = 0; w < forbidden.length; ++w) {
                assertFalse(_contains(lower, forbidden[w]), string.concat(TILL, ": forbidden function ", fns[i].name));
            }
        }
    }

    function test_noSelfdestructOrDelegatecallInBytecode() public {
        FoundationTill till = new FoundationTill(address(this));
        bytes memory code = address(till).code;
        assertGt(code.length, 0, "no code");
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0xff) revert("FoundationTill: SELFDESTRUCT found");
            if (op == 0xf4) revert("FoundationTill: DELEGATECALL found");
            if (op == 0xf2) revert("FoundationTill: CALLCODE found");
            if (op >= 0x60 && op <= 0x7f) {
                i += (op - 0x5f) + 1; // PUSH1..PUSH32 carry data bytes
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
