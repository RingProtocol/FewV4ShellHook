// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Aggregator hook discovery interface
/// @notice ABI used by Uniswap-compatible routing services to quote external-liquidity hooks.
interface IAggregatorHook {
    error UnspecifiedAmountExceeded();
    error PoolDoesNotExist();
    error LiquidityNotAllowed();

    event AggregatorPoolRegistered(PoolId indexed poolId);
    event HookSwap(PoolId indexed poolId, address indexed sender, int256 amount0, int256 amount1, uint24 swapFee);

    /// @notice Quotes the unspecified side for an exact-input (negative) or exact-output (positive) request.
    /// @dev Intended for eth_call/callStatic. It is non-view because the implementation simulates a real v4 swap.
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId) external returns (uint256 amountUnspecified);

    /// @notice Returns a liquidity-depth proxy in the outer pool's currency order.
    function pseudoTotalValueLocked(PoolId poolId) external returns (uint256 amount0, uint256 amount1);
}
