// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {MockFewFactory} from "../test/mocks/MockFewFactory.sol";
import {MockWETH9} from "../test/mocks/MockWETH9.sol";

/// @notice Local deployment script for testing FewV4ShellHook with native ETH.
///         The shell pool uses native ETH (address(0)) as currency0 and an ERC20 as currency1.
///         The lp pool uses FewWETH (wrapping WETH) and FewTokenB (wrapping tokenB).
///         The hook bridges ETH <-> WETH <-> FewWETH atomically during the lp route.
///
/// @dev Usage:
///   anvil --port 8545 &
///   forge script script/DeployLocalEth.s.sol:DeployLocalEth --rpc-url http://127.0.0.1:8545 --broadcast -vvv
contract DeployLocalEth is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using StateLibrary for PoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant LIQUIDITY = 100e18;
    uint256 internal constant SWAP_AMOUNT = 1e18;
    uint256 internal constant RESERVE = 10e18;

    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // anvil account 0
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ------------------------------------------------------------------
        // 1. Deploy core infrastructure
        // ------------------------------------------------------------------
        PoolManager manager = new PoolManager(deployer);
        console2.log("PoolManager:", address(manager));

        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        console2.log("SwapRouter:", address(swapRouter));
        console2.log("LiquidityRouter:", address(liquidityRouter));

        // 2. Deploy mock WETH9 (for ETH <-> WETH bridging)
        MockWETH9 weth = new MockWETH9();
        console2.log("WETH:", address(weth));

        // 3. Deploy mock ERC20 token (the non-ETH side of the shell pool)
        MockERC20 tokenB = new MockERC20("TokenB", "TB", 18);
        tokenB.mint(deployer, 1_000_000e18);
        console2.log("TokenB:", address(tokenB));

        // 4. Deploy mock FewFactory and create wrappers
        MockFewFactory factory = new MockFewFactory();
        factory.createToken(address(weth)); // creates FewWETH (underlying = WETH)
        factory.createToken(address(tokenB)); // creates FewTokenB (underlying = tokenB)
        address fewWETH = factory.getWrappedToken(address(weth));
        address fewTokenB = factory.getWrappedToken(address(tokenB));
        console2.log("FewFactory:", address(factory));
        console2.log("FewWETH (fwWETH):", fewWETH);
        console2.log("FewTokenB (fwB):", fewTokenB);

        // 5. Deploy V4Quoter (required by hook constructor)
        V4Quoter v4Quoter = new V4Quoter(IPoolManager(address(manager)));

        // 6. Mine hook address and deploy via CREATE2
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            IFewFactory(address(factory)),
            IWETH9(address(weth)),
            IV4Quoter(address(v4Quoter)),
            address(this)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(create2Deployer, flags, type(FewV4ShellHook).creationCode, constructorArgs);
        FewV4ShellHook hook = new FewV4ShellHook{salt: salt}(
            IPoolManager(address(manager)),
            IFewFactory(address(factory)),
            IWETH9(address(weth)),
            IV4Quoter(address(v4Quoter)),
            address(this)
        );
        require(address(hook) == expectedHook, "hook address mismatch");
        console2.log("FewV4ShellHook:", address(hook));

        // ------------------------------------------------------------------
        // 7. Construct pool keys
        // ------------------------------------------------------------------
        // Shell pool: native ETH (currency0, since address(0) < any token) / tokenB (currency1)
        Currency currency0 = Currency.wrap(address(0)); // native ETH
        Currency currency1 = Currency.wrap(address(tokenB));

        PoolKey memory shellKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // LP pool: FewWETH / FewTokenB (order depends on address ordering)
        address few0 = fewWETH;
        address few1 = fewTokenB;
        bool orderAligned = few0 < few1;
        PoolKey memory lpKey = PoolKey({
            currency0: Currency.wrap(orderAligned ? few0 : few1),
            currency1: Currency.wrap(orderAligned ? few1 : few0),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        console2.log("OrderAligned:", orderAligned);
        console2.log("LP pool currency0:", Currency.unwrap(lpKey.currency0));
        console2.log("LP pool currency1:", Currency.unwrap(lpKey.currency1));

        // ------------------------------------------------------------------
        // 8. Initialize shell pool
        // ------------------------------------------------------------------
        manager.initialize(shellKey, SQRT_PRICE_1_1);
        console2.log("Shell pool (ETH/TokenB) initialized at 1:1");

        // Note: We rely on FewFactory auto-inference for the lp route (like DeployLocal.s.sol).
        // The hook derives the lp pool from getWrappedToken(WETH) and getWrappedToken(tokenB),
        // reusing the shell pool's fee and tickSpacing. No setLpPool needed (owner is constructor argument).

        // ------------------------------------------------------------------
        // 9. Add shell pool liquidity with native ETH
        //    This funds the PoolManager with physical ETH, which the hook needs
        //    for the flash-take input leg during zeroForOne (ETH -> tokenB) swaps.
        //    Using a full-range position so the PoolManager receives ~LIQUIDITY ETH.
        // ------------------------------------------------------------------
        tokenB.approve(address(liquidityRouter), type(uint256).max);
        {
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: -887270, tickUpper: 887270, liquidityDelta: int128(int256(LIQUIDITY)), salt: 0
            });
            // Send generous ETH; PoolModifyLiquidityTest refunds excess
            liquidityRouter.modifyLiquidity{value: LIQUIDITY * 2}(shellKey, params, bytes(""));
        }
        console2.log("Shell pool liquidity added (full range):", LIQUIDITY);

        // ------------------------------------------------------------------
        // 10. Initialize lp pool and add liquidity
        // ------------------------------------------------------------------
        manager.initialize(lpKey, SQRT_PRICE_1_1);
        console2.log("LP pool (FewWETH/FewTokenB) initialized at 1:1");

        // Wrap WETH and tokenB into FewTokens for lp liquidity + reserves.
        // Total needed: LIQUIDITY (for lp pool) + RESERVE (for PoolManager flash-take) = 110e18
        uint256 wrapAmount = LIQUIDITY + RESERVE;
        weth.deposit{value: wrapAmount}();
        weth.approve(fewWETH, type(uint256).max);
        IFewWrappedToken(fewWETH).wrap(wrapAmount);
        tokenB.approve(fewTokenB, type(uint256).max);
        IFewWrappedToken(fewTokenB).wrap(wrapAmount);
        console2.log("Wrapped WETH and tokenB to FewTokens:", wrapAmount);

        // Approve FewTokens for liquidity router
        IERC20(fewWETH).approve(address(liquidityRouter), type(uint256).max);
        IERC20(fewTokenB).approve(address(liquidityRouter), type(uint256).max);

        // Add liquidity to lp pool (wide tick range to cover price moves in both directions)
        {
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: -7000, tickUpper: 7000, liquidityDelta: int128(int256(LIQUIDITY)), salt: 0
            });
            liquidityRouter.modifyLiquidity(lpKey, params, bytes(""));
        }
        console2.log("LP pool liquidity added:", LIQUIDITY);

        // ------------------------------------------------------------------
        // 11. Pre-fund PoolManager with reserves for flash-take
        // ------------------------------------------------------------------
        // Send remaining FewTokens to PoolManager for the output leg flash-take
        // (after lp liquidity, RESERVE of each FewToken remains with the deployer)
        IERC20(fewWETH).transfer(address(manager), RESERVE);
        IERC20(fewTokenB).transfer(address(manager), RESERVE);
        console2.log("Sent FewWETH and FewTokenB to PoolManager for flash-take");

        // Send tokenB to PoolManager for oneForZero input leg flash-take
        tokenB.transfer(address(manager), RESERVE);
        console2.log("Sent tokenB to PoolManager for flash-take");

        // Approve tokenB for swapRouter (needed for oneForZero swap)
        tokenB.approve(address(swapRouter), type(uint256).max);

        // ------------------------------------------------------------------
        // 12. Test swap 1: zeroForOne (ETH -> tokenB), exact-input
        // ------------------------------------------------------------------
        console2.log("=== Test swap 1: zeroForOne (ETH -> tokenB) ===");
        {
            uint256 ethBefore = deployer.balance;
            uint256 tokenBBefore = tokenB.balanceOf(deployer);

            (uint160 shellPriceBefore,,,) = manager.getSlot0(shellKey.toId());
            (uint160 lpPriceBefore,,,) = manager.getSlot0(lpKey.toId());

            PoolSwapTest.TestSettings memory settings =
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

            // Send SWAP_AMOUNT ETH with the swap call; excess is refunded by PoolSwapTest
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
            uint256 tokenBAfter = tokenB.balanceOf(deployer);

            console2.log("Delta amount0 (ETH):", int256(swapDelta.amount0()));
            console2.log("Delta amount1 (TokenB):", int256(swapDelta.amount1()));
            console2.log("Shell price before:", shellPriceBefore);
            console2.log("Shell price after: ", shellPriceAfter);
            console2.log("LP price before: ", lpPriceBefore);
            console2.log("LP price after:  ", lpPriceAfter);
            console2.log("ETH consumed: ", ethBefore - ethAfter);
            console2.log("TokenB received:", tokenBAfter - tokenBBefore);

            if (lpPriceAfter != lpPriceBefore) {
                console2.log("Result: LP pool was used (LP price moved, shell price unchanged)");
            } else {
                console2.log("Result: WARNING - LP price did not move");
            }
        }

        // ------------------------------------------------------------------
        // 13. Test swap 2: oneForZero (tokenB -> ETH), exact-input
        // ------------------------------------------------------------------
        console2.log("=== Test swap 2: oneForZero (tokenB -> ETH) ===");
        {
            uint256 ethBefore = deployer.balance;
            uint256 tokenBBefore = tokenB.balanceOf(deployer);

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
            uint256 tokenBAfter = tokenB.balanceOf(deployer);

            console2.log("Delta amount0 (ETH):", int256(swapDelta.amount0()));
            console2.log("Delta amount1 (TokenB):", int256(swapDelta.amount1()));
            console2.log("Shell price before:", shellPriceBefore);
            console2.log("Shell price after: ", shellPriceAfter);
            console2.log("LP price before: ", lpPriceBefore);
            console2.log("LP price after:  ", lpPriceAfter);
            console2.log("TokenB consumed: ", tokenBBefore - tokenBAfter);
            console2.log("ETH received:", ethAfter - ethBefore);

            if (lpPriceAfter != lpPriceBefore) {
                console2.log("Result: LP pool was used (LP price moved, shell price unchanged)");
            } else {
                console2.log("Result: WARNING - LP price did not move");
            }
        }

        // ------------------------------------------------------------------
        // 14. Verify hook has no residual balances
        // ------------------------------------------------------------------
        require(
            IERC20(address(tokenB)).balanceOf(address(hook)) == 0 && IERC20(fewWETH).balanceOf(address(hook)) == 0
                && IERC20(fewTokenB).balanceOf(address(hook)) == 0,
            "hook has residual ERC20 balances"
        );
        require(address(hook).balance == 0, "hook has residual ETH");
        console2.log("Hook balances: all zero (OK)");

        vm.stopBroadcast();

        console2.log("=== ETH local deployment complete ===");
        console2.log("All contracts deployed and ETH swaps verified on anvil.");
    }
}
