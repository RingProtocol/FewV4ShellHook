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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {FewV4ShellHook} from "../../src/FewV4ShellHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";

/// @dev The v4-core PoolSwapTest helper ABI-decodes ERC20 return values and therefore cannot settle
///      legacy USDT. This router uses SafeERC20, matching production-router token compatibility.
contract ShellSafeSwapRouter is IUnlockCallback {
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

/// @notice Mainnet proof that the real fwUSDC/fwUSDT v4 LP can settle an origin USDC/USDT shell,
///         while the existing fwUSDC/USDC and USDT/fwUSDT wrapper-pool state remains untouched.
contract FewV4ShellHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 25_833_244;
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address internal constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant FW_USDC = 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429;
    address internal constant FW_USDT = 0xef87f4608e601E8564800265AeE1c1FfaDF73283;
    address internal constant USER = address(0xBEEF);

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant EXACT_INPUT = 1e6;
    uint256 internal constant EXACT_OUTPUT = 8e5;

    PoolId internal constant INNER_POOL_ID =
        PoolId.wrap(0x6199c1a871328a693bbc9cd80a7e4874a4a7e2ebc862b51fa04bb6b587dbac47);
    PoolId internal constant USDC_WRAPPER_POOL_ID =
        PoolId.wrap(0x5837e6b4fd4b8193f2f7a8b4490c0f154344bb9a52b36a885578ff6d3193fc47);
    PoolId internal constant USDT_WRAPPER_POOL_ID =
        PoolId.wrap(0x7db868544c8f7f6ddb107c7749c94f03c9e0155f2138aef3f8a020e4a469d95a);

    bool internal forked;
    IPoolManager internal manager;
    FewV4ShellHook internal hook;
    ShellSafeSwapRouter internal swapRouter;
    PoolKey internal outerKey;
    PoolId internal outerPoolId;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;

        manager = IPoolManager(V4_POOL_MANAGER);
        (uint160 innerPrice,,,) = manager.getSlot0(INNER_POOL_ID);
        assertGt(innerPrice, 0, "real inner initialized");
        assertGt(manager.getLiquidity(INNER_POOL_ID), 0, "real inner active liquidity");

        PoolId[] memory allowedInnerPools = new PoolId[](1);
        allowedInnerPools[0] = INNER_POOL_ID;
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs =
            abi.encode(manager, IFewFactory(FEW_FACTORY), IV4Quoter(V4_QUOTER), allowedInnerPools);
        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV4ShellHook).creationCode, constructorArgs);
        hook =
            new FewV4ShellHook{salt: salt}(manager, IFewFactory(FEW_FACTORY), IV4Quoter(V4_QUOTER), allowedInnerPools);
        assertEq(address(hook), mined);

        outerKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(USDT),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        outerPoolId = outerKey.toId();
        (address few0, address few1, PoolId innerPoolId,, uint160 recommendedPrice) =
            hook.previewRoute(USDC, USDT, FEE, TICK_SPACING);
        assertEq(few0, FW_USDC);
        assertEq(few1, FW_USDT);
        assertEq(PoolId.unwrap(innerPoolId), PoolId.unwrap(INNER_POOL_ID));
        manager.initialize(outerKey, recommendedPrice);

        swapRouter = new ShellSafeSwapRouter(manager);
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

    function test_realExactInput_usdcToUsdt_quoteEqualsExecution() public requireFork {
        _assertExactInput(true);
    }

    function test_realExactInput_usdtToUsdc_quoteEqualsExecution() public requireFork {
        _assertExactInput(false);
    }

    function test_realExactOutput_usdcToUsdt_quoteEqualsExecution() public requireFork {
        _assertExactOutput(true);
    }

    function test_realExactOutput_usdtToUsdc_quoteEqualsExecution() public requireFork {
        _assertExactOutput(false);
    }

    function _assertExactInput(bool zeroForOne) internal {
        _Snapshot memory beforeState = _snapshot();
        uint256 quote = hook.quote(zeroForOne, -int256(EXACT_INPUT), outerPoolId);
        _assertQuoteRollback(beforeState);

        address input = zeroForOne ? USDC : USDT;
        address output = zeroForOne ? USDT : USDC;
        uint256 inputBefore = IERC20(input).balanceOf(USER);
        uint256 outputBefore = IERC20(output).balanceOf(USER);
        BalanceDelta delta = _swapAsUser(zeroForOne, -int256(EXACT_INPUT));

        assertEq(inputBefore - IERC20(input).balanceOf(USER), EXACT_INPUT);
        assertEq(IERC20(output).balanceOf(USER) - outputBefore, quote);
        assertEq(int256(zeroForOne ? delta.amount0() : delta.amount1()), -int256(EXACT_INPUT));
        assertEq(int256(zeroForOne ? delta.amount1() : delta.amount0()), int256(quote));
        _assertPostSwap(beforeState);
    }

    function _assertExactOutput(bool zeroForOne) internal {
        _Snapshot memory beforeState = _snapshot();
        uint256 quote = hook.quote(zeroForOne, int256(EXACT_OUTPUT), outerPoolId);
        _assertQuoteRollback(beforeState);

        address input = zeroForOne ? USDC : USDT;
        address output = zeroForOne ? USDT : USDC;
        uint256 inputBefore = IERC20(input).balanceOf(USER);
        uint256 outputBefore = IERC20(output).balanceOf(USER);
        BalanceDelta delta = _swapAsUser(zeroForOne, int256(EXACT_OUTPUT));

        assertEq(inputBefore - IERC20(input).balanceOf(USER), quote);
        assertEq(IERC20(output).balanceOf(USER) - outputBefore, EXACT_OUTPUT);
        assertEq(int256(zeroForOne ? delta.amount0() : delta.amount1()), -int256(quote));
        assertEq(int256(zeroForOne ? delta.amount1() : delta.amount0()), int256(EXACT_OUTPUT));
        _assertPostSwap(beforeState);
    }

    function _swapAsUser(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        vm.prank(USER);
        return swapRouter.swap(
            outerKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
    }

    struct _Snapshot {
        uint160 outerPrice;
        uint160 innerPrice;
        uint160 usdcWrapperPrice;
        uint160 usdtWrapperPrice;
        uint128 outerLiquidity;
        uint128 usdcWrapperLiquidity;
        uint128 usdtWrapperLiquidity;
        uint256 managerUsdc;
        uint256 managerUsdt;
    }

    function _snapshot() internal view returns (_Snapshot memory state) {
        (state.outerPrice,,,) = manager.getSlot0(outerPoolId);
        (state.innerPrice,,,) = manager.getSlot0(INNER_POOL_ID);
        (state.usdcWrapperPrice,,,) = manager.getSlot0(USDC_WRAPPER_POOL_ID);
        (state.usdtWrapperPrice,,,) = manager.getSlot0(USDT_WRAPPER_POOL_ID);
        state.outerLiquidity = manager.getLiquidity(outerPoolId);
        state.usdcWrapperLiquidity = manager.getLiquidity(USDC_WRAPPER_POOL_ID);
        state.usdtWrapperLiquidity = manager.getLiquidity(USDT_WRAPPER_POOL_ID);
        state.managerUsdc = IERC20(USDC).balanceOf(address(manager));
        state.managerUsdt = IERC20(USDT).balanceOf(address(manager));
    }

    function _assertQuoteRollback(_Snapshot memory beforeState) internal view {
        _Snapshot memory afterQuote = _snapshot();
        assertEq(afterQuote.outerPrice, beforeState.outerPrice, "quote outer price");
        assertEq(afterQuote.innerPrice, beforeState.innerPrice, "quote inner price");
        assertEq(afterQuote.managerUsdc, beforeState.managerUsdc, "quote manager USDC");
        assertEq(afterQuote.managerUsdt, beforeState.managerUsdt, "quote manager USDT");
        _assertWrapperPoolsUnchanged(beforeState, afterQuote);
    }

    function _assertPostSwap(_Snapshot memory beforeState) internal view {
        _Snapshot memory afterState = _snapshot();
        assertEq(afterState.outerPrice, beforeState.outerPrice, "outer price unchanged");
        assertEq(afterState.outerLiquidity, 0, "outer liquidity zero");
        assertTrue(afterState.innerPrice != beforeState.innerPrice, "real inner price moved");
        assertEq(afterState.managerUsdc, beforeState.managerUsdc, "manager USDC inventory restored");
        assertEq(afterState.managerUsdt, beforeState.managerUsdt, "manager USDT inventory restored");
        _assertWrapperPoolsUnchanged(beforeState, afterState);
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook USDC");
        assertEq(IERC20(USDT).balanceOf(address(hook)), 0, "hook USDT");
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "hook fwUSDC");
        assertEq(IERC20(FW_USDT).balanceOf(address(hook)), 0, "hook fwUSDT");
    }

    function _assertWrapperPoolsUnchanged(_Snapshot memory beforeState, _Snapshot memory afterState) internal pure {
        assertEq(afterState.usdcWrapperPrice, beforeState.usdcWrapperPrice, "USDC wrapper price");
        assertEq(afterState.usdtWrapperPrice, beforeState.usdtWrapperPrice, "USDT wrapper price");
        assertEq(afterState.usdcWrapperLiquidity, beforeState.usdcWrapperLiquidity, "USDC wrapper liquidity");
        assertEq(afterState.usdtWrapperLiquidity, beforeState.usdtWrapperLiquidity, "USDT wrapper liquidity");
    }
}
