// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DeltaResolver} from "v4-periphery/src/base/DeltaResolver.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {IAggregatorHook} from "./interfaces/IAggregatorHook.sol";
import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";

/// @title FewV4ShellHook
/// @notice Exposes an origin-token A/B v4 pool while executing every swap against one approved,
///         hookless fwA/fwB v4 pool: origin A -> fwA -> inner v4 swap -> fwB -> origin B.
/// @dev The outer pool deliberately has no native liquidity. A before-swap return delta replaces
///      the outer swap with the nested inner swap and leaves every Hook-owned PoolManager delta at zero.
///
///      Safety model:
///      - no owner, upgrade, pause, fee, sweep, or post-deploy route setter;
///      - only constructor-allowlisted inner PoolIds may be registered;
///      - every inner key is canonical, static-fee, and hookless;
///      - exact-input and exact-output requests must fill completely or the whole transaction reverts;
///      - only the canonical v4 extreme price limits are accepted in V1;
///      - the PoolManager must already hold enough physical origin input for the atomic flash conversion.
contract FewV4ShellHook is BaseHook, DeltaResolver, ReentrancyGuard, IAggregatorHook {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    struct RegisteredRoute {
        address token0;
        address token1;
        address few0;
        address few1;
        uint24 fee;
        int24 tickSpacing;
        PoolId innerPoolId;
        bool orderAligned;
        bool registered;
    }

    error ZeroAddress();
    error EmptyInnerPoolAllowlist();
    error DuplicateAllowedInnerPool(PoolId poolId);
    error InvalidOuterCurrencies();
    error NativeCurrencyNotSupported();
    error DynamicFeeNotSupported();
    error CanonicalWrapperMissing(address origin);
    error InvalidWrapper(address origin, address wrapper);
    error WrapperUnderlyingMismatch(address wrapper, address expected, address actual);
    error InnerPoolNotAllowed(PoolId poolId);
    error InnerPoolNotInitialized(PoolId poolId);
    error InnerPoolHasNoActiveLiquidity(PoolId poolId);
    error InnerPoolAlreadyRegistered(PoolId innerPoolId, PoolId outerPoolId);
    error OuterPriceMismatch(uint160 supplied, uint160 expected);
    error InvalidMirroredPrice(uint256 sqrtPriceX96);
    error UnexpectedHookData();
    error AmountOutOfRange(int256 amountSpecified);
    error UnsupportedOuterPriceLimit(uint160 supplied, uint160 expected);
    error InnerSwapDirectionMismatch();
    error InnerSwapPartialFill(uint256 actual, uint256 expected);
    error InsufficientSettlementInventory(address token, uint256 available, uint256 required);
    error QuoterPoolManagerMismatch();
    error WrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error UnwrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error InsufficientConversionBalance(address token, uint256 available, uint256 required);
    error TokenBalanceMismatch(address token, uint256 expectedBalance, uint256 actualBalance);
    error SettlementAmountMismatch(address token, uint256 paid, uint256 expected);

    event InnerPoolAllowed(PoolId indexed innerPoolId);
    event ShellPoolRegistered(
        PoolId indexed outerPoolId, PoolId indexed innerPoolId, address indexed few0, address few1, bool orderAligned
    );
    event ShellSwap(
        PoolId indexed outerPoolId,
        PoolId indexed innerPoolId,
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 amountIn,
        uint256 amountOut
    );

    IFewFactory public immutable fewFactory;
    IV4Quoter public immutable quoter;

    /// @notice Constructor-fixed inner liquidity sources. There is no function that can mutate this mapping later.
    mapping(PoolId innerPoolId => bool allowed) public allowedInnerPools;
    mapping(PoolId outerPoolId => RegisteredRoute route) internal _registeredRoutes;
    mapping(PoolId innerPoolId => bool registered) public innerPoolRegistered;
    mapping(PoolId innerPoolId => PoolId outerPoolId) public outerPoolForInnerPool;

    constructor(
        IPoolManager _poolManager,
        IFewFactory _fewFactory,
        IV4Quoter _quoter,
        PoolId[] memory _allowedInnerPoolIds
    ) BaseHook(_poolManager) {
        if (address(_poolManager) == address(0) || address(_fewFactory) == address(0) || address(_quoter) == address(0))
        {
            revert ZeroAddress();
        }
        if (address(_quoter.poolManager()) != address(_poolManager)) revert QuoterPoolManagerMismatch();
        if (_allowedInnerPoolIds.length == 0) revert EmptyInnerPoolAllowlist();

        fewFactory = _fewFactory;
        quoter = _quoter;

        for (uint256 i; i < _allowedInnerPoolIds.length; ++i) {
            PoolId innerPoolId = _allowedInnerPoolIds[i];
            if (allowedInnerPools[innerPoolId]) revert DuplicateAllowedInnerPool(innerPoolId);
            allowedInnerPools[innerPoolId] = true;
            emit InnerPoolAllowed(innerPoolId);
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Returns the immutable route registered for an outer pool.
    function routeForPool(PoolId outerPoolId) external view returns (RegisteredRoute memory) {
        RegisteredRoute memory route = _registeredRoutes[outerPoolId];
        if (!route.registered) revert PoolDoesNotExist();
        return route;
    }

    /// @notice Returns the exact hookless inner key used by an outer pool.
    function innerPoolKey(PoolId outerPoolId) external view returns (PoolKey memory) {
        RegisteredRoute storage route = _registeredRoute(outerPoolId);
        return _innerPoolKey(route);
    }

    /// @notice Previews the canonical wrappers, allowlisted inner pool, ordering, and safe outer init price.
    /// @dev Deployment tooling should call this immediately before initializing the outer pool.
    function previewRoute(address token0, address token1, uint24 fee, int24 tickSpacing)
        external
        view
        returns (address few0, address few1, PoolId innerPoolId, bool orderAligned, uint160 outerSqrtPriceX96)
    {
        RegisteredRoute memory route = _deriveRoute(token0, token1, fee, tickSpacing);
        return (
            route.few0,
            route.few1,
            route.innerPoolId,
            route.orderAligned,
            _recommendedOuterPrice(route.innerPoolId, route.orderAligned)
        );
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        RegisteredRoute memory route =
            _deriveRoute(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), key.fee, key.tickSpacing);
        uint160 expectedPrice = _recommendedOuterPrice(route.innerPoolId, route.orderAligned);
        if (sqrtPriceX96 != expectedPrice) revert OuterPriceMismatch(sqrtPriceX96, expectedPrice);

        PoolId outerPoolId = key.toId();
        if (innerPoolRegistered[route.innerPoolId]) {
            revert InnerPoolAlreadyRegistered(route.innerPoolId, outerPoolForInnerPool[route.innerPoolId]);
        }

        route.registered = true;
        _registeredRoutes[outerPoolId] = route;
        innerPoolRegistered[route.innerPoolId] = true;
        outerPoolForInnerPool[route.innerPoolId] = outerPoolId;

        emit AggregatorPoolRegistered(outerPoolId);
        emit ShellPoolRegistered(outerPoolId, route.innerPoolId, route.few0, route.few1, route.orderAligned);
        return IHooks.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId outerPoolId = key.toId();
        RegisteredRoute storage route = _registeredRoute(outerPoolId);
        if (hookData.length != 0) revert UnexpectedHookData();
        _validateAmount(params.amountSpecified);

        uint160 expectedOuterLimit = params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (params.sqrtPriceLimitX96 != expectedOuterLimit) {
            revert UnsupportedOuterPriceLimit(params.sqrtPriceLimitX96, expectedOuterLimit);
        }

        bool innerZeroForOne = params.zeroForOne == route.orderAligned;
        if (params.amountSpecified < 0) {
            uint256 requestedInput = uint256(-params.amountSpecified);
            _requireSettlementInventory(params.zeroForOne ? route.token0 : route.token1, requestedInput);
        }

        (uint256 amountIn, uint256 amountOut) =
            _executeInnerSwap(route, innerZeroForOne, params.amountSpecified, params.sqrtPriceLimitX96);
        _requireSettlementInventory(params.zeroForOne ? route.token0 : route.token1, amountIn);
        _convertAndSettle(route, params.zeroForOne, amountIn, amountOut);

        int128 specifiedDelta = (-params.amountSpecified).toInt128();
        int128 unspecifiedDelta = params.amountSpecified < 0 ? -amountOut.toInt128() : amountIn.toInt128();

        emit ShellSwap(
            outerPoolId, route.innerPoolId, sender, params.zeroForOne, params.amountSpecified, amountIn, amountOut
        );
        _emitHookSwap(outerPoolId, sender, params.zeroForOne, amountIn, amountOut);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    /// @inheritdoc IAggregatorHook
    /// @dev Runs the official V4Quoter against the outer key so the quote simulates the complete nested
    ///      swap, physical PoolManager inventory check, wrap, and unwrap. Call only as a top-level quote.
    function quote(bool zeroToOne, int256 amountSpecified, PoolId outerPoolId)
        external
        override
        returns (uint256 amountUnspecified)
    {
        _validateAmount(amountSpecified);
        RegisteredRoute storage route = _registeredRoute(outerPoolId);
        uint128 exactAmount = uint128(amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified));
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: _outerPoolKey(route), zeroForOne: zeroToOne, exactAmount: exactAmount, hookData: bytes("")
        });

        if (amountSpecified < 0) {
            (amountUnspecified,) = quoter.quoteExactInputSingle(params);
        } else {
            (amountUnspecified,) = quoter.quoteExactOutputSingle(params);
        }
    }

    /// @inheritdoc IAggregatorHook
    /// @dev This is an active-liquidity depth proxy, not accounting TVL. PoolManager ERC20 balances are
    ///      singleton-global and therefore cannot honestly be assigned to an individual inner pool.
    function pseudoTotalValueLocked(PoolId outerPoolId)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        RegisteredRoute storage route = _registeredRoute(outerPoolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(route.innerPoolId);
        uint128 liquidity = poolManager.getLiquidity(route.innerPoolId);
        if (sqrtPriceX96 == 0 || liquidity == 0) return (0, 0);

        uint256 virtual0 = FullMath.mulDiv(uint256(liquidity), 1 << 96, sqrtPriceX96);
        uint256 virtual1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, 1 << 96);
        return route.orderAligned ? (virtual0, virtual1) : (virtual1, virtual0);
    }

    /// @notice Physical singleton inventory currently available for the shell's flash input leg.
    /// @dev This is PoolManager-wide inventory, not route-owned TVL. The router repays it during settlement.
    function availableSettlementInventory(PoolId outerPoolId, bool zeroToOne) external view returns (uint256) {
        RegisteredRoute storage route = _registeredRoute(outerPoolId);
        Currency input = Currency.wrap(zeroToOne ? route.token0 : route.token1);
        return input.balanceOf(address(poolManager));
    }

    function _deriveRoute(address token0, address token1, uint24 fee, int24 tickSpacing)
        internal
        view
        returns (RegisteredRoute memory route)
    {
        if (token0 == address(0) || token1 == address(0)) revert NativeCurrencyNotSupported();
        if (token0 >= token1) revert InvalidOuterCurrencies();
        if (fee.isDynamicFee()) revert DynamicFeeNotSupported();
        fee.validate();

        address few0 = fewFactory.getWrappedToken(token0);
        address few1 = fewFactory.getWrappedToken(token1);
        if (few0 == address(0)) revert CanonicalWrapperMissing(token0);
        if (few1 == address(0)) revert CanonicalWrapperMissing(token1);
        if (few0 == few1) revert InvalidWrapper(token1, few1);
        if (few0 == token0 || few0 == token1 || few0.code.length == 0) revert InvalidWrapper(token0, few0);
        if (few1 == token0 || few1 == token1 || few1.code.length == 0) revert InvalidWrapper(token1, few1);

        address underlying0 = IFewWrappedToken(few0).token();
        address underlying1 = IFewWrappedToken(few1).token();
        if (underlying0 != token0) revert WrapperUnderlyingMismatch(few0, token0, underlying0);
        if (underlying1 != token1) revert WrapperUnderlyingMismatch(few1, token1, underlying1);

        bool orderAligned = few0 < few1;
        PoolKey memory innerKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId innerPoolId = innerKey.toId();
        if (!allowedInnerPools[innerPoolId]) revert InnerPoolNotAllowed(innerPoolId);

        (uint160 innerSqrtPriceX96,,,) = poolManager.getSlot0(innerPoolId);
        if (innerSqrtPriceX96 == 0) revert InnerPoolNotInitialized(innerPoolId);
        if (poolManager.getLiquidity(innerPoolId) == 0) revert InnerPoolHasNoActiveLiquidity(innerPoolId);

        route = RegisteredRoute({
            token0: token0,
            token1: token1,
            few0: few0,
            few1: few1,
            fee: fee,
            tickSpacing: tickSpacing,
            innerPoolId: innerPoolId,
            orderAligned: orderAligned,
            registered: false
        });
    }

    function _recommendedOuterPrice(PoolId innerPoolId, bool orderAligned) internal view returns (uint160) {
        (uint160 innerSqrtPriceX96,,,) = poolManager.getSlot0(innerPoolId);
        if (innerSqrtPriceX96 == 0) revert InnerPoolNotInitialized(innerPoolId);
        if (orderAligned) return innerSqrtPriceX96;

        uint256 inverse = FullMath.mulDiv(1 << 96, 1 << 96, innerSqrtPriceX96);
        if (inverse <= TickMath.MIN_SQRT_PRICE || inverse >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidMirroredPrice(inverse);
        }
        return uint160(inverse);
    }

    function _executeInnerSwap(
        RegisteredRoute storage route,
        bool innerZeroForOne,
        int256 amountSpecified,
        uint160 outerPriceLimitX96
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        PoolKey memory innerKey = _innerPoolKey(route);
        uint160 innerLimit = _mapInnerPriceLimit(route.orderAligned, innerZeroForOne, outerPriceLimitX96);
        BalanceDelta delta = poolManager.swap(
            innerKey,
            SwapParams({zeroForOne: innerZeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: innerLimit}),
            bytes("")
        );

        int128 inputDelta = innerZeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = innerZeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InnerSwapDirectionMismatch();

        amountIn = uint256(-int256(inputDelta));
        amountOut = uint256(int256(outputDelta));
        uint256 expected = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 actualSpecified = amountSpecified < 0 ? amountIn : amountOut;
        if (actualSpecified != expected) revert InnerSwapPartialFill(actualSpecified, expected);
    }

    /// @dev Reversing the token order also reverses sqrt(price). The rounding direction is chosen so
    ///      the mapped inner limit is never looser than the caller's outer limit.
    function _mapInnerPriceLimit(bool orderAligned, bool innerZeroForOne, uint160 outerLimit)
        internal
        pure
        returns (uint160)
    {
        if (orderAligned) return outerLimit;

        uint256 mapped = innerZeroForOne
            ? FullMath.mulDivRoundingUp(1 << 96, 1 << 96, outerLimit)
            : FullMath.mulDiv(1 << 96, 1 << 96, outerLimit);

        if (innerZeroForOne && mapped <= TickMath.MIN_SQRT_PRICE) mapped = TickMath.MIN_SQRT_PRICE + 1;
        if (!innerZeroForOne && mapped >= TickMath.MAX_SQRT_PRICE) mapped = TickMath.MAX_SQRT_PRICE - 1;
        if (mapped <= TickMath.MIN_SQRT_PRICE || mapped >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidMirroredPrice(mapped);
        }
        return uint160(mapped);
    }

    function _convertAndSettle(RegisteredRoute storage route, bool outerZeroForOne, uint256 amountIn, uint256 amountOut)
        internal
    {
        Currency input = Currency.wrap(outerZeroForOne ? route.token0 : route.token1);
        Currency output = Currency.wrap(outerZeroForOne ? route.token1 : route.token0);
        address fewIn = outerZeroForOne ? route.few0 : route.few1;
        address fewOut = outerZeroForOne ? route.few1 : route.few0;

        uint256 inputBaseline = input.balanceOfSelf();
        uint256 fewInBaseline = IERC20(fewIn).balanceOf(address(this));
        _take(input, address(this), amountIn);
        _wrapExact(input, fewIn, amountIn);
        _settleExact(Currency.wrap(fewIn), amountIn);
        _requireBalance(input, inputBaseline);
        _requireBalance(Currency.wrap(fewIn), fewInBaseline);

        uint256 outputBaseline = output.balanceOfSelf();
        uint256 fewOutBaseline = IERC20(fewOut).balanceOf(address(this));
        _take(Currency.wrap(fewOut), address(this), amountOut);
        _unwrapExact(fewOut, output, amountOut);
        _settleExact(output, amountOut);
        _requireBalance(Currency.wrap(fewOut), fewOutBaseline);
        _requireBalance(output, outputBaseline);
    }

    function _wrapExact(Currency input, address fewToken, uint256 amount) internal {
        uint256 inputBefore = input.balanceOfSelf();
        uint256 fewBefore = IERC20(fewToken).balanceOf(address(this));

        IERC20(Currency.unwrap(input)).forceApprove(fewToken, amount);
        uint256 returnedAmount = IFewWrappedToken(fewToken).wrap(amount);
        IERC20(Currency.unwrap(input)).forceApprove(fewToken, 0);
        if (returnedAmount != amount) revert WrapReturnMismatch(returnedAmount, amount);

        if (inputBefore < amount) {
            revert InsufficientConversionBalance(Currency.unwrap(input), inputBefore, amount);
        }
        _requireBalance(input, inputBefore - amount);
        _requireBalance(Currency.wrap(fewToken), fewBefore + amount);
    }

    function _unwrapExact(address fewToken, Currency output, uint256 amount) internal {
        uint256 fewBefore = IERC20(fewToken).balanceOf(address(this));
        uint256 outputBefore = output.balanceOfSelf();
        uint256 returnedAmount = IFewWrappedToken(fewToken).unwrap(amount);
        if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);

        if (fewBefore < amount) revert InsufficientConversionBalance(fewToken, fewBefore, amount);
        _requireBalance(Currency.wrap(fewToken), fewBefore - amount);
        _requireBalance(output, outputBefore + amount);
    }

    function _settleExact(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        uint256 paid = poolManager.settle();
        if (paid != amount) revert SettlementAmountMismatch(Currency.unwrap(currency), paid, amount);
    }

    function _requireBalance(Currency currency, uint256 expected) internal view {
        uint256 actual = currency.balanceOfSelf();
        if (actual != expected) revert TokenBalanceMismatch(Currency.unwrap(currency), expected, actual);
    }

    function _requireSettlementInventory(address token, uint256 amount) internal view {
        uint256 available = IERC20(token).balanceOf(address(poolManager));
        if (available < amount) revert InsufficientSettlementInventory(token, available, amount);
    }

    function _validateAmount(int256 amountSpecified) internal pure {
        if (
            amountSpecified == 0 || amountSpecified > int256(type(int128).max)
                || amountSpecified < -int256(type(int128).max)
        ) {
            revert AmountOutOfRange(amountSpecified);
        }
    }

    function _registeredRoute(PoolId outerPoolId) internal view returns (RegisteredRoute storage route) {
        route = _registeredRoutes[outerPoolId];
        if (!route.registered) revert PoolDoesNotExist();
    }

    function _innerPoolKey(RegisteredRoute storage route) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(route.orderAligned ? route.few0 : route.few1),
            currency1: Currency.wrap(route.orderAligned ? route.few1 : route.few0),
            fee: route.fee,
            tickSpacing: route.tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _outerPoolKey(RegisteredRoute storage route) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(route.token0),
            currency1: Currency.wrap(route.token1),
            fee: route.fee,
            tickSpacing: route.tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    function _emitHookSwap(PoolId outerPoolId, address sender, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        internal
    {
        int256 signedIn = amountIn.toInt256();
        int256 signedOut = amountOut.toInt256();
        (int256 amount0, int256 amount1) = zeroForOne ? (signedIn, -signedOut) : (-signedOut, signedIn);
        // This field is the fee added by the aggregator Hook itself. The inner v4 PoolManager Swap
        // event separately reports its LP + v4 protocol fee; the shell adds no additional fee.
        emit HookSwap(outerPoolId, sender, amount0, amount1, 0);
    }

    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }
}
