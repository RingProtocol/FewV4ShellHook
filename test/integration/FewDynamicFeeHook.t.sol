// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {FewV4ShellHookTest} from "./FewV4ShellHook.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FewDynamicFeeHook} from "../../src/FewDynamicFeeHook.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FwInventoryFeeMath as M} from "../../src/libraries/FwInventoryFeeMath.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LpOwner} from "../../src/base/LpOwner.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @dev Inherits existing Shell regressions unchanged; dynamic scenarios install a separate LP.
contract FewDynamicFeeHookTest is FewV4ShellHookTest {
    using PoolIdLibrary for PoolKey;
    FewDynamicFeeHook internal dynamicHook;

    function test_gas_shellRouteFewPoolVersusDynamicFeeFewPool() public {
        // Baseline: shell pool is registered to a regular Few v4 pool.
        manager.initialize(lpKey, SQRT_PRICE_1_1);
        _addLpLiquidity(LP_LIQUIDITY);
        address w0 = Currency.unwrap(lpKey.currency0);
        address w1 = Currency.unwrap(lpKey.currency1);
        deal(address(tokenA), USER, 10e18);
        deal(address(tokenB), USER, 10e18);
        deal(IFewWrappedToken(w0).token(), w0, 100e18);
        deal(IFewWrappedToken(w1).token(), w1, 100e18);
        _addCurLiquidity(1e18);

        uint256 snapshot = vm.snapshotState();
        uint256 regularFewGas = _measureSwap(shellKey, true, -int256(1e18));
        assertTrue(vm.revertToState(snapshot));

        // Reconfigure the same shell route to an otherwise equivalent Few v4 pool
        // that runs the dynamic-fee hook, then measure through the same shell entry.
        _install();
        deal(IFewWrappedToken(w0).token(), w0, 100e18);
        deal(IFewWrappedToken(w1).token(), w1, 100e18);
        _addCurLiquidity(1e18);
        uint256 dynamicFewGas = _measureSwap(shellKey, true, -int256(1e18));
        assertTrue(vm.revertToState(snapshot));

        emit log_named_uint("Shell -> regular Few v4 pool gas", regularFewGas);
        emit log_named_uint("Shell -> FewDynamicFeeHook Few v4 pool gas", dynamicFewGas);
        emit log_named_uint(
            "Dynamic fee route additional gas", dynamicFewGas > regularFewGas ? dynamicFewGas - regularFewGas : 0
        );
    }

    function _measureSwap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256 gasUsed)
    {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(USER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            bytes("")
        );
        gasUsed = vm.lastCallGas().gasTotalUsed;
    }

    function _install() internal {
        bytes memory args = abi.encode(manager, IFewFactory(address(factory)), address(this));
        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
            type(FewDynamicFeeHook).creationCode,
            args
        );
        dynamicHook = new FewDynamicFeeHook{salt: salt}(manager, IFewFactory(address(factory)), address(this));
        lpKey.hooks = IHooks(address(dynamicHook));
        lpKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        dynamicHook.configurePool(lpKey, M.Config(1000, 2000, 3000));
        hook.setLpPool(shellKey, lpKey);
        manager.initialize(lpKey, SQRT_PRICE_1_1);
        _addLpLiquidity(LP_LIQUIDITY);
    }

    function test_dynamic_liveZeroAndBalanced() public {
        _install();
        address w0 = Currency.unwrap(lpKey.currency0);
        address w1 = Currency.unwrap(lpKey.currency1);
        address u0 = IFewWrappedToken(w0).token();
        address u1 = IFewWrappedToken(w1).token();
        deal(u0, w0, 100e18);
        deal(u1, w1, 100e18);
        (uint24 f0, uint24 f1) = dynamicHook.getFee(lpKey);
        assertEq(f0, 2000);
        assertEq(f1, 2000);
        deal(u1, w1, 0);
        (f0, f1) = dynamicHook.getFee(lpKey);
        assertEq(f0, 3000);
        assertEq(f1, 1000);
        // Same block: no cached fee.
        deal(u0, w0, 0);
        deal(u1, w1, 100e18);
        (f0, f1) = dynamicHook.getFee(lpKey);
        assertEq(f0, 1000);
        assertEq(f1, 3000);
        deal(u1, w1, 0);
        (f0, f1) = dynamicHook.getFee(lpKey);
        assertEq(f0, 3000);
        assertEq(f1, 3000);
    }

    function test_dynamic_amountMatrix() public {
        _install();
        uint256[5] memory amounts = [uint256(1000), 1e12, 1e15, 1e17, 1e18];
        uint256[3] memory inventory1 = [uint256(50e18), 100e18, 200e18];
        address w0 = Currency.unwrap(lpKey.currency0);
        address w1 = Currency.unwrap(lpKey.currency1);
        for (uint256 r; r < inventory1.length; ++r) {
            deal(IFewWrappedToken(w0).token(), w0, 100e18);
            deal(IFewWrappedToken(w1).token(), w1, inventory1[r]);
            for (uint256 i; i < amounts.length; ++i) {
                for (uint256 d; d < 2; ++d) {
                    for (uint256 exact; exact < 2; ++exact) {
                        uint256 snapshot = vm.snapshotState();
                        bool direction = d == 0;
                        int256 specified = exact == 0 ? -int256(amounts[i]) : int256(amounts[i]);
                        uint256 quote = hook.quote(direction, specified, shellKey.toId());
                        BalanceDelta delta = _swapAsUser(direction, specified);
                        int128 input = direction ? delta.amount0() : delta.amount1();
                        int128 output = direction ? delta.amount1() : delta.amount0();
                        assertEq(exact == 0 ? uint256(uint128(output)) : uint256(-int256(input)), quote);
                        assertEq(exact == 0 ? uint256(-int256(input)) : uint256(uint128(output)), amounts[i]);
                        vm.revertToState(snapshot);
                    }
                }
            }
        }
    }

    function test_dynamic_feeOverrideAllAmountsAndCallers() public {
        _install();
        address w0 = Currency.unwrap(lpKey.currency0);
        address w1 = Currency.unwrap(lpKey.currency1);
        deal(IFewWrappedToken(w0).token(), w0, 100e18);
        deal(IFewWrappedToken(w1).token(), w1, 50e18);
        int256[6] memory sizes = [int256(-1), -1e6, -1e18, int256(1), 1e6, 1e18];
        for (uint256 i; i < sizes.length; ++i) {
            for (uint256 d; d < 2; ++d) {
                for (uint256 caller; caller < 2; ++caller) {
                    vm.prank(address(manager));
                    (, BeforeSwapDelta delta, uint24 fee) = dynamicHook.beforeSwap(
                        caller == 0 ? address(hook) : USER,
                        lpKey,
                        SwapParams(d == 0, sizes[i], SQRT_PRICE_1_1),
                        bytes("")
                    );
                    assertEq(BeforeSwapDelta.unwrap(delta), 0);
                    assertEq(fee, (d == 0 ? uint24(2334) : uint24(1667)) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
                }
            }
        }
    }

    function test_dynamic_adminValidation() public {
        _install();
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(LpOwner.NotOwner.selector, USER, address(this)));
        dynamicHook.configurePool(lpKey, M.Config(1000, 2000, 3000));
        vm.expectRevert(M.InvalidConfig.selector);
        dynamicHook.configurePool(lpKey, M.Config(3000, 2000, 1000));
        vm.expectRevert(M.InvalidConfig.selector);
        dynamicHook.configurePool(lpKey, M.Config(0, 2000, 999999));
        PoolKey memory bad = lpKey;
        bad.fee = 3000;
        vm.expectRevert(FewDynamicFeeHook.InvalidPool.selector);
        dynamicHook.configurePool(bad, M.Config(1000, 2000, 3000));
        dynamicHook.configurePool(lpKey, M.Config(500, 500, 500));
        (uint24 f0, uint24 f1) = dynamicHook.getFee(lpKey);
        assertEq(f0, 500);
        assertEq(f1, 500);
        vm.expectRevert();
        dynamicHook.beforeSwap(USER, lpKey, SwapParams(true, -1, SQRT_PRICE_1_1), bytes(""));
    }

    function test_dynamic_zeroInventoryRecoveryAndRollback() public {
        _install();
        address w0 = Currency.unwrap(lpKey.currency0);
        address w1 = Currency.unwrap(lpKey.currency1);
        address u0 = IFewWrappedToken(w0).token();
        address u1 = IFewWrappedToken(w1).token();
        deal(u0, w0, 100e18);
        deal(u1, w1, 0);
        // Shell direction mapping: supply LP token1, withdraw LP token0.
        bool supplyToken1 = !orderAligned;
        uint256 before0 = MockERC20(u0).balanceOf(w0);
        BalanceDelta delta = _swapAsUser(supplyToken1, -int256(1e18));
        uint256 out = uint256(uint128(supplyToken1 ? delta.amount1() : delta.amount0()));
        assertEq(MockERC20(u0).balanceOf(w0), before0 - out);
        assertEq(MockERC20(u1).balanceOf(w1), 1e18);
        (uint24 f0, uint24 f1) = dynamicHook.getFee(lpKey);
        assertGt(f1, 1000);
        assertLt(f0, 3000);
        deal(u1, w1, 0);
        uint256 snapshot = vm.snapshotState();
        vm.expectRevert();
        _swapAsUser(!supplyToken1, -int256(1e18));
        assertEq(MockERC20(u1).balanceOf(w1), 0);
        assertEq(MockERC20(u0).balanceOf(w0), before0 - out);
        vm.revertToState(snapshot);
    }
}
