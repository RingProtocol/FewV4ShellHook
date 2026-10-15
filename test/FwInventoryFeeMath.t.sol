// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {FwInventoryFeeMath as M} from "../src/libraries/FwInventoryFeeMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract FwInventoryFeeMathTest is Test {
    uint160 constant Q96 = 79228162514264337593543950336;

    function test_inventoryTable() public pure {
        uint256[6] memory b1 = [uint256(0), 25, 50, 100, 200, 400];
        uint24[6] memory f0Expected = [uint24(3000), 2600, 2334, 2000, 1667, 1400];
        uint24[6] memory f1Expected = [uint24(1000), 1400, 1667, 2000, 2334, 2600];
        for (uint256 i; i < b1.length; ++i) {
            (uint24 f0, uint24 f1,) = M.fees(M.Config(1000, 2000, 3000), Q96, 100, b1[i]);
            assertEq(f0, f0Expected[i]);
            assertEq(f1, f1Expected[i]);
        }
    }

    function test_wethUsdcExampleAndDecimals() public pure {
        (uint24 f0, uint24 f1,) = M.fees(M.Config(1000, 2000, 3000), Q96 * 50, 1, 2000);
        assertEq(f0, 2112);
        assertEq(f1, 1889);
        (f0, f1,) = M.fees(M.Config(1000, 2000, 3000), uint160(uint256(Q96) * 50 / 1e6), 1e18, 2000e6);
        assertEq(f0, 2112);
        assertEq(f1, 1889);
    }

    function test_extremePricesAndBalances() public pure {
        M.fees(M.Config(1000, 2000, 3000), TickMath.MIN_SQRT_PRICE, type(uint256).max, 1);
        M.fees(M.Config(1000, 2000, 3000), TickMath.MAX_SQRT_PRICE - 1, 1, type(uint256).max);
        (uint24 f0, uint24 f1,) = M.fees(M.Config(1000, 2000, 3000), Q96, type(uint256).max, type(uint256).max);
        assertEq(f0, 2000);
        assertEq(f1, 2000);
    }

    function testFuzz_bounds(uint160 p, uint256 b0, uint256 b1) public pure {
        p = uint160(bound(p, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        (uint24 f0, uint24 f1, int256 s) = M.fees(M.Config(1000, 2000, 3000), p, b0, b1);
        assertGe(f0, 1000);
        assertLe(f0, 3000);
        assertGe(f1, 1000);
        assertLe(f1, 3000);
        assertGe(s, -1e18);
        assertLe(s, 1e18);
    }

    function testFuzz_monotonicAndSymmetric(uint128 a, uint128 b, uint128 extra) public pure {
        (uint24 f0, uint24 f1,) = M.fees(M.Config(1000, 2000, 3000), Q96, uint256(a) + 1, uint256(b) + 1);
        (uint24 g0, uint24 g1,) = M.fees(M.Config(1000, 2000, 3000), Q96, uint256(a) + 1, uint256(b) + 1 + extra);
        assertLe(g0, f0);
        assertGe(g1, f1);
        (g0, g1,) = M.fees(M.Config(1000, 2000, 3000), Q96, uint256(b) + 1, uint256(a) + 1);
        assertEq(g0, f1);
        assertEq(g1, f0);
    }

    function testFuzz_independentRationalOracle(uint64 a, uint64 b, uint16 priceRoot, uint24 minFee, uint24 spread)
        public
        pure
    {
        uint256 root = uint256(priceRoot) + 1;
        uint256 v0 = (uint256(a) + 1) * root * root;
        uint256 v1 = uint256(b) + 1;
        minFee = uint24(bound(minFee, 0, 900000));
        spread = uint24(bound(spread, 0, 49000));
        M.Config memory c = M.Config(minFee, minFee + spread, minFee + 2 * spread);
        (uint24 f0, uint24 f1,) = M.fees(c, uint160(uint256(Q96) * root), uint256(a) + 1, uint256(b) + 1);
        uint256 diff = v0 > v1 ? v0 - v1 : v1 - v0;
        uint256 total = v0 + v1;
        uint256 low = c.baseFee - FullMath.mulDiv(diff, spread, total);
        uint256 high = c.baseFee + FullMath.mulDivRoundingUp(diff, spread, total);
        // E18 skew quantization can move the final rounded fee by at most one pip.
        assertApproxEqAbs(f0, v0 > v1 ? high : low, 1);
        assertApproxEqAbs(f1, v0 > v1 ? low : high, 1);
    }

    function test_configAndZeroMatrix() public pure {
        uint24[4] memory bases = [uint24(0), 2000, 3000, 999998];
        for (uint256 i; i < bases.length; ++i) {
            M.Config memory flat = M.Config(bases[i], bases[i], bases[i]);
            (uint24 f0, uint24 f1,) = M.fees(flat, Q96, 0, 100);
            assertEq(f0, bases[i]);
            assertEq(f1, bases[i]);
        }
        (uint24 a, uint24 b,) = M.fees(M.Config(1000, 1800, 3000), Q96, 100, 300);
        assertEq(a, 1400);
        assertEq(b, 2400);
        (a, b,) = M.fees(M.Config(1000, 2000, 3000), Q96, 0, 0);
        assertEq(a, 3000);
        assertEq(b, 3000);
    }
}
