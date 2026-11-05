// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPoint} from "../src/FixedPoint.sol";

contract FixedPointHarness {
    function mulDivDown(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPoint.mulDivDown(x, y, d);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FixedPoint.mulDivUp(x, y, d);
    }

    function min(uint256 a, uint256 b) external pure returns (uint256) {
        return FixedPoint.min(a, b);
    }

    function zeroFloorSub(uint256 a, uint256 b) external pure returns (uint256) {
        return FixedPoint.zeroFloorSub(a, b);
    }
}

contract FixedPointTest is Test {
    FixedPointHarness internal fp = new FixedPointHarness();

    function test_values() public view {
        assertEq(fp.mulDivDown(10, 3, 4), 7);
        assertEq(fp.mulDivUp(10, 3, 4), 8);
        assertEq(fp.mulDivUp(0, 3, 4), 0);
        assertEq(fp.mulDivUp(8, 1, 4), 2);
        assertEq(fp.min(1, 2), 1);
        assertEq(fp.min(2, 1), 1);
        assertEq(fp.zeroFloorSub(5, 3), 2);
        assertEq(fp.zeroFloorSub(3, 5), 0);
    }

    function testFuzz_upIsDownOrOneMore(uint256 x, uint256 y, uint256 d) public view {
        x = bound(x, 0, type(uint128).max);
        y = bound(y, 0, type(uint128).max);
        d = bound(d, 1, type(uint256).max);
        uint256 down = fp.mulDivDown(x, y, d);
        uint256 up = fp.mulDivUp(x, y, d);
        assertTrue(up == down || up == down + 1);
        assertEq(up == down, (x * y) % d == 0);
    }
}
