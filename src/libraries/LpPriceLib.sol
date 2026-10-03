// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Price-limit mapping for FewToken LPs.
library LpPriceLib {
    /// @dev Maps a shell-pool sqrtPriceLimitX96 into the lp pool's price space. When the lp pool's
    ///      currency order is reversed relative to shell pool (`!orderAligned`), the price limit is inverted.
    function mapLpPriceLimit(bool orderAligned, bool lpZeroForOne, uint160 shellLimit) internal pure returns (uint160) {
        if (orderAligned) return shellLimit;

        uint256 mapped = lpZeroForOne
            ? FullMath.mulDivRoundingUp(1 << 96, 1 << 96, shellLimit)
            : FullMath.mulDiv(1 << 96, 1 << 96, shellLimit);

        if (lpZeroForOne && mapped <= TickMath.MIN_SQRT_PRICE) mapped = TickMath.MIN_SQRT_PRICE + 1;
        if (!lpZeroForOne && mapped >= TickMath.MAX_SQRT_PRICE) mapped = TickMath.MAX_SQRT_PRICE - 1;
        if (mapped <= TickMath.MIN_SQRT_PRICE || mapped >= TickMath.MAX_SQRT_PRICE) {
            mapped = lpZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        return uint160(mapped);
    }
}
