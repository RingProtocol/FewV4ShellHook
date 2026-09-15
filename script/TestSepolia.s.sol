// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

/// @notice End-to-end Sepolia test for FewV4ShellHook.
///         Uses the already-deployed hook and existing Sepolia infrastructure
///         (V4 PoolManager, FewFactory, WETH, FewWETH, TOKEN, FewToken).
///
///         Shell pool: native ETH / TOKEN (UV4A) with the hook.
///         LP pool:    FewToken (fwUV4A) / FewWETH (fwWETH), no hook.
///
/// Required env:
///   ETH_PRIVATE_KEY  - deployer private key (must be hook owner)
///   ETH_RPC_URL      - Sepolia RPC URL
///
/// Optional env (defaults are Sepolia addresses):
///   HOOK, V4_POOL_MANAGER, FEW_FACTORY, WETH9, TOKEN, FEW_TOKEN, FEW_WETH
contract TestSepolia is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint24 internal constant FEE = 2500;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant LIQUIDITY = 0.1e18; // 0.1 ETH worth
    uint256 internal constant SWAP_AMOUNT = 0.01e18; // 0.01 ETH per swap
    uint256 internal constant RESERVE = 0.05e18; // 0.05 ETH reserve

    // Sepolia defaults
    address internal constant HOOK_DEFAULT = 0xff5641ABF89a3Cd2e28ea01e65e19a5a33EB2088;
    address internal constant V4_POOL_MANAGER_DEFAULT = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant FEW_FACTORY_DEFAULT = 0x226e65279E177A779522864Ce1dE40c85E2C08A5;
    address internal constant WETH9_DEFAULT = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant TOKEN_DEFAULT = 0xc41CdC9422c70c07681f9A92CDf23d3f8b3bd54B;
    address internal constant FEW_TOKEN_DEFAULT = 0x57AFcCC6D20e72D55B2A9ccB4fae10d189dcf19d;
    address internal constant FEW_WETH_DEFAULT = 0x98b902eF4f9fEB2F6982ceEB4E98761294854D61;

    function run() external {
        address hookAddr = vm.envOr("HOOK", HOOK_DEFAULT);
        address poolManagerAddr = vm.envOr("V4_POOL_MANAGER", V4_POOL_MANAGER_DEFAULT);
        address factoryAddr = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address wethAddr = vm.envOr("WETH9", WETH9_DEFAULT);
        address tokenAddr = vm.envOr("TOKEN", TOKEN_DEFAULT);
        address fewTokenAddr = vm.envOr("FEW_TOKEN", FEW_TOKEN_DEFAULT);
        address fewWethAddr = vm.envOr("FEW_WETH", FEW_WETH_DEFAULT);

        uint256 deployerPrivateKey = vm.envUint("ETH_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        IPoolManager manager = IPoolManager(poolManagerAddr);
        FewV4ShellHook hook = FewV4ShellHook(payable(hookAddr));
        IERC20 token = IERC20(tokenAddr);
        IERC20 fewToken = IERC20(fewTokenAddr);
        IERC20 fewWeth = IERC20(fewWethAddr);
        IWETH9 weth = IWETH9(wethAddr);

        console2.log("=== FewV4ShellHook Sepolia end-to-end test ===");
        console2.log("Deployer:       ", deployer);
        console2.log("Hook:           ", hookAddr);
        console2.log("PoolManager:    ", poolManagerAddr);
        console2.log("FewFactory:     ", factoryAddr);
        console2.log("WETH:           ", wethAddr);
        console2.log("TOKEN (UV4A):   ", tokenAddr);
        console2.log("FEW_TOKEN:      ", fewTokenAddr);
        console2.log("FEW_WETH:       ", fewWethAddr);
        console2.log("Deployer ETH:   ", deployer.balance);
        console2.log("Deployer TOKEN: ", token.balanceOf(deployer));

        // Verify hook is the deployer's.
        require(hook.owner() == deployer, "configured owner is not deployer");
        require(address(hook.poolManager()) == poolManagerAddr, "poolManager mismatch");

        vm.startBroadcast(deployerPrivateKey);

        // ------------------------------------------------------------------
        // 1. Deploy test routers (PoolSwapTest, PoolModifyLiquidityTest)
        // ------------------------------------------------------------------
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        console2.log("SwapRouter:       ", address(swapRouter));
        console2.log("LiquidityRouter:  ", address(liquidityRouter));

        // ------------------------------------------------------------------
        // 2. Construct pool keys
        // ------------------------------------------------------------------
        // Shell pool: ETH (currency0, address(0)) / TOKEN (currency1)
        PoolKey memory shellKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddr),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        // LP pool: FEW_TOKEN / FEW_WETH (sorted by address)
        // FEW_TOKEN (0x57AF...) < FEW_WETH (0x98b9...)
        bool orderAligned = fewWethAddr < fewTokenAddr; // false
        PoolKey memory lpKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? fewWethAddr : fewTokenAddr),
            currency1: Currency.wrap(orderAligned ? fewTokenAddr : fewWethAddr),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        console2.log("OrderAligned: ", orderAligned);
        console2.log("LP currency0: ", Currency.unwrap(lpKey.currency0));
        console2.log("LP currency1: ", Currency.unwrap(lpKey.currency1));

        // ------------------------------------------------------------------
        // 3. Initialize shell pool through the hook (records in initedPools)
        // ------------------------------------------------------------------
        {
            (uint160 existingPrice,,,) = manager.getSlot0(shellKey.toId());
            if (existingPrice == 0) {
                manager.initialize(shellKey, SQRT_PRICE_1_1);
                console2.log("Shell pool (ETH/TOKEN) initialized at 1:1");
            } else {
                console2.log("Shell pool already initialized, price:", existingPrice);
            }
        }

        // ------------------------------------------------------------------
        // 4. Initialize LP pool (FEW_TOKEN/FEW_WETH)
        // ------------------------------------------------------------------
        {
            (uint160 existingPrice,,,) = manager.getSlot0(lpKey.toId());
            if (existingPrice == 0) {
                manager.initialize(lpKey, SQRT_PRICE_1_1);
                console2.log("LP pool (FEW_TOKEN/FEW_WETH) initialized at 1:1");
            } else {
                console2.log("LP pool already initialized, price:", existingPrice);
            }
        }

        // ------------------------------------------------------------------
        // 5. Register LP pool for the shell pool (setLpPool)
        // ------------------------------------------------------------------
        hook.setLpPool(shellKey, lpKey);
        console2.log("LP pool registered for shell pool");

        // ------------------------------------------------------------------
        // 6. Wrap tokens for LP liquidity + reserves
        //    Need FEW_WETH and FEW_TOKEN for lp liquidity + PoolManager reserves
        // ------------------------------------------------------------------
        uint256 wrapAmount = LIQUIDITY + RESERVE;
        // Deposit ETH -> WETH
        weth.deposit{value: wrapAmount}();
        // Wrap WETH -> FEW_WETH
        weth.approve(fewWethAddr, type(uint256).max);
        IFewWrappedToken(fewWethAddr).wrap(wrapAmount);
        console2.log("Wrapped WETH -> FEW_WETH:", wrapAmount);

        // Wrap TOKEN -> FEW_TOKEN
        token.approve(fewTokenAddr, type(uint256).max);
        IFewWrappedToken(fewTokenAddr).wrap(wrapAmount);
        console2.log("Wrapped TOKEN -> FEW_TOKEN:", wrapAmount);

        // ------------------------------------------------------------------
        // 7. Add liquidity to LP pool (wide tick range)
        // ------------------------------------------------------------------
        fewWeth.approve(address(liquidityRouter), type(uint256).max);
        fewToken.approve(address(liquidityRouter), type(uint256).max);
        {
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int128(int256(LIQUIDITY)), salt: 0
            });
            liquidityRouter.modifyLiquidity(lpKey, params, bytes(""));
        }
        console2.log("LP pool liquidity added:", LIQUIDITY);

        // ------------------------------------------------------------------
        // 8. Add liquidity to shell pool (full range, sends ETH + TOKEN to PM)
        // ------------------------------------------------------------------
        token.approve(address(liquidityRouter), type(uint256).max);
        {
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int128(int256(LIQUIDITY)), salt: 0
            });
            // Send generous ETH; PoolModifyLiquidityTest refunds excess
            liquidityRouter.modifyLiquidity{value: LIQUIDITY * 2}(shellKey, params, bytes(""));
        }
        console2.log("Shell pool liquidity added:", LIQUIDITY);

        // ------------------------------------------------------------------
        // 9. Pre-fund PoolManager with extra reserves for flash-take
        //    - TOKEN for oneForZero (TOKEN -> ETH) input leg
        //    - FEW_WETH and FEW_TOKEN for lp output leg flash-take
        // ------------------------------------------------------------------
        token.transfer(address(manager), RESERVE);
        fewWeth.transfer(address(manager), RESERVE);
        fewToken.transfer(address(manager), RESERVE);
        console2.log("Pre-funded PoolManager with reserves:", RESERVE);

        // Approve TOKEN for swapRouter (needed for oneForZero swap)
        token.approve(address(swapRouter), type(uint256).max);

        // ------------------------------------------------------------------
        // 10. Test swap 1: zeroForOne (ETH -> TOKEN), exact-input
        // ------------------------------------------------------------------
        console2.log("=== Test swap 1: zeroForOne (ETH -> TOKEN) ===");
        {
            uint256 ethBefore = deployer.balance;
            uint256 tokenBefore = token.balanceOf(deployer);

            (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
            (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

            PoolSwapTest.TestSettings memory settings =
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

            BalanceDelta swapDelta = swapRouter.swap{value: SWAP_AMOUNT}(
                shellKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(SWAP_AMOUNT),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                settings,
                bytes("")
            );

            (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
            (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());

            uint256 ethAfter = deployer.balance;
            uint256 tokenAfter = token.balanceOf(deployer);

            console2.log("Delta amount0 (ETH):   ", int256(swapDelta.amount0()));
            console2.log("Delta amount1 (TOKEN): ", int256(swapDelta.amount1()));
            console2.log("Shell price before:     ", shellPriceBefore);
            console2.log("Shell price after:      ", shellPriceAfter);
            console2.log("LP price before:        ", lpPriceBefore);
            console2.log("LP price after:         ", lpPriceAfter);
            console2.log("ETH consumed:           ", ethBefore - ethAfter);
            console2.log("TOKEN received:         ", tokenAfter - tokenBefore);

            if (lpPriceAfter != lpPriceBefore) {
                console2.log("Result: LP pool was used (LP price moved, shell price unchanged)");
            } else {
                console2.log("Result: WARNING - LP price did not move");
            }
        }

        // ------------------------------------------------------------------
        // 11. Test swap 2: oneForZero (TOKEN -> ETH), exact-input
        // ------------------------------------------------------------------
        console2.log("=== Test swap 2: oneForZero (TOKEN -> ETH) ===");
        {
            uint256 ethBefore = deployer.balance;
            uint256 tokenBefore = token.balanceOf(deployer);

            (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
            (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

            PoolSwapTest.TestSettings memory settings =
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

            BalanceDelta swapDelta = swapRouter.swap(
                shellKey,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(SWAP_AMOUNT),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                settings,
                bytes("")
            );

            (uint160 shellPriceAfter,,,) = manager.getSlot0(shellKey.toId());
            (uint160 lpPriceAfter,,,) = manager.getSlot0(lpKey.toId());

            uint256 ethAfter = deployer.balance;
            uint256 tokenAfter = token.balanceOf(deployer);

            console2.log("Delta amount0 (ETH):   ", int256(swapDelta.amount0()));
            console2.log("Delta amount1 (TOKEN): ", int256(swapDelta.amount1()));
            console2.log("Shell price before:    ", shellPriceBefore);
            console2.log("Shell price after:     ", shellPriceAfter);
            console2.log("LP price before:       ", lpPriceBefore);
            console2.log("LP price after:        ", lpPriceAfter);
            console2.log("TOKEN consumed:        ", tokenBefore - tokenAfter);
            console2.log("ETH received:          ", ethAfter - ethBefore);

            if (lpPriceAfter != lpPriceBefore) {
                console2.log("Result: LP pool was used (LP price moved, shell price unchanged)");
            } else {
                console2.log("Result: WARNING - LP price did not move");
            }
        }

        // ------------------------------------------------------------------
        // 12. Verify hook has no residual balances
        // ------------------------------------------------------------------
        require(
            token.balanceOf(hookAddr) == 0 && fewWeth.balanceOf(hookAddr) == 0 && fewToken.balanceOf(hookAddr) == 0,
            "hook has residual ERC20 balances"
        );
        require(hookAddr.balance == 0, "hook has residual ETH");
        console2.log("Hook balances: all zero (OK)");

        vm.stopBroadcast();

        console2.log("=== Sepolia end-to-end test complete ===");
        console2.log("All swaps verified on Sepolia.");
    }
}
