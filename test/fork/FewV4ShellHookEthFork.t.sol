// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {FewV4ShellHook} from "../../src/FewV4ShellHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

/// @dev ETH-aware swap router. Handles native currency in settle (send ETH) and take (receive ETH).
contract ShellEthSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    struct CallbackData {
        address payer;
        PoolKey key;
        SwapParams params;
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        CallbackData memory cb = abi.decode(data, (CallbackData));
        BalanceDelta delta = manager.swap(cb.key, cb.params, bytes(""));
        _settle(cb.key.currency0, cb.payer, delta.amount0());
        _settle(cb.key.currency1, cb.payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(int256(delta)));
        }
    }

    receive() external payable {}
}

/// @notice Fork test for native ETH shell: outer pool is ETH/USDC, inner pool is fwETH/fwUSDC.
///         Proves that swaps route through the inner fwETH/fwUSDC v4 pool.
contract FewV4ShellHookEthForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address internal constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant V4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant EXACT_INPUT = 0.05 ether;

    bool internal forked;
    IPoolManager internal manager;
    IFewFactory internal factory;
    FewV4ShellHook internal hook;
    ShellEthSwapRouter internal swapRouter;
    PoolKey internal outerKey;
    PoolId internal outerPoolId;
    PoolId internal innerPoolId;

    address internal fwEth;
    address internal fwUsdc;
    bool internal innerEthIsToken0;

    address internal constant USER = address(0xBEEF);
    address internal constant HOOK_OWNER = address(0xA11CE);

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        manager = IPoolManager(V4_POOL_MANAGER);
        factory = IFewFactory(FEW_FACTORY);

        fwEth = factory.getWrappedToken(WETH);
        fwUsdc = factory.getWrappedToken(USDC);
        require(fwEth != address(0) && fwUsdc != address(0), "wrapper missing");
        require(IFewWrappedToken(fwEth).token() == WETH, "fwEth underlying");
        require(IFewWrappedToken(fwUsdc).token() == USDC, "fwUsdc underlying");

        innerEthIsToken0 = fwEth < fwUsdc;
        PoolKey memory iKey = PoolKey({
            currency0: Currency.wrap(innerEthIsToken0 ? fwEth : fwUsdc),
            currency1: Currency.wrap(innerEthIsToken0 ? fwUsdc : fwEth),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        innerPoolId = iKey.toId();

        (uint160 innerPrice,,,) = manager.getSlot0(innerPoolId);
        if (innerPrice == 0 || manager.getLiquidity(innerPoolId) == 0) {
            _bootstrapInnerPool(iKey);
        }

        PoolId[] memory allowed = new PoolId[](1);
        allowed[0] = innerPoolId;
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            manager,
            IFewFactory(FEW_FACTORY),
            IV4Quoter(V4_QUOTER),
            IWETH9(WETH),
            allowed,
            HOOK_OWNER,
            IPositionManager(V4_POSITION_MANAGER)
        );
        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, constructorArgs);
        hook = new FewV4ShellHook{salt: salt}(
            manager,
            IFewFactory(FEW_FACTORY),
            IV4Quoter(V4_QUOTER),
            IWETH9(WETH),
            allowed,
            HOOK_OWNER,
            IPositionManager(V4_POSITION_MANAGER)
        );
        assertEq(address(hook), mined);

        outerKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        outerPoolId = outerKey.toId();

        (,,,, uint160 recommendedPrice) = hook.previewRoute(address(0), USDC, FEE, TICK_SPACING);
        manager.initialize(outerKey, recommendedPrice);

        swapRouter = new ShellEthSwapRouter(manager);

        vm.deal(USER, 10 ether);
        deal(USDC, address(manager), 100_000e6);

        vm.startPrank(USER);
        IERC20(USDC).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    modifier requireFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_ethToUsdc_exactInput_routesThroughInnerPool() public requireFork {
        (uint160 innerPriceBefore,,,) = manager.getSlot0(innerPoolId);
        (uint160 outerPriceBefore,,,) = manager.getSlot0(outerPoolId);
        uint128 outerLiqBefore = manager.getLiquidity(outerPoolId);
        uint256 userEthBefore = USER.balance;
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        uint256 quote = hook.quote(true, -int256(EXACT_INPUT), outerPoolId);
        assertGt(quote, 0, "quote > 0");

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: EXACT_INPUT}(
            outerKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(EXACT_INPUT),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        assertEq(userEthBefore - USER.balance, EXACT_INPUT, "user paid exact ETH input");
        assertEq(IERC20(USDC).balanceOf(USER) - userUsdcBefore, quote, "user received quoted USDC");
        assertEq(int256(delta.amount0()), -int256(EXACT_INPUT), "delta amount0 = -input");
        assertEq(int256(delta.amount1()), int256(quote), "delta amount1 = +output");

        (uint160 innerPriceAfter,,,) = manager.getSlot0(innerPoolId);
        assertTrue(innerPriceAfter != innerPriceBefore, "inner price moved = swap routed through inner pool");

        (uint160 outerPriceAfter,,,) = manager.getSlot0(outerPoolId);
        assertEq(outerPriceAfter, outerPriceBefore, "outer price unchanged = inert");
        assertEq(manager.getLiquidity(outerPoolId), outerLiqBefore, "outer liquidity unchanged");

        assertEq(address(hook).balance, 0, "hook ETH balance zero");
        assertEq(IERC20(fwEth).balanceOf(address(hook)), 0, "hook fwEth zero");
        assertEq(IERC20(fwUsdc).balanceOf(address(hook)), 0, "hook fwUsdc zero");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook USDC zero");
    }

    function test_usdcToEth_exactInput_routesThroughInnerPool() public requireFork {
        deal(USDC, USER, 10_000e6);
        vm.startPrank(USER);
        IERC20(USDC).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        (uint160 innerPriceBefore,,,) = manager.getSlot0(innerPoolId);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        uint256 userEthBefore = USER.balance;

        uint256 quote = hook.quote(false, -int256(100e6), outerPoolId);
        assertGt(quote, 0, "quote > 0");

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap(
            outerKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(100e6),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );

        assertEq(userUsdcBefore - IERC20(USDC).balanceOf(USER), 100e6, "user paid 100 USDC");
        assertEq(USER.balance - userEthBefore, quote, "user received quoted ETH");
        assertEq(int256(delta.amount1()), -int256(100e6), "delta amount1 = -input");
        assertEq(int256(delta.amount0()), int256(quote), "delta amount0 = +output");

        (uint160 innerPriceAfter,,,) = manager.getSlot0(innerPoolId);
        assertTrue(innerPriceAfter != innerPriceBefore, "inner price moved = swap routed through inner pool");

        assertEq(address(hook).balance, 0, "hook ETH balance zero");
        assertEq(IERC20(fwEth).balanceOf(address(hook)), 0, "hook fwEth zero");
        assertEq(IERC20(fwUsdc).balanceOf(address(hook)), 0, "hook fwUsdc zero");
    }

    function _bootstrapInnerPool(PoolKey memory iKey) internal {
        vm.deal(address(this), 100 ether);
        _wrapEthToFwEth(50 ether);

        deal(USDC, address(this), 200_000e6);
        IERC20(USDC).approve(fwUsdc, 200_000e6);
        IFewWrappedToken(fwUsdc).wrap(200_000e6);

        IERC20(fwEth).approve(address(manager), type(uint256).max);
        IERC20(fwUsdc).approve(address(manager), type(uint256).max);

        uint160 sqrtPrice = _computeInnerSqrtPrice();
        manager.initialize(iKey, sqrtPrice);

        manager.unlock(abi.encode(true));
    }

    function _wrapEthToFwEth(uint256 amount) internal {
        IWETH9(WETH).deposit{value: amount}();
        IERC20(WETH).approve(fwEth, amount);
        IFewWrappedToken(fwEth).wrap(amount);
    }

    function _computeInnerSqrtPrice() internal view returns (uint160) {
        // 1 ETH ≈ 2000 USDC.  fwETH = 18 dec, fwUSDC = 6 dec.
        // sqrtPriceX96 = sqrt(price * 2^192) where price = token1_raw / token0_raw.
        if (innerEthIsToken0) {
            // token0 = fwETH (18), token1 = fwUSDC (6)
            // price = 2000e6 / 1e18
            uint256 val = (uint256(2000e6) << 192) / 1e18;
            return _clampSqrtPrice(_sqrt(val));
        } else {
            // token0 = fwUSDC (6), token1 = fwETH (18)
            // price = 1e18 / 2000e6
            uint256 val = (uint256(1e18) << 192) / uint256(2000e6);
            return _clampSqrtPrice(_sqrt(val));
        }
    }

    function _clampSqrtPrice(uint256 v) internal pure returns (uint160) {
        if (v <= uint256(TickMath.MIN_SQRT_PRICE)) return uint160(uint256(TickMath.MIN_SQRT_PRICE) + 1);
        if (v >= uint256(TickMath.MAX_SQRT_PRICE)) return uint160(uint256(TickMath.MAX_SQRT_PRICE) - 1);
        return uint160(v);
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        bool isLiquidity = abi.decode(data, (bool));
        if (isLiquidity) {
            return _addLiquidityCallback();
        }
        return bytes("");
    }

    function _addLiquidityCallback() internal returns (bytes memory) {
        PoolKey memory iKey = PoolKey({
            currency0: Currency.wrap(innerEthIsToken0 ? fwEth : fwUsdc),
            currency1: Currency.wrap(innerEthIsToken0 ? fwUsdc : fwEth),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        (BalanceDelta delta,) = manager.modifyLiquidity(
            iKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 2e15,
                salt: bytes32(0)
            }),
            bytes("")
        );

        _settleDelta(iKey.currency0, delta.amount0());
        _settleDelta(iKey.currency1, delta.amount1());

        return abi.encode(true);
    }

    function _settleDelta(Currency currency, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
                manager.settle();
            }
        }
    }

    receive() external payable {}
}
