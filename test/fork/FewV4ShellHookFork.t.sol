// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV4ShellHook} from "../../src/FewV4ShellHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

/// @dev The v4-core PoolSwapTest helper ABI-decodes ERC20 return values and therefore cannot settle
///      legacy USDT. This router uses SafeERC20, matching production-router token compatibility.
contract SafeSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    struct CallbackData {
        address payer;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        CallbackData memory callback = abi.decode(data, (CallbackData));
        BalanceDelta delta = manager.swap(callback.key, callback.params, callback.hookData);
        _settle(callback.key.currency0, callback.payer, delta.amount0());
        _settle(callback.key.currency1, callback.payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 delta) internal {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(int256(delta)));
        }
    }
}

/// @notice Mainnet fork test: verifies routing through the real fwUSDC/fwUSDT v4 lp pool.
contract FewV4ShellHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 25_833_244;
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant FW_USDC = 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429;
    address internal constant FW_USDT = 0xef87f4608e601E8564800265AeE1c1FfaDF73283;
    address internal constant USER = address(0xBEEF);

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant SWAP_AMOUNT = 1e6;

    PoolId internal constant LP_POOL_ID =
        PoolId.wrap(0x6199c1a871328a693bbc9cd80a7e4874a4a7e2ebc862b51fa04bb6b587dbac47);

    bool internal forked;
    IPoolManager internal manager;
    FewV4ShellHook internal hook;
    SafeSwapRouter internal swapRouter;
    PoolKey internal shellKey;
    PoolId internal shellPoolId;
    PoolKey internal lpKey;
    bool internal orderAligned;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;

        manager = IPoolManager(V4_POOL_MANAGER);

        // Verify lp pool exists and has liquidity.
        (uint160 lpPrice,,,) = manager.getSlot0(LP_POOL_ID);
        assertGt(lpPrice, 0, "real lp pool initialized");
        assertGt(manager.getLiquidity(LP_POOL_ID), 0, "real lp pool active liquidity");

        // Deploy hook at mined address.
        V4Quoter v4Quoter = new V4Quoter(manager);
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory constructorArgs =
            abi.encode(manager, IFewFactory(FEW_FACTORY), IWETH9(WETH9), IV4Quoter(address(v4Quoter)));
        (address minedAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, constructorArgs);
        hook = new FewV4ShellHook{salt: salt}(manager, IFewFactory(FEW_FACTORY), IWETH9(WETH9), IV4Quoter(address(v4Quoter)));
        assertEq(address(hook), minedAddr);

        // Construct shell pool key (USDC < USDT).
        shellKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(USDT),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        shellPoolId = shellKey.toId();

        // Derive fb key the same way the hook does.
        address few0 = IFewFactory(FEW_FACTORY).getWrappedToken(USDC);
        address few1 = IFewFactory(FEW_FACTORY).getWrappedToken(USDT);
        orderAligned = few0 < few1;
        lpKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        // Initialize shell pool at the lp pool's price (must be initialized before setLpPool).
        (uint160 lpSqrtPrice,,,) = manager.getSlot0(LP_POOL_ID);
        uint160 shellInitPrice = orderAligned ? lpSqrtPrice : _invertPrice(lpSqrtPrice);
        manager.initialize(shellKey, shellInitPrice);

        // Register the lp pool explicitly (no auto-inference fallback).
        hook.setLpPool(shellKey, lpKey);

        swapRouter = new SafeSwapRouter(manager);
        deal(USDC, USER, 1_000e6);
        deal(USDT, USER, 1_000e6);
        vm.startPrank(USER);
        IERC20(USDC).forceApprove(address(swapRouter), type(uint256).max);
        IERC20(USDT).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    modifier requireFork() {
        if (!forked) vm.skip(true);
        _;
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    function test_realLpPoolDerivation() public requireFork {
        // The hook should derive the same lp pool ID as the known real pool.
        address few0 = IFewFactory(FEW_FACTORY).getWrappedToken(USDC);
        address few1 = IFewFactory(FEW_FACTORY).getWrappedToken(USDT);
        assertEq(few0, FW_USDC);
        assertEq(few1, FW_USDT);
        assertEq(PoolId.unwrap(lpKey.toId()), PoolId.unwrap(LP_POOL_ID));
    }

    function test_realSwapRoutesToLp() public requireFork {
        // lp is always the execution venue; shell price should not move.
        (uint160 shellPriceBefore,,,) = manager.getSlot0(shellPoolId);
        (uint160 lpPriceBefore,,,) = manager.getSlot0(LP_POOL_ID);

        _swapAsUser(true, -int256(SWAP_AMOUNT));

        (uint160 shellPriceAfter,,,) = manager.getSlot0(shellPoolId);
        (uint160 lpPriceAfter,,,) = manager.getSlot0(LP_POOL_ID);
        assertEq(shellPriceAfter, shellPriceBefore, "shell price unchanged");
        assertTrue(lpPriceAfter != lpPriceBefore, "lp price moved");
    }

    function test_realHookBalancesZeroAfterSwap() public requireFork {
        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));

        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook USDC");
        assertEq(IERC20(USDT).balanceOf(address(hook)), 0, "hook USDT");
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "hook fwUSDC");
        assertEq(IERC20(FW_USDT).balanceOf(address(hook)), 0, "hook fwUSDT");
    }

    function test_realPoolManagerInventoryRestored() public requireFork {
        uint256 managerUsdcBefore = IERC20(USDC).balanceOf(address(manager));
        uint256 managerUsdtBefore = IERC20(USDT).balanceOf(address(manager));

        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));

        // PoolManager inventory should be restored after settlement.
        assertEq(IERC20(USDC).balanceOf(address(manager)), managerUsdcBefore, "manager USDC restored");
        assertEq(IERC20(USDT).balanceOf(address(manager)), managerUsdtBefore, "manager USDT restored");
    }

    function test_realSwapBothDirections() public requireFork {
        // USDC -> USDT
        uint256 usdcBefore = IERC20(USDC).balanceOf(USER);
        uint256 usdtBefore = IERC20(USDT).balanceOf(USER);
        _swapAsUser(true, -int256(SWAP_AMOUNT), _fallbackData(1));
        assertEq(usdcBefore - IERC20(USDC).balanceOf(USER), SWAP_AMOUNT, "USDC consumed");
        assertGt(IERC20(USDT).balanceOf(USER), usdtBefore, "USDT received");

        // USDT -> USDC
        usdcBefore = IERC20(USDC).balanceOf(USER);
        usdtBefore = IERC20(USDT).balanceOf(USER);
        _swapAsUser(false, -int256(SWAP_AMOUNT), _fallbackData(1));
        assertEq(usdtBefore - IERC20(USDT).balanceOf(USER), SWAP_AMOUNT, "USDT consumed");
        assertGt(IERC20(USDC).balanceOf(USER), usdcBefore, "USDC received");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _swapAsUser(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return _swapAsUser(zeroForOne, amountSpecified, bytes(""));
    }

    function _swapAsUser(bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        vm.prank(USER);
        return swapRouter.swap(
            shellKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
    }

    function _fallbackData(uint256 amountLimit) internal view returns (bytes memory) {
        return abi.encode(block.timestamp + 1 hours, amountLimit);
    }

    function _invertPrice(uint160 sqrtPriceX96) internal pure returns (uint160) {
        uint256 inverse = (1 << 96) * (1 << 96) / sqrtPriceX96;
        return uint160(inverse);
    }
}
