// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @dev Test-only beforeSwap hook: direct Quoter swaps pay less than shell swaps.
contract MockSenderFeeHook {
    address public immutable quoter;

    constructor(address quoter_) {
        quoter = quoter_;
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = sender == quoter ? 500 : 100_000;
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
