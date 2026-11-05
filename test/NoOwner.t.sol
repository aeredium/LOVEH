// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {SurfaceTest} from "./Surface.t.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {ReceiptToken} from "../src/ReceiptToken.sol";
import {KinkedRateFormula} from "../src/rates/KinkedRateFormula.sol";
import {LinearRateFormula} from "../src/rates/LinearRateFormula.sol";

/// @notice No owner: no contract exposes an owner, admin, pause, upgrade or role function, and no
///         deployed bytecode contains SELFDESTRUCT or DELEGATECALL.
contract NoOwnerTest is SurfaceTest {
    function test_noOwnerAdminPauseUpgradeOrRoleFunction() public view {
        string[] memory forbidden = new string[](22);
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

    function test_noSelfdestructOrDelegatecallInBytecode() public {
        address[] memory formulas = new address[](1);
        LinearRateFormula lin = new LinearRateFormula(0, 1);
        formulas[0] = address(lin);
        MarketFactory f = new MarketFactory(address(this), formulas);
        address m = f.createMarket(address(0x1), address(0x2), address(0x3), 0.5e18, address(lin));
        KinkedRateFormula k = new KinkedRateFormula(0, 1, 2, 0.5e18);
        _assertNoOpcode(address(f).code, "MarketFactory");
        _assertNoOpcode(m.code, "Market");
        _assertNoOpcode(Market(m).receiptToken().code, "ReceiptToken");
        _assertNoOpcode(address(lin).code, "LinearRateFormula");
        _assertNoOpcode(address(k).code, "KinkedRateFormula");
    }

    /// @dev Walks the bytecode, skipping PUSH data, and fails on SELFDESTRUCT (0xff), DELEGATECALL (0xf4)
    ///      or CALLCODE (0xf2). Runtime code is checked, which is what matters once deployed.
    function _assertNoOpcode(bytes memory code, string memory name) internal pure {
        assertGt(code.length, 0, "no code");
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0xff) revert(string.concat(name, ": SELFDESTRUCT found"));
            if (op == 0xf4) revert(string.concat(name, ": DELEGATECALL found"));
            if (op == 0xf2) revert(string.concat(name, ": CALLCODE found"));
            if (op >= 0x60 && op <= 0x7f) {
                i += (op - 0x5f) + 1; // PUSH1..PUSH32 carry data bytes
            } else {
                ++i;
            }
        }
    }
}
