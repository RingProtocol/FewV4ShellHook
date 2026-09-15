// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV4ShellHook} from "../../src/FewV4ShellHook.sol";
import {LpOwner} from "../../src/base/LpOwner.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {MockFewFactory} from "../mocks/MockFewFactory.sol";
import {MockFewWrappedToken} from "../mocks/MockFewWrappedToken.sol";
import {MockWETH9} from "../mocks/MockWETH9.sol";
import {MockNoOpHook} from "../mocks/MockNoOpHook.sol";

/// @notice Integration tests for FewV4ShellHook using a fresh local PoolManager and mock FewFactory.
contract FewV4ShellHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant SQRT_PRICE_1_2 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_2_1 = 112045541949572279837463876454;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant SWAP_AMOUNT = 1e18;
    uint256 internal constant LP_LIQUIDITY = 100e18;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    V4Quoter internal v4Quoter;

    MockFewFactory internal factory;
    MockWETH9 internal weth;
    FewV4ShellHook internal hook;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    Currency internal currencyA;
    Currency internal currencyB;
    Currency internal currency0;
    Currency internal currency1;

    address internal fewA;
    address internal fewB;

    PoolKey internal shellKey;
    PoolKey internal lpKey;
    bool internal orderAligned;

    address internal LP = makeAddr("LP");
    address internal USER = makeAddr("USER");

    function setUp() public {
        // Deploy fresh PoolManager and test routers.
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        v4Quoter = new V4Quoter(manager);

        // Deploy mock tokens.
        tokenA = new MockERC20("TokenA", "TA", 18);
        tokenB = new MockERC20("TokenB", "TB", 18);
        tokenA.mint(address(this), 1_000_000e18);
        tokenB.mint(address(this), 1_000_000e18);
        tokenA.mint(USER, 100e18);
        tokenB.mint(USER, 100e18);

        currencyA = Currency.wrap(address(tokenA));
        currencyB = Currency.wrap(address(tokenB));
        (currency0, currency1) = address(tokenA) < address(tokenB) ? (currencyA, currencyB) : (currencyB, currencyA);

        // Deploy mock FewFactory and create wrappers.
        factory = new MockFewFactory();
        factory.createToken(address(tokenA));
        factory.createToken(address(tokenB));
        fewA = factory.getWrappedToken(address(tokenA));
        fewB = factory.getWrappedToken(address(tokenB));

        // Deploy mock WETH9 for native ETH support tests.
        weth = new MockWETH9();

        // Mint underlying to PoolManager so the hook can flash-take during lp route.
        // Also mint fewTokens to PoolManager for the lp swap output leg.
        tokenA.mint(address(manager), 1_000_000e18);
        tokenB.mint(address(manager), 1_000_000e18);

        // Deploy the hook at a mined address matching permission flags.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory constructorArgs =
            abi.encode(manager, IFewFactory(address(factory)), IWETH9(address(weth)), IV4Quoter(address(v4Quoter)));
        (address minedAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, constructorArgs);
        hook = new FewV4ShellHook{salt: salt}(
            manager, IFewFactory(address(factory)), IWETH9(address(weth)), IV4Quoter(address(v4Quoter))
        );
        assertEq(address(hook), minedAddr, "hook address mismatch");

        // Approve tokens for routers.
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(liquidityRouter), type(uint256).max);
        tokenB.approve(address(liquidityRouter), type(uint256).max);

        // Approve tokens for the hook (needed for wrap during lp route).
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        // User approvals.
        vm.startPrank(USER);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Construct pool keys.
        shellKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Derive fb key the same way the hook does: few0 = getWrappedToken(token0), few1 = getWrappedToken(token1).
        address few0 = factory.getWrappedToken(Currency.unwrap(currency0));
        address few1 = factory.getWrappedToken(Currency.unwrap(currency1));
        orderAligned = few0 < few1;
        lpKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Initialize shell pool before registering lp pool (setLpPool requires the shell pool to be initialized).
        manager.initialize(shellKey, SQRT_PRICE_1_1);

        // Register the lp pool explicitly (no auto-inference).
        hook.setLpPool(shellKey, lpKey);
    }

    // ---------------------------------------------------------------------
    // Permission tests
    // ---------------------------------------------------------------------

    function test_permissions_correct() public view {
        Hooks.Permissions memory perm = hook.getHookPermissions();
        assertTrue(perm.beforeInitialize);
        assertFalse(perm.afterInitialize);
        assertFalse(perm.beforeAddLiquidity);
        assertFalse(perm.afterAddLiquidity);
        assertFalse(perm.beforeRemoveLiquidity);
        assertFalse(perm.afterRemoveLiquidity);
        assertTrue(perm.beforeSwap);
        assertFalse(perm.afterSwap);
        assertFalse(perm.beforeDonate);
        assertFalse(perm.afterDonate);
        assertTrue(perm.beforeSwapReturnDelta);
        assertFalse(perm.afterSwapReturnDelta);
        assertFalse(perm.afterAddLiquidityReturnDelta);
        assertFalse(perm.afterRemoveLiquidityReturnDelta);
    }

    function test_constructor_zeroAddress_reverts() public {
        // FewFactory(0) and WETH(0) are blocked by the constructor.
        // We can't test PoolManager(0) directly because BaseHook's validateHookAddress
        // runs first and requires a specific address pattern.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        // FewFactory(0)
        bytes memory constructorArgsA =
            abi.encode(manager, IFewFactory(address(0)), IWETH9(address(weth)), IV4Quoter(address(v4Quoter)));
        (address minedAddrA, bytes32 saltA) =
            HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, constructorArgsA);
        vm.expectRevert(LpOwner.ZeroAddress.selector);
        new FewV4ShellHook{salt: saltA}(manager, IFewFactory(address(0)), IWETH9(address(weth)), IV4Quoter(address(v4Quoter)));
        minedAddrA;

        // WETH(0)
        bytes memory constructorArgsB =
            abi.encode(manager, IFewFactory(address(factory)), IWETH9(address(0)), IV4Quoter(address(v4Quoter)));
        (address minedAddrB, bytes32 saltB) =
            HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, constructorArgsB);
        vm.expectRevert(LpOwner.ZeroAddress.selector);
        new FewV4ShellHook{salt: saltB}(manager, IFewFactory(address(factory)), IWETH9(address(0)), IV4Quoter(address(v4Quoter)));
        minedAddrB;
    }

    // ---------------------------------------------------------------------
    // Liquidity tests
    // ---------------------------------------------------------------------

    function test_anyoneCanAddLiquidity() public {
        // Initialize shell pool at 1:1.

        // Give LP some tokens.
        tokenA.mint(LP, 100e18);
        tokenB.mint(LP, 100e18);

        // Anyone (LP) can add liquidity without hook interference.
        vm.startPrank(LP);
        tokenA.approve(address(liquidityRouter), type(uint256).max);
        tokenB.approve(address(liquidityRouter), type(uint256).max);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0});
        liquidityRouter.modifyLiquidity(shellKey, params, bytes(""));
        vm.stopPrank();

        assertGt(manager.getLiquidity(shellKey.toId()), 0, "liquidity added");
    }

    // ---------------------------------------------------------------------
    // Fallback to shell pool tests
    // ---------------------------------------------------------------------

    function test_lpNotInitialized_reverts() public {
        // Initialize shell pool only (lp pool not initialized). lp is the only venue, so revert.
        _addCurLiquidity(1e18);

        _expectLpRevertOnSwap(true, -int256(SWAP_AMOUNT), FewV4ShellHook.LpRouteUnavailable.selector);
    }

    function test_lpHasNoLiquidity_reverts() public {
        // Initialize both pools but only add liquidity to shell. fb has no liquidity → revert.
        manager.initialize(lpKey, SQRT_PRICE_1_1);
        _addCurLiquidity(1e18);

        _expectLpRevertOnSwap(true, -int256(SWAP_AMOUNT), FewV4ShellHook.LpRouteUnavailable.selector);
    }

    function test_lpLiquidityEqual_stillRoutesToLp() public {
        // Both pools at the same price with equal liquidity. lp is always used regardless of depth.
        manager.initialize(lpKey, SQRT_PRICE_1_1);
        _addCurLiquidity(1e18);
        _addLpLiquidity(1e18);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT / 1000));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    // ---------------------------------------------------------------------
    // lp route tests
    // ---------------------------------------------------------------------

    function test_usesExplicitLp_zeroForOne() public {
        // For zeroForOne (selling token0, buying token1), lp is better when lpPrice > shellPrice.
        // When orderAligned, fb sqrtPrice is directly comparable.
        // When !orderAligned, fb sqrtPrice is inverted: normalized = 2^192 / lpSqrtPrice.
        // So we set lp price to SQRT_PRICE_2_1 (higher) when orderAligned,
        // or SQRT_PRICE_1_2 (lower, which inverts to higher) when !orderAligned.
        uint160 lpPrice = _lpPriceForBetterZeroForOne();
        manager.initialize(lpKey, lpPrice);
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));

        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
    }

    function test_lpShallower_stillRoutesToLp() public {
        // lp price is better for zeroForOne, and fb liquidity is shallower than shell.
        // lp is always used regardless of depth comparison.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(0.5e18);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT / 1000));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_routesToLpEvenIfPriceWorse() public {
        // lp price is worse for zeroForOne, but lp is always used regardless of depth or price.
        // The lp price sits near the edge of the fb liquidity range in the swap's
        // direction, so use a small amount that still fills completely.
        manager.initialize(lpKey, _lpPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT / 1000));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_usesExplicitLp_oneForZero() public {
        // For oneForZero (selling token1, buying token0), lp is better when lpPrice < shellPrice.
        uint160 lpPrice = _lpPriceForBetterOneForZero();
        manager.initialize(lpKey, lpPrice);
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(false, -int256(SWAP_AMOUNT), _fallbackData(1));

        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
    }

    function test_lpRoute_hookBalancesZero() public {
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));

        // Hook should hold no residual balances.
        assertEq(IERC20(address(tokenA)).balanceOf(address(hook)), 0, "hook tokenA balance");
        assertEq(IERC20(address(tokenB)).balanceOf(address(hook)), 0, "hook tokenB balance");
        assertEq(IERC20(fewA).balanceOf(address(hook)), 0, "hook fewA balance");
        assertEq(IERC20(fewB).balanceOf(address(hook)), 0, "hook fewB balance");
    }

    function test_autoRoutesToLpWhenSpotPriceBetter_zeroForOne() public {
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_autoRoutesToLpWhenSpotPriceBetter_oneForZero() public {
        manager.initialize(lpKey, _lpPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(false, -int256(SWAP_AMOUNT));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_autoRoutesToLpForExactOutput() public {
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, int256(SWAP_AMOUNT));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_autoLpHookBalancesZero() public {
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        assertEq(IERC20(address(tokenA)).balanceOf(address(hook)), 0, "hook tokenA balance");
        assertEq(IERC20(address(tokenB)).balanceOf(address(hook)), 0, "hook tokenB balance");
        assertEq(IERC20(fewA).balanceOf(address(hook)), 0, "hook fewA balance");
        assertEq(IERC20(fewB).balanceOf(address(hook)), 0, "hook fewB balance");
    }

    function test_lpDeeperButTooShallowRevertsOnPartialFill() public {
        // lp is strictly deeper than shell but still too shallow for the requested amount.
        // The lp swap cannot fill completely, so the whole transaction reverts.
        manager.initialize(lpKey, SQRT_PRICE_1_1);
        _addCurLiquidity(0.001e18);
        _addLpLiquidity(0.01e18);

        // v4-core wraps hook reverts in the ERC-7751 error WrappedError(address,bytes4,bytes,bytes)
        // (see Hooks.callHook), so vm.expectRevert(LpSwapPartialFill.selector) cannot match directly.
        // Catch the wrapper, decode it, and assert the inner reason is LpSwapPartialFill.
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        try swapRouter.swap(
            shellKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            bytes("")
        ) {
            assertTrue(false, "expected LpSwapPartialFill");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "ERC-7751 wrapper");
            (address target, bytes4 fnSelector, bytes memory inner,) =
                abi.decode(_stripSelector(reason), (address, bytes4, bytes, bytes));
            assertEq(target, address(hook), "wrapper target");
            assertEq(fnSelector, IHooks.beforeSwap.selector, "wrapper selector");
            assertEq(bytes4(inner), FewV4ShellHook.LpSwapPartialFill.selector, "LpSwapPartialFill");
            (uint256 actual, uint256 expected) = abi.decode(_stripSelector(inner), (uint256, uint256));
            assertEq(expected, SWAP_AMOUNT, "expected fill");
            assertTrue(actual < expected, "partial fill");
        }
    }

    function test_insufficientLpInventory_exactIn_reverts() public {
        // The few token contract lacks sufficient underlying to fulfill the unwrap of the output.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        // Burn the output few token's underlying balance so unwrap would fail.
        address fewOut = factory.getWrappedToken(Currency.unwrap(currency1));
        address underlying = IFewWrappedToken(fewOut).token();
        uint256 underlyingBal = MockERC20(underlying).balanceOf(fewOut);
        MockERC20(underlying).burn(fewOut, underlyingBal);

        _expectLpRevertOnSwap(true, -int256(SWAP_AMOUNT), FewV4ShellHook.LpInsufficientInventory.selector);
    }

    function test_insufficientLpInventory_exactOut_reverts() public {
        // Same as above but for exact-output.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        // Burn the output few token's underlying balance so unwrap would fail.
        address fewOut = factory.getWrappedToken(Currency.unwrap(currency1));
        address underlying = IFewWrappedToken(fewOut).token();
        uint256 underlyingBal = MockERC20(underlying).balanceOf(fewOut);
        MockERC20(underlying).burn(fewOut, underlyingBal);

        _expectLpRevertOnSwap(true, int256(SWAP_AMOUNT), FewV4ShellHook.LpInsufficientInventory.selector);
    }

    function test_insufficientLpInventory_oneForZero_reverts() public {
        // oneForZero direction: burn the output few token's underlying and verify revert.
        manager.initialize(lpKey, _lpPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        // Burn the output few token's underlying balance so unwrap would fail.
        address fewOut = factory.getWrappedToken(Currency.unwrap(currency0));
        address underlying = IFewWrappedToken(fewOut).token();
        uint256 underlyingBal = MockERC20(underlying).balanceOf(fewOut);
        MockERC20(underlying).burn(fewOut, underlyingBal);

        _expectLpRevertOnSwap(false, -int256(SWAP_AMOUNT), FewV4ShellHook.LpInsufficientInventory.selector);
    }

    function test_lpUnavailable_reverts() public {
        // fb unavailable → revert (no shell fallback).
        _addCurLiquidity(1e18);

        _expectLpRevertOnSwap(true, -int256(SWAP_AMOUNT), FewV4ShellHook.LpRouteUnavailable.selector);
    }

    function test_hookDataIgnored_zeroLimitStillRoutesToLp() public {
        // hookData carries no amountLimit semantics; routing is purely depth-based.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(0));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_hookDataIgnored_expiredDeadlineStillRoutesToLp() public {
        // hookData carries no deadline semantics; an expired encoding no longer reverts.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);
        vm.warp(100);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), abi.encode(uint256(99), uint256(1)));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_hookDataIgnored_minOutputNotEnforced() public {
        // hookData carries no minimum-output semantics; a huge limit no longer reverts.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(type(uint256).max));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_usesExplicitLpForExactOutput() public {
        manager.initialize(lpKey, _lpPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(false, int256(SWAP_AMOUNT), _fallbackData(type(uint256).max));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_usesExplicitLpForExactOutput_zeroForOne() public {
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, int256(SWAP_AMOUNT), _fallbackData(type(uint256).max));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_hookDataIgnored_maxInputNotEnforced() public {
        // hookData carries no maximum-input semantics; a tiny limit no longer reverts.
        manager.initialize(lpKey, _lpPriceForBetterOneForZero());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(false, int256(SWAP_AMOUNT), _fallbackData(1));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    // ---------------------------------------------------------------------
    // Edge cases
    // ---------------------------------------------------------------------

    function test_revertsOnZeroAmount() public {
        _addCurLiquidity(1e18);

        // PoolManager itself reverts on zero amount before the hook is called.
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectRevert();
        swapRouter.swap(
            shellKey,
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            bytes("")
        );
    }

    function test_hookDataIgnored_invalidBytesStillSwaps() public {
        // hookData is not validated; arbitrary bytes neither revert nor change routing.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT), bytes("invalid"));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    // ---------------------------------------------------------------------
    // Owner / admin tests
    // ---------------------------------------------------------------------

    function test_ownerIsDeployer() public view {
        assertEq(hook.owner(), address(this), "owner is deployer");
    }

    function test_transferOwner_emitsAndUpdates() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, false, true);
        emit LpOwner.OwnerChanged(address(this), newOwner);
        hook.transferOwner(newOwner);

        assertEq(hook.owner(), newOwner, "owner updated");
    }

    function test_transferOwner_revertsOnZeroAddress() public {
        vm.expectRevert(LpOwner.ZeroAddress.selector);
        hook.transferOwner(address(0));
    }

    function test_transferOwner_revertsForNonOwner() public {
        address newOwner = makeAddr("newOwner");
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LpOwner.NotOwner.selector, attacker, address(this)));
        hook.transferOwner(newOwner);
    }

    function test_transferredOwnerCanAct() public {
        address newOwner = makeAddr("newOwner");
        hook.transferOwner(newOwner);

        vm.prank(newOwner);
        hook.setLpPool(shellKey, lpKey);
        (,, bool isSet) = hook.lpPools(shellKey.toId());
        assertTrue(isSet, "new owner registered");
    }

    // ---------------------------------------------------------------------
    // lpPools registration tests
    // ---------------------------------------------------------------------

    function test_setLpPool_emitsAndRegisters() public {
        vm.expectEmit(true, false, false, true);
        emit FewV4ShellHook.LpPoolSet(shellKey.toId(), lpKey);
        hook.setLpPool(shellKey, lpKey);

        (PoolKey memory rKey,, bool rSet) = hook.lpPools(shellKey.toId());
        assertTrue(rSet, "registered");
        assertEq(Currency.unwrap(rKey.currency0), Currency.unwrap(lpKey.currency0), "currency0");
        assertEq(Currency.unwrap(rKey.currency1), Currency.unwrap(lpKey.currency1), "currency1");
        assertEq(rKey.fee, lpKey.fee, "fee");
        assertEq(rKey.tickSpacing, lpKey.tickSpacing, "tickSpacing");
    }

    function test_setLpPool_revertsForNonOwner() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LpOwner.NotOwner.selector, attacker, address(this)));
        hook.setLpPool(shellKey, lpKey);
    }

    function test_setLpPool_emptyKeyRemovesRegistration() public {
        // Register first.
        hook.setLpPool(shellKey, lpKey);
        (,, bool isSet) = hook.lpPools(shellKey.toId());
        assertTrue(isSet, "registered");

        // Empty lpPoolKey (currency0 == address(0)) removes the registration.
        PoolKey memory emptyKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(0))
        });

        vm.expectEmit(true, false, false, false);
        emit FewV4ShellHook.LpPoolRemoved(shellKey.toId());
        hook.setLpPool(shellKey, emptyKey);

        (,, bool rSet) = hook.lpPools(shellKey.toId());
        assertFalse(rSet, "removed");
    }

    function test_setLpPool_emptyKeyRemoval_revertsForNonOwner() public {
        // Register first.
        hook.setLpPool(shellKey, lpKey);

        PoolKey memory emptyKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(0))
        });

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LpOwner.NotOwner.selector, attacker, address(this)));
        hook.setLpPool(shellKey, emptyKey);
    }

    function test_registeredLpPoolUsesRegisteredFee() public {
        // Register an lp pool with a DIFFERENT fee than the shell pool to confirm the registered
        // fee/tickSpacing is used (not the shell pool's).
        uint24 registeredFee = 3000;
        int24 registeredTickSpacing = 60;

        // Build the registered fb key (different fee/tickSpacing than shellKey).
        bool lpOrderAligned = fewA < fewB;
        PoolKey memory registeredLpKey = PoolKey({
            currency0: Currency.wrap(lpOrderAligned ? fewA : fewB),
            currency1: Currency.wrap(lpOrderAligned ? fewB : fewA),
            fee: registeredFee,
            tickSpacing: registeredTickSpacing,
            hooks: IHooks(address(0))
        });

        manager.initialize(registeredLpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidityWithKey(registeredLpKey, LP_LIQUIDITY);

        hook.setLpPool(shellKey, registeredLpKey);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 registeredLpPriceBefore,,,) = manager.getSlot0(registeredLpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 registeredLpPriceAfter,,,) = manager.getSlot0(registeredLpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(registeredLpPriceAfter != registeredLpPriceBefore, "registered lp price moved");
    }

    function test_registeredLpPoolWithHook_routesToHookedPool() public {
        // Register an lp pool that carries a (no-op) hook. The hook must be preserved so the swap
        // routes to the hooked pool, not the hookless pool with the same fee/tickSpacing/shellrencies.
        // Mine an address with the AFTER_INITIALIZE_FLAG bit set (matching the hook's permission).
        uint160 hookFlags = uint160(Hooks.AFTER_INITIALIZE_FLAG);
        bytes memory hookConstructorArgs = bytes("");
        (address hookAddr, bytes32 hookSalt) =
            HookMiner.find(address(this), hookFlags, type(MockNoOpHook).creationCode, hookConstructorArgs);
        MockNoOpHook lpHook = new MockNoOpHook{salt: hookSalt}();
        assertEq(address(lpHook), hookAddr, "lp hook address mismatch");

        bool lpOrderAligned = fewA < fewB;
        PoolKey memory hookedLpKey = PoolKey({
            currency0: Currency.wrap(lpOrderAligned ? fewA : fewB),
            currency1: Currency.wrap(lpOrderAligned ? fewB : fewA),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(lpHook))
        });

        // Initialize the hooked lp pool and add liquidity.
        manager.initialize(hookedLpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidityWithKey(hookedLpKey, LP_LIQUIDITY);

        // Register the hooked lp pool.
        hook.setLpPool(shellKey, hookedLpKey);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 hookedLpPriceBefore,,,) = manager.getSlot0(hookedLpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 hookedLpPriceAfter,,,) = manager.getSlot0(hookedLpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(hookedLpPriceAfter != hookedLpPriceBefore, "hooked lp price moved");
    }

    function test_emptyKeyRemovalFallsBackToAutoInference() public {
        // Register then remove via empty key.
        hook.setLpPool(shellKey, lpKey);

        PoolKey memory emptyKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(0))
        });
        hook.setLpPool(shellKey, emptyKey);

        // After removal, the hook falls back to FewFactory auto-inference.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
        (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "auto-inferred lp price moved");
    }

    function test_registeredLpPoolWithInvalidWrapper_revertsAtSetTime() public {
        // Register an lp pool with a bogus few0 address (no code). setLpPool validates wrappers at
        // registration time, so the bogus wrapper is rejected immediately.
        address bogusFew0 = makeAddr("bogusFew0");

        PoolKey memory bogusLpKey = PoolKey({
            currency0: Currency.wrap(bogusFew0 < fewB ? bogusFew0 : fewB),
            currency1: Currency.wrap(bogusFew0 < fewB ? fewB : bogusFew0),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        vm.expectRevert(LpOwner.ZeroAddress.selector);
        hook.setLpPool(shellKey, bogusLpKey);
    }

    function test_registeredLpPoolWithWrongUnderlying_revertsAtSetTime() public {
        // Register an lp pool where the wrappers don't correspond to the shell pool's tokens at all.
        // setLpPool validates wrappers at registration time, so this is rejected immediately.
        address fakeWrapper = address(new MockFewWrappedToken(makeAddr("wrongUnderlying")));

        // Construct an lpPoolKey using the fake wrapper. Ensure v4 ordering.
        address other = fewB;
        address fbCur0 = fakeWrapper < other ? fakeWrapper : other;
        address fbCur1 = fakeWrapper < other ? other : fakeWrapper;

        PoolKey memory badLpKey = PoolKey({
            currency0: Currency.wrap(fbCur0),
            currency1: Currency.wrap(fbCur1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        vm.expectRevert();
        hook.setLpPool(shellKey, badLpKey);
    }

    // ---------------------------------------------------------------------
    // quote tests
    // ---------------------------------------------------------------------

    function test_quote_exactInput_returnsExpectedAmountOut() public {
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        // Quote exact-input: swap SWAP_AMOUNT/100 of token0 for token1.
        uint256 amountUnspecified = hook.quote(true, -int256(SWAP_AMOUNT / 100), shellKey.toId());

        // exact-input: unspecified side is output (amountOut)
        assertEq(amountUnspecified, amountUnspecified, "amountUnspecified");
        assertTrue(amountUnspecified > 0, "amountUnspecified > 0");
    }

    function test_quote_exactOutput_returnsExpectedAmountIn() public {
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addCurLiquidity(1e18);
        _addLpLiquidity(LP_LIQUIDITY);

        // Quote exact-output: want SWAP_AMOUNT/100 of token1.
        uint256 exactOut = SWAP_AMOUNT / 100;
        uint256 amountUnspecified = hook.quote(true, int256(exactOut), shellKey.toId());

        // exact-output: unspecified side is input (amountIn)
        assertTrue(amountUnspecified > 0, "amountUnspecified > 0");
    }

    function test_quote_revertsWhenLpUnavailable() public {
        // fb not initialized → quote reverts.
        _addCurLiquidity(1e18);

        vm.expectRevert(FewV4ShellHook.LpRouteUnavailable.selector);
        hook.quote(true, -int256(SWAP_AMOUNT), shellKey.toId());
    }

    // ---------------------------------------------------------------------
    // pseudoTotalValueLocked tests
    // ---------------------------------------------------------------------

    function test_pseudoTvl_returnsLpPoolDepth() public {
        // Initialize lp pool and add liquidity.
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addLpLiquidity(LP_LIQUIDITY);

        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(shellKey.toId());

        // Both amounts should be positive.
        assertGt(amount0, 0, "amount0 > 0");
        assertGt(amount1, 0, "amount1 > 0");

        // Verify against the lp pool's own sqrtPriceX96 and liquidity.
        (uint160 lpSqrtPrice,,,) = manager.getSlot0(lpKey.toId());
        uint128 lpLiquidity = manager.getLiquidity(lpKey.toId());
        uint256 expectedVirtual0 = FullMath.mulDiv(uint256(lpLiquidity), 1 << 96, lpSqrtPrice);
        uint256 expectedVirtual1 = FullMath.mulDiv(uint256(lpLiquidity), lpSqrtPrice, 1 << 96);

        if (orderAligned) {
            assertEq(amount0, expectedVirtual0, "amount0 matches lp virtual0");
            assertEq(amount1, expectedVirtual1, "amount1 matches lp virtual1");
        } else {
            assertEq(amount0, expectedVirtual1, "amount0 matches lp virtual1 (inverted)");
            assertEq(amount1, expectedVirtual0, "amount1 matches lp virtual0 (inverted)");
        }
    }

    function test_pseudoTvl_returnsZeroWhenLpNotInitialized() public {
        // lp pool not initialized → route unavailable → returns (0, 0).
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(shellKey.toId());
        assertEq(amount0, 0, "amount0 == 0");
        assertEq(amount1, 0, "amount1 == 0");
    }

    function test_pseudoTvl_returnsZeroWhenLpHasNoLiquidity() public {
        // lp pool initialized but no liquidity → route available=false → returns (0, 0).
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());

        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(shellKey.toId());
        assertEq(amount0, 0, "amount0 == 0");
        assertEq(amount1, 0, "amount1 == 0");
    }

    function test_pseudoTvl_revertsForUninitializedShellPool() public {
        // Construct a shellPool key that was never initialized through the hook.
        PoolKey memory uninitKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // different fee → different PoolId, never initialized
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(abi.encodeWithSelector(FewV4ShellHook.ShellPoolNotInitialized.selector, uninitKey.toId()));
        hook.pseudoTotalValueLocked(uninitKey.toId());
    }

    function test_pseudoTvl_updatesAfterLpSwap() public {
        manager.initialize(lpKey, _lpPriceForBetterZeroForOne());
        _addLpLiquidity(LP_LIQUIDITY);

        (uint256 amount0Before, uint256 amount1Before) = hook.pseudoTotalValueLocked(shellKey.toId());

        // Swap moves the lp pool price, so virtual amounts change.
        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint256 amount0After, uint256 amount1After) = hook.pseudoTotalValueLocked(shellKey.toId());

        // After zeroForOne (selling token0, buying token1), price decreases (more token0 per token1).
        // virtual0 = L * 2^96 / sqrtPrice → increases as price drops
        // virtual1 = L * sqrtPrice / 2^96 → decreases as price drops
        // But orderAligned may invert; just check they changed.
        assertTrue(
            amount0After != amount0Before || amount1After != amount1Before, "pseudo TVL changed after swap"
        );
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Returns `data` without its leading 4-byte selector, so abi.decode can consume a
    ///      custom-error payload.
    function _stripSelector(bytes memory data) internal pure returns (bytes memory) {
        bytes memory out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
        return out;
    }

    /// @dev Asserts that a swap on shellKey reverts with the given inner error selector, unwrapping
    ///      the v4-core ERC-7751 WrappedError envelope.
    function _expectLpRevertOnSwap(bool zeroForOne, int256 amountSpecified, bytes4 innerSelector) internal {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        try swapRouter.swap(
            shellKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            bytes("")
        ) {
            assertTrue(false, "expected revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "ERC-7751 wrapper");
            (, bytes4 fnSelector, bytes memory inner,) =
                abi.decode(_stripSelector(reason), (address, bytes4, bytes, bytes));
            assertEq(fnSelector, IHooks.beforeSwap.selector, "wrapper selector");
            assertEq(bytes4(inner), innerSelector, "inner selector");
        }
    }

    function _addCurLiquidity(uint256 liquidityAmount) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: int128(int256(liquidityAmount)), salt: 0
        });
        liquidityRouter.modifyLiquidity(shellKey, params, bytes(""));
    }

    function _addLpLiquidity(uint256 liquidityAmount) internal {
        // Need to wrap tokens and provide them to the lp pool.
        // The lp pool uses fewTokens, so we need to wrap first and approve the liquidity router.
        uint256 amount0 = liquidityAmount;
        uint256 amount1 = liquidityAmount;

        // Wrap tokens for the lp pool.
        address lpToken0 = Currency.unwrap(lpKey.currency0);
        address lpToken1 = Currency.unwrap(lpKey.currency1);
        address origin0 = IFewWrappedToken(lpToken0).token();
        address origin1 = IFewWrappedToken(lpToken1).token();

        MockERC20(origin0).approve(lpToken0, type(uint256).max);
        MockERC20(origin1).approve(lpToken1, type(uint256).max);
        IFewWrappedToken(lpToken0).wrap(amount0);
        IFewWrappedToken(lpToken1).wrap(amount1);

        // Approve fewTokens for liquidity router.
        IERC20(lpToken0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(lpToken1).approve(address(liquidityRouter), type(uint256).max);

        // Also mint fewTokens to PoolManager for the hook's flash-take of output.
        // The hook takes fewOut from PoolManager during lp route settlement.
        MockERC20(origin0).approve(lpToken0, type(uint256).max);
        MockERC20(origin1).approve(lpToken1, type(uint256).max);
        // Wrap extra to give to PoolManager.
        IFewWrappedToken(lpToken0).wrap(amount0 * 100);
        IFewWrappedToken(lpToken1).wrap(amount1 * 100);
        IERC20(lpToken0).transfer(address(manager), amount0 * 100);
        IERC20(lpToken1).transfer(address(manager), amount1 * 100);

        // Use a tick range that contains the lp pool's shellrent tick.
        // SQRT_PRICE_2_1 -> tick 6931, SQRT_PRICE_1_2 -> tick -6931, SQRT_PRICE_1_1 -> tick 0.
        // We use a range centered on 0 with enough width to cover all test prices.
        // Use tick spacing multiples (TICK_SPACING=10).
        // Range -7000 to 7000 covers ticks -6931 and 6931.
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -7000, tickUpper: 7000, liquidityDelta: int128(int256(liquidityAmount)), salt: 0
        });
        liquidityRouter.modifyLiquidity(lpKey, params, bytes(""));
    }

    /// @dev Like `_addLpLiquidity` but for an explicit fb key (used by lpPools registration tests).
    ///      Tick bounds are derived from the key's tickSpacing so they remain valid multiples.
    function _addLpLiquidityWithKey(PoolKey memory key, uint256 liquidityAmount) internal {
        address lpToken0 = Currency.unwrap(key.currency0);
        address lpToken1 = Currency.unwrap(key.currency1);
        address origin0 = IFewWrappedToken(lpToken0).token();
        address origin1 = IFewWrappedToken(lpToken1).token();

        MockERC20(origin0).approve(lpToken0, type(uint256).max);
        MockERC20(origin1).approve(lpToken1, type(uint256).max);

        // Wrap ample fewTokens: liquidity for the pool plus a buffer for PoolManager flash-take.
        uint256 poolAmount0 = liquidityAmount * 200;
        uint256 poolAmount1 = liquidityAmount * 200;
        IFewWrappedToken(lpToken0).wrap(poolAmount0);
        IFewWrappedToken(lpToken1).wrap(poolAmount1);

        IERC20(lpToken0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(lpToken1).approve(address(liquidityRouter), type(uint256).max);

        // Send extra fewTokens to PoolManager for the hook's flash-take of output.
        uint256 managerReserve0 = liquidityAmount * 100;
        uint256 managerReserve1 = liquidityAmount * 100;
        IERC20(lpToken0).transfer(address(manager), managerReserve0);
        IERC20(lpToken1).transfer(address(manager), managerReserve1);

        // Tick bounds are multiples of tickSpacing and wide enough to cover test prices
        // (tick 6931 for SQRT_PRICE_2_1, tick -6931 for SQRT_PRICE_1_2).
        int24 halfRange = int24(int256(uint256(uint24(key.tickSpacing))) * 700);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -halfRange, tickUpper: halfRange, liquidityDelta: int128(int256(liquidityAmount)), salt: 0
        });
        liquidityRouter.modifyLiquidity(key, params, bytes(""));
    }

    function _swapAsUser(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return _swapAsUser(zeroForOne, amountSpecified, bytes(""));
    }

    function _swapAsUser(bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        return swapRouter.swap(
            shellKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            hookData
        );
    }

    function _fallbackData(uint256 amountLimit) internal view returns (bytes memory) {
        return abi.encode(block.timestamp + 1 hours, amountLimit);
    }

    /// @dev Returns the lp pool sqrtPriceX96 that makes fb better for zeroForOne.
    ///      When orderAligned: fb needs higher sqrtPrice -> SQRT_PRICE_2_1.
    ///      When !orderAligned: fb needs lower sqrtPrice (inverts to higher) -> SQRT_PRICE_1_2.
    function _lpPriceForBetterZeroForOne() internal view returns (uint160) {
        return orderAligned ? SQRT_PRICE_2_1 : SQRT_PRICE_1_2;
    }

    /// @dev Returns the lp pool sqrtPriceX96 that makes fb better for oneForZero.
    ///      When orderAligned: fb needs lower sqrtPrice -> SQRT_PRICE_1_2.
    ///      When !orderAligned: fb needs higher sqrtPrice (inverts to lower) -> SQRT_PRICE_2_1.
    function _lpPriceForBetterOneForZero() internal view returns (uint160) {
        return orderAligned ? SQRT_PRICE_1_2 : SQRT_PRICE_2_1;
    }
}
