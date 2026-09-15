// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Price-limit mapping and marginal amount estimation for lp pools.
library LpPriceLib {
    using StateLibrary for IPoolManager;

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

    /// @dev Returns the marginal (minimum) amountIn needed for an exact-output swap of `amountOut`
    ///      on the lp pool, using its current sqrtPriceX96. Lower bound — actual amountIn is >= this.
    function estimateLpAmountIn(IPoolManager pm, PoolId lpPoolId, bool lpZeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(lpPoolId);
        if (sqrtPriceX96 == 0) return type(uint256).max;

        if (lpZeroForOne) {
            return FullMath.mulDiv(FullMath.mulDiv(amountOut, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
        } else {
            return FullMath.mulDiv(FullMath.mulDiv(amountOut, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
        }
    }
}
