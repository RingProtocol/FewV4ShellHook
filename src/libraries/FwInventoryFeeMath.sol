// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";

/// @notice Linear fees against the signed, market-value inventory imbalance.
library FwInventoryFeeMath {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant ONE = 1e18;

    struct Config {
        uint24 minFee;
        uint24 baseFee;
        uint24 maxFee;
    }
    error InvalidConfig();
    error InvalidPrice();

    function validate(Config memory c) internal pure {
        if (c.minFee > c.baseFee || c.baseFee > c.maxFee || c.maxFee > 999998) revert InvalidConfig();
    }

    /// @return skew Positive when token1 is abundant, negative when token1 is scarce; 1e18 scale.
    function imbalance(uint160 sqrtPrice, uint256 b0, uint256 b1) internal pure returns (int256 skew) {
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) revert InvalidPrice();
        if (b0 == 0) return b1 == 0 ? int256(0) : int256(ONE);
        if (b1 == 0) return -int256(ONE);
        // Common scaling keeps the largest balance at 224 bits, preserving fractional
        // value for tiny raw balances and leaving room for addition. Always convert
        // the cheaper asset into the more expensive asset's units (ratio <= 1).
        uint256 largest = b0 > b1 ? b0 : b1;
        uint256 bits = uint256(BitMath.mostSignificantBit(largest)) + 1;
        if (bits <= 224) {
            b0 <<= 224 - bits;
            b1 <<= 224 - bits;
        } else {
            b0 >>= bits - 224;
            b1 >>= bits - 224;
        }
        if (sqrtPrice <= Q96) {
            b0 = FullMath.mulDiv(FullMath.mulDiv(b0, sqrtPrice, Q96), sqrtPrice, Q96);
        } else {
            b1 = FullMath.mulDiv(FullMath.mulDiv(b1, Q96, sqrtPrice), Q96, sqrtPrice);
        }
        uint256 total = b0 + b1;
        uint256 diff = b0 > b1 ? b0 - b1 : b1 - b0;
        uint256 magnitude = FullMath.mulDiv(diff, ONE, total);
        skew = b1 >= b0 ? int256(magnitude) : -int256(magnitude);
    }

    function fees(Config memory c, uint160 sqrtPrice, uint256 b0, uint256 b1)
        internal
        pure
        returns (uint24 zeroForOne, uint24 oneForZero, int256 skew)
    {
        validate(c);
        skew = imbalance(sqrtPrice, b0, b1);
        if (b0 == 0 && b1 == 0) return (c.maxFee, c.maxFee, 0);
        uint256 strength = uint256(skew < 0 ? -skew : skew);
        // Ceil final fees: subtract floor(discount), add ceil(premium).
        uint24 low = c.baseFee - uint24(FullMath.mulDiv(strength, c.baseFee - c.minFee, ONE));
        uint24 high = c.baseFee + uint24(FullMath.mulDivRoundingUp(strength, c.maxFee - c.baseFee, ONE));
        return skew >= 0 ? (low, high, skew) : (high, low, skew);
    }
}
