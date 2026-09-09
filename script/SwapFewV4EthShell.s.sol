// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, BalanceDelta} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Simple ETH-aware swap router for FewV4ShellHook outer pools.
/// @dev Handles native ETH in settle and take. Caller must approve ERC20 before TOKEN -> ETH.
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

/// @notice Direct swap on a FewV4EthShell outer pool.
///
/// Required env:
///   V4_POOL_MANAGER, HOOK, TOKEN, AMOUNT_IN, ETH_PRIVATE_KEY
///
/// Optional:
///   POOL_FEE=3000, TICK_SPACING=60, ZERO_FOR_ONE=true
///
/// ZERO_FOR_ONE=true  => ETH -> TOKEN (send ETH)
/// ZERO_FOR_ONE=false => TOKEN -> ETH (approve TOKEN)
contract SwapFewV4EthShell is Script {
    using CurrencyLibrary for Currency;

    function run() external {
        address poolManagerAddress = vm.envAddress("V4_POOL_MANAGER");
        address hookAddress = vm.envAddress("HOOK");
        address token = vm.envAddress("TOKEN");
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(60)));
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);
        uint256 amountIn = vm.envUint("AMOUNT_IN");

        IPoolManager manager = IPoolManager(poolManagerAddress);

        PoolKey memory outerKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress)
        });

        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        console2.log("=== SwapFewV4EthShell preflight ===");
        console2.log("router will be deployed in broadcast");
        console2.log("token:          ", token);
        console2.log("hook:           ", hookAddress);
        console2.log("zeroForOne:     ", zeroForOne ? "ETH -> TOKEN" : "TOKEN -> ETH");
        console2.log("amountIn:       ", amountIn);
        console2.log("sqrtPriceLimit: ", sqrtPriceLimitX96);

        vm.startBroadcast();

        ShellEthSwapRouter router = new ShellEthSwapRouter(manager);

        if (!zeroForOne) {
            IERC20(token).approve(address(router), amountIn);
        }

        BalanceDelta delta;
        if (zeroForOne) {
            delta = router.swap{value: amountIn}(outerKey, params);
        } else {
            delta = router.swap(outerKey, params);
        }

        vm.stopBroadcast();

        console2.log("=== SwapFewV4EthShell result ===");
        console2.log("router:         ", address(router));
        console2.log("amount0 delta:  ", int256(delta.amount0()));
        console2.log("amount1 delta:  ", int256(delta.amount1()));
    }
}
