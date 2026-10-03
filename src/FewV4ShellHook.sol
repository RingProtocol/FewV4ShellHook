// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";
import {IAggregatorHook} from "./interfaces/IAggregatorHook.sol";
import {LpRouteLib} from "./libraries/LpRouteLib.sol";
import {LpPriceLib} from "./libraries/LpPriceLib.sol";
import {LpSettlement} from "./base/LpSettlement.sol";
import {LpOwner} from "./base/LpOwner.sol";

/// @title FewV4ShellHook
/// @notice A v4 hook that routes all swaps through the fwA/fwB FewToken lp pool (lp pool).
///
/// @dev Core logic:
///      The hook always routes to lp when available. The shell pool is never used as an execution venue.
///      If lp is unavailable (no route, no liquidity, or insufficient inventory), the swap reverts.
///
///      Slippage protection relies on v4 native mechanisms:
///      - sqrtPriceLimitX96 is mapped to the lp pool's price space before the lp swap.
///      - The caller's router enforces deadline, amountOutMinimum, and amountInMaximum.
///      - lp swaps must fill completely or the whole transaction reverts.
///      hookData is ignored.
//
///      Safety model:
///      - a two-step transferable `owner` (set by the constructor argument) can initialize Shell Pools
///        and register or remove explicit lp pool mappings; there is no upgrade, added fee, or sweep capability;
///      - anyone may add liquidity to the shell pool;
///      - routing always goes to lp; the shell pool is never used as a lp venue;
///      - the lp pool key is taken only from the owner-registered `lpPools` mapping (keyed by shell pool PoolId);
///      - wrap/unwrap are strict 1:1 with return-value and balance checks;
///      - exact-input and exact-output requests must fill completely or the whole transaction reverts;
///      - the PoolManager must already hold enough physical origin input for the atomic flash conversion
///        when the lp route is chosen.
contract FewV4ShellHook is BaseHook, LpSettlement, LpOwner, ReentrancyLock, IAggregatorHook {
    using CurrencyLibrary for Currency;
    using FullMath for uint256;
    using LpRouteLib for LpRouteLib.LpRoute;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    error WrapperUnderlyingMismatch(address wrapper, address expected, address actual);
    error NonCanonicalWrapper(address wrapper, address expectedCanonical);
    error DependencyHasNoCode(address dependency);
    error QuoterPoolManagerMismatch(address expected, address actual);
    error UnexpectedNativeSender(address sender);
    error LpHookReturnsDeltaUnsupported(address hook);
    error LpRouteAlreadyRegistered(PoolId lpPoolId, PoolId shellPoolId);
    error LpSwapDirectionMismatch();
    error LpSwapPartialFill(uint256 actual, uint256 expected);
    error LpRouteUnavailable();
    error LpInsufficientInventory(address token, uint256 available, uint256 required);
    error ShellPoolNotInitialized(PoolId shellPoolId);
    error QuoteAmountTooLarge(uint256 amount, uint256 max);
    error InvalidAmount();

    event LpSwap(
        PoolId indexed shellPoolId,
        PoolId indexed lpPoolId,
        address indexed sender,
        bool zeroForOne,
        bool usedLp,
        int256 amountSpecified,
        uint256 amountIn,
        uint256 amountOut
    );
    event LpPoolSet(PoolId indexed shellPoolId, PoolKey lpPoolKey);
    event LpPoolRemoved(PoolId indexed shellPoolId);

    IFewFactory public immutable fewFactory;
    IWETH9 public immutable weth;
    IV4Quoter public immutable v4Quoter;

    /// @notice Owner-registered explicit lp pool definitions, keyed by the shell pool's PoolId.
    mapping(PoolId => LpPool) public lpPools;

    /// @notice Prevents duplicate Shell pools for the same origin-token pair and FewToken LP.
    /// @dev Native ETH and WETH use different keys, so both user-facing modes may share one LP.
    mapping(bytes32 => PoolId) public shellPoolForRoute;
    mapping(bytes32 => bool) public routeRegistered;

    /// @notice Records the shell pool keys that have been initialized through this hook, keyed by PoolId.
    mapping(PoolId => PoolKey) public initedPools;

    /// @notice Enumerable list of all shell pool PoolIds that have been initialized through this hook.
    PoolId[] public initedPoolIds;

    struct LpPool {
        PoolKey lpPoolKey;
        bool orderAligned;
        bool set;
    }

    constructor(
        IPoolManager _poolManager,
        IFewFactory _fewFactory,
        IWETH9 _wrappedNative,
        IV4Quoter _v4Quoter,
        address _owner
    ) BaseHook(_poolManager) LpSettlement(_wrappedNative) LpOwner(_owner) {
        if (
            address(_poolManager) == address(0) || address(_fewFactory) == address(0)
                || address(_wrappedNative) == address(0) || address(_v4Quoter) == address(0)
        ) {
            revert ZeroAddress();
        }
        _requireCode(address(_poolManager));
        _requireCode(address(_fewFactory));
        _requireCode(address(_wrappedNative));
        _requireCode(address(_v4Quoter));
        address quoterPoolManager = address(_v4Quoter.poolManager());
        if (quoterPoolManager != address(_poolManager)) {
            revert QuoterPoolManagerMismatch(address(_poolManager), quoterPoolManager);
        }
        fewFactory = _fewFactory;
        weth = _wrappedNative;
        v4Quoter = _v4Quoter;
    }

    /// @notice Registers an explicit lp pool for the given shell pool. The `lpPoolKey`'s
    ///         currency0/currency1 must be FewToken wrappers for shellPoolKey.currency0/currency1
    ///         respectively (in either order). The `lpPoolKey.hooks` is preserved, so a hooked lp
    ///         pool may be registered unless it returns swap deltas that this shell cannot settle.
    ///         Passing an empty `lpPoolKey` (currency0 == address(0)) removes the registration and
    ///         disables swaps for that shell pool until a new LP pool is registered.
    // Registration deliberately validates initialization, hook flags, canonical wrappers,
    // currency order, duplicate routes and cached approvals in one bounded admin path.
    // slither-disable-next-line cyclomatic-complexity
    function setLpPool(PoolKey calldata shellPoolKey, PoolKey calldata lpPoolKey) external onlyOwner {
        PoolId shellPoolId = shellPoolKey.toId();
        if (address(initedPools[shellPoolId].hooks) == address(0)) revert ShellPoolNotInitialized(shellPoolId);

        // Empty lpPoolKey (currency0 == address(0)) means removal.
        if (Currency.unwrap(lpPoolKey.currency0) == address(0)) {
            if (!lpPools[shellPoolId].set) return;
            PoolId previousLpPoolId = lpPools[shellPoolId].lpPoolKey.toId();
            bytes32 previousRouteKey = _routeRegistrationKey(previousLpPoolId, shellPoolKey);
            delete routeRegistered[previousRouteKey];
            shellPoolForRoute[previousRouteKey] = PoolId.wrap(bytes32(0));
            delete lpPools[shellPoolId];
            emit LpPoolRemoved(shellPoolId);
            return;
        }

        uint160 lpHookFlags = uint160(address(lpPoolKey.hooks));
        if (lpHookFlags & (Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0) {
            revert LpHookReturnsDeltaUnsupported(address(lpPoolKey.hooks));
        }

        // Validate: lpPoolKey.currency0/currency1 must be FewToken wrappers for shellPoolKey's
        // currencies (in either order). Native ETH (address(0)) maps to WETH for comparison.
        address shellLookup0 = Currency.unwrap(shellPoolKey.currency0);
        address shellLookup1 = Currency.unwrap(shellPoolKey.currency1);
        shellLookup0 = shellLookup0 == address(0) ? address(weth) : shellLookup0;
        shellLookup1 = shellLookup1 == address(0) ? address(weth) : shellLookup1;
        address few0 = Currency.unwrap(lpPoolKey.currency0);
        address few1 = Currency.unwrap(lpPoolKey.currency1);
        if (few0.code.length == 0 || few1.code.length == 0) revert ZeroAddress();

        address underlying0 = IFewWrappedToken(few0).token();
        address underlying1 = IFewWrappedToken(few1).token();
        address canonical0 = fewFactory.getWrappedToken(underlying0);
        address canonical1 = fewFactory.getWrappedToken(underlying1);
        if (canonical0 != few0) revert NonCanonicalWrapper(few0, canonical0);
        if (canonical1 != few1) revert NonCanonicalWrapper(few1, canonical1);
        bool orderAligned = false;
        if (underlying0 == shellLookup0 && underlying1 == shellLookup1) {
            orderAligned = true;
        } else if (underlying0 == shellLookup1 && underlying1 == shellLookup0) {
            orderAligned = false;
        } else {
            revert WrapperUnderlyingMismatch(few0, shellLookup0, underlying0);
        }

        PoolId lpPoolId = lpPoolKey.toId();
        bytes32 routeKey = _routeRegistrationKey(lpPoolId, shellPoolKey);
        if (routeRegistered[routeKey] && PoolId.unwrap(shellPoolForRoute[routeKey]) != PoolId.unwrap(shellPoolId)) {
            revert LpRouteAlreadyRegistered(lpPoolId, shellPoolForRoute[routeKey]);
        }

        LpPool storage previous = lpPools[shellPoolId];
        if (previous.set) {
            PoolId previousLpPoolId = previous.lpPoolKey.toId();
            if (PoolId.unwrap(previousLpPoolId) != PoolId.unwrap(lpPoolId)) {
                bytes32 previousRouteKey = _routeRegistrationKey(previousLpPoolId, shellPoolKey);
                delete routeRegistered[previousRouteKey];
                shellPoolForRoute[previousRouteKey] = PoolId.wrap(bytes32(0));
            }
        }

        _authorizeWrapper(underlying0, few0);
        _authorizeWrapper(underlying1, few1);

        lpPools[shellPoolId] = LpPool({lpPoolKey: lpPoolKey, orderAligned: orderAligned, set: true});
        routeRegistered[routeKey] = true;
        shellPoolForRoute[routeKey] = shellPoolId;
        emit LpPoolSet(shellPoolId, lpPoolKey);
    }

    // ---------------------------------------------------------------------
    // Quote
    // ---------------------------------------------------------------------

    /// @notice Quotes the complete shell swap, including settlement inventory, wrap/unwrap and full fill.
    /// @dev Top-level quote using V4Quoter's revert-based simulation: every simulated state change rolls back.
    ///      Like standard V4Quoter, this models swap-before-payment. A prepaid router may execute a trade
    ///      unavailable to this quote, but an inner-pool price alone is not an executable shell quote.
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        external
        override
        returns (uint256 amountUnspecified)
    {
        _validateAmount(amountSpecified);
        PoolKey memory shellKey = initedPools[poolId];
        if (address(shellKey.hooks) == address(0)) revert ShellPoolNotInitialized(poolId);

        LpRouteLib.LpRoute memory route = _deriveLpRoute(shellKey, poolId);
        if (!route.available) revert LpRouteUnavailable();

        if (amountSpecified < 0) {
            uint256 exactAmount = uint256(-amountSpecified);
            // Gas estimate is not part of IAggregatorHook.quote's return value.
            // slither-disable-next-line unused-return
            (amountUnspecified,) = v4Quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: shellKey, zeroForOne: zeroToOne, exactAmount: uint128(exactAmount), hookData: bytes("")
                })
            );
        } else {
            uint256 exactAmount = uint256(amountSpecified);
            // Gas estimate is not part of IAggregatorHook.quote's return value.
            // slither-disable-next-line unused-return
            (amountUnspecified,) = v4Quoter.quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: shellKey, zeroForOne: zeroToOne, exactAmount: uint128(exactAmount), hookData: bytes("")
                })
            );
        }
    }

    /// @notice Returns a liquidity-depth proxy for the shell pool, expressed in the shell pool's currency
    ///         order. Reads the lp pool's sqrtPriceX96 and active liquidity and computes virtual amounts.
    /// @dev This is an active-liquidity depth proxy, not accounting TVL. Returns (0, 0) if the lp pool
    ///      is unavailable, uninitialized, or has no active liquidity.
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolKey memory shellKey = initedPools[poolId];
        if (address(shellKey.hooks) == address(0)) revert ShellPoolNotInitialized(poolId);

        LpRouteLib.LpRoute memory route = _deriveLpRoute(shellKey, poolId);
        if (!route.available) return (0, 0);

        // Only the active price is needed for the depth proxy.
        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(route.lpPoolId);
        uint128 liquidity = poolManager.getLiquidity(route.lpPoolId);
        if (sqrtPriceX96 == 0 || liquidity == 0) return (0, 0);

        uint256 virtual0 = FullMath.mulDiv(uint256(liquidity), 1 << 96, sqrtPriceX96);
        uint256 virtual1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, 1 << 96);
        return route.orderAligned ? (virtual0, virtual1) : (virtual1, virtual0);
    }

    /// @dev Required to receive native ETH from PoolManager.take() and WETH9.withdraw().
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(weth)) {
            revert UnexpectedNativeSender(msg.sender);
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
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

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // A shell pool's slot0 is metadata rather than the executable price, but it is permanent.
        // Restrict initialization so an unrelated account cannot front-run the reviewed PoolKey
        // with a misleading price before the owner configures its canonical FewToken LP route.
        if (sender != owner) revert NotOwner(sender, owner);
        PoolId id = key.toId();
        initedPools[id] = key;
        initedPoolIds.push(id);
        emit AggregatorPoolRegistered(id);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Returns the number of shell pools that have been initialized through this hook.
    function initedPoolCount() external view returns (uint256) {
        return initedPoolIds.length;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    )
        internal
        override
        isNotLocked
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateAmount(params.amountSpecified);
        PoolId shellPoolId = key.toId();

        // lp is the only execution venue. If no route is available, revert.
        LpRouteLib.LpRoute memory route = _deriveLpRoute(key, shellPoolId);
        if (!route.available) revert LpRouteUnavailable();

        bool lpZeroForOne = params.zeroForOne == route.orderAligned;

        // Pre-swap check (exact-input only): PoolManager must already hold enough origin input
        // token for the flash conversion leg. Fails fast before spending gas on the lp swap.
        if (params.amountSpecified < 0) {
            uint256 requestedInput = uint256(-params.amountSpecified);
            _requireSettlementInventory(params.zeroForOne ? route.token0 : route.token1, requestedInput);
        }

        (uint256 amountIn, uint256 amountOut) =
            _executeLpSwap(route, lpZeroForOne, params.amountSpecified, params.sqrtPriceLimitX96);

        // Post-swap check (exact-output only): amountIn is unknown until the lp swap executes,
        // so the pre-check was skipped. Verify PoolManager holds enough origin input now.
        if (params.amountSpecified > 0) {
            _requireSettlementInventory(params.zeroForOne ? route.token0 : route.token1, amountIn);
        }

        // Post-swap check: the few token contract must hold enough underlying origin token to
        // fulfill the unwrap. Route construction already validated which underlying belongs to
        // the output wrapper; native ETH maps to WETH.
        address fewOut = params.zeroForOne ? route.few1 : route.few0;
        address outputUnderlying = params.zeroForOne ? route.token1 : route.token0;
        if (outputUnderlying == address(0)) outputUnderlying = address(weth);
        uint256 availableUnderlying = IERC20(outputUnderlying).balanceOf(fewOut);
        if (availableUnderlying < amountOut) {
            revert LpInsufficientInventory(fewOut, availableUnderlying, amountOut);
        }

        convertAndSettle(route, params.zeroForOne, amountIn, amountOut);

        int128 specifiedDelta = (-params.amountSpecified).toInt128();
        int128 unspecifiedDelta = params.amountSpecified < 0 ? -amountOut.toInt128() : amountIn.toInt128();

        emit LpSwap(
            shellPoolId, route.lpPoolId, sender, params.zeroForOne, true, params.amountSpecified, amountIn, amountOut
        );

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    // ---------------------------------------------------------------------
    // lp route derivation
    // ---------------------------------------------------------------------

    function _deriveLpRoute(PoolKey memory key, PoolId shellPoolId)
        internal
        view
        returns (LpRouteLib.LpRoute memory route)
    {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (key.fee.isDynamicFee()) revert LpRouteUnavailable();

        // Owner-registered lp pool is the only source for the lp route.
        LpPool memory registered = lpPools[shellPoolId];
        if (registered.set) {
            PoolKey memory lpKey = registered.lpPoolKey;
            bool orderAligned = registered.orderAligned;
            // few0/few1 in the route always wrap shell token0/token1 respectively.
            address regFew0 = Currency.unwrap(orderAligned ? lpKey.currency0 : lpKey.currency1);
            address regFew1 = Currency.unwrap(orderAligned ? lpKey.currency1 : lpKey.currency0);
            return LpRouteLib.buildRoute(
                poolManager, token0, token1, regFew0, regFew1, lpKey.fee, lpKey.tickSpacing, lpKey.hooks, orderAligned
            );
        }
        return route;
    }

    // ---------------------------------------------------------------------
    // ---------------------------------------------------------------------
    // lp swap execution
    // ---------------------------------------------------------------------

    function _executeLpSwap(
        LpRouteLib.LpRoute memory route,
        bool lpZeroForOne,
        int256 amountSpecified,
        uint160 shellPriceLimitX96
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        uint160 lpLimit = LpPriceLib.mapLpPriceLimit(route.orderAligned, lpZeroForOne, shellPriceLimitX96);

        BalanceDelta delta = poolManager.swap(
            route.lpKeyFromRoute(),
            SwapParams({zeroForOne: lpZeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: lpLimit}),
            bytes("")
        );

        int128 inputDelta = lpZeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = lpZeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert LpSwapDirectionMismatch();

        amountIn = uint256(-int256(inputDelta));
        amountOut = uint256(int256(outputDelta));

        uint256 expected = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 actualSpecified = amountSpecified < 0 ? amountIn : amountOut;
        if (actualSpecified != expected) revert LpSwapPartialFill(actualSpecified, expected);
    }

    /// @dev Verifies the PoolManager holds enough origin token to fulfill the flash conversion
    ///      input leg. Reusing LpInsufficientInventory for a consistent error surface.
    function _requireSettlementInventory(address token, uint256 amount) internal view {
        uint256 available =
            token == address(0) ? address(poolManager).balance : IERC20(token).balanceOf(address(poolManager));
        if (available < amount) revert LpInsufficientInventory(token, available, amount);
    }

    /// @dev V4 swap deltas and the quoter's exact-in cast are signed int128. Never truncate an amount.
    function _validateAmount(int256 amount) internal pure {
        if (amount == 0 || amount < -int256(type(int128).max) || amount > int256(type(int128).max)) {
            revert InvalidAmount();
        }
    }

    function _requireCode(address dependency) internal view {
        if (dependency.code.length == 0) revert DependencyHasNoCode(dependency);
    }

    function _routeRegistrationKey(PoolId lpPoolId, PoolKey memory shellPoolKey) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(lpPoolId, Currency.unwrap(shellPoolKey.currency0), Currency.unwrap(shellPoolKey.currency1))
        );
    }
}
