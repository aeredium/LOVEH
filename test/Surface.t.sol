// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Reads the external surface of every contract from the compiled ABI, so the lists below
///         are checked against what is actually deployed, not against the source alone.
abstract contract SurfaceTest is Test {
    struct Fn {
        string name;
        string mutability;
    }

    string[] internal contracts = ["MarketFactory", "Market", "ReceiptToken", "LinearRateFormula", "KinkedRateFormula"];

    function _abi(string memory contractName) internal view returns (string memory) {
        return vm.readFile(string.concat("out/", contractName, ".sol/", contractName, ".json"));
    }

    /// @dev Every ABI entry of type function, with its state mutability, read entry by entry.
    function _functions(string memory contractName) internal view returns (Fn[] memory fns) {
        string memory json = _abi(contractName);
        uint256 total = _abiLength(json);
        assertGt(total, 0, "abi empty");
        Fn[] memory all = new Fn[](total);
        uint256 n;
        for (uint256 i = 0; i < total; ++i) {
            string memory path = string.concat("$.abi[", vm.toString(i), "]");
            string memory kind = vm.parseJsonString(json, string.concat(path, ".type"));
            if (!_eq(kind, "function")) continue;
            all[n++] = Fn(
                vm.parseJsonString(json, string.concat(path, ".name")),
                vm.parseJsonString(json, string.concat(path, ".stateMutability"))
            );
        }
        fns = new Fn[](n);
        for (uint256 i = 0; i < n; ++i) {
            fns[i] = all[i];
        }
    }

    function _abiLength(string memory json) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat("$.abi[", vm.toString(n), "]"))) {
            ++n;
        }
    }

    /// @dev True if the ABI holds an entry of this type (receive, fallback, ...).
    function _hasEntryOfType(string memory json, string memory kind) internal view returns (bool) {
        uint256 total = _abiLength(json);
        for (uint256 i = 0; i < total; ++i) {
            string memory t = vm.parseJsonString(json, string.concat("$.abi[", vm.toString(i), "].type"));
            if (_eq(t, kind)) return true;
        }
        return false;
    }

    function _has(string[] memory list, string memory name) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (keccak256(bytes(list[i])) == keccak256(bytes(name))) return true;
        }
        return false;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; ++i) {
            bool match_ = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}
