// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";
import {FewV4NettingShellHook} from "../src/experimental/FewV4NettingShellHook.sol";
import {IAggregatorHook} from "../src/interfaces/IAggregatorHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";

interface IBenchUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IBenchPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Shared mainnet-fork constants for the anvil gas bench.
abstract contract BenchConstants {
    using CurrencyLibrary for Currency;

    // Mainnet addresses (same set used by test/fork/FewV4NettingShellHookFork.t.sol).
    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IFewFactory internal constant FEW_FACTORY = IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD);
    IWETH9 internal constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // forge script routes EOA CREATE2 through this proxy, so mining must use it as deployer.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

    // Shell pool shape used by the fork suite: fee 75 (dynamic), tickSpacing 1.
    uint24 internal constant SHELL_FEE = 75;
    int24 internal constant SHELL_TICK_SPACING = 1;

    // Claim inventory funded for the netting hook.
    uint256 internal constant CLAIM_WETH = 100 ether;
    uint256 internal constant CLAIM_WBTC = 20e8;
    uint256 internal constant CLAIM_ETH = 200 ether;

    // User working balances.
    uint256 internal constant USER_WETH = 50 ether;
    uint256 internal constant USER_WBTC = 10e8;

    function _poolId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolIdLibrary.toId(key);
    }

    function _shellKey(IHooks hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(WBTC),
            currency1: Currency.wrap(address(WETH)),
            fee: SHELL_FEE,
            tickSpacing: SHELL_TICK_SPACING,
            hooks: hook
        });
    }

    function _ethShellKey(IHooks hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(WBTC),
            fee: SHELL_FEE,
            tickSpacing: SHELL_TICK_SPACING,
            hooks: hook
        });
    }

    function _invertPrice(uint160 sqrtPriceX96) internal pure returns (uint160) {
        return uint160((uint256(1) << 192) / sqrtPriceX96);
    }
}

/// @notice Deploys immediate + netting hooks on the anvil mainnet fork, initializes both shell pool
///         sets, registers the FewToken LP route, funds netting claims and prepares a swap user.
/// @dev Usage:
///   forge script script/AnvilNettingGasBench.s.sol:AnvilNettingGasBenchSetup \
///     --rpc-url http://127.0.0.1:8546 --broadcast -vvv
contract AnvilNettingGasBenchSetup is Script, BenchConstants {
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 deployerPk = vm.envUint("ANVIL_DEPLOYER_PK");
        uint256 userPk = vm.envUint("ANVIL_USER_PK");
        address deployer = vm.addr(deployerPk);
        address user = vm.addr(userPk);

        address fewWeth = IFewFactory(FEW_FACTORY).getWrappedToken(address(WETH));
        address fewWbtc = IFewFactory(FEW_FACTORY).getWrappedToken(WBTC);
        require(fewWeth != address(0) && fewWbtc != address(0), "few tokens missing at fork block");
        // Mainnet fwWBTC/fwWETH pool behind position #416852, sorted by address.
        PoolKey memory fewKey = PoolKey({
            currency0: Currency.wrap(fewWbtc),
            currency1: Currency.wrap(fewWeth),
            fee: 500,
            tickSpacing: 5,
            hooks: IHooks(address(0))
        });
        (uint160 fewPrice,,,) = MANAGER.getSlot0(fewKey.toId());
        require(fewPrice != 0, "few pool not initialized at fork block");
        address fewUnderlying0 = IFewWrappedToken(fewWbtc).token();

        vm.startBroadcast(deployerPk);

        V4Quoter quoter = new V4Quoter(MANAGER);

        bytes memory args = abi.encode(MANAGER, FEW_FACTORY, WETH, IV4Quoter(address(quoter)), deployer);
        (, bytes32 immediateSalt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(FewV4ShellHook).creationCode, args);
        FewV4ShellHook immediate =
            new FewV4ShellHook{salt: immediateSalt}(MANAGER, FEW_FACTORY, WETH, IV4Quoter(address(quoter)), deployer);
        bytes memory nettingArgs = abi.encode(MANAGER, FEW_FACTORY, WETH, IV4Quoter(address(quoter)), deployer);
        (, bytes32 nettingSalt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(FewV4NettingShellHook).creationCode, nettingArgs);
        FewV4NettingShellHook netting = new FewV4NettingShellHook{salt: nettingSalt}(
            MANAGER, FEW_FACTORY, WETH, IV4Quoter(address(quoter)), deployer
        );

        PoolKey memory immediateKey = _shellKey(IHooks(address(immediate)));
        PoolKey memory nettingKey = _shellKey(IHooks(address(netting)));
        PoolKey memory immediateEthKey = _ethShellKey(IHooks(address(immediate)));
        PoolKey memory nettingEthKey = _ethShellKey(IHooks(address(netting)));

        MANAGER.initialize(immediateKey, _mappedShellPrice(immediateKey, fewPrice, fewUnderlying0));
        MANAGER.initialize(nettingKey, _mappedShellPrice(nettingKey, fewPrice, fewUnderlying0));
        MANAGER.initialize(immediateEthKey, _mappedShellPrice(immediateEthKey, fewPrice, fewUnderlying0));
        MANAGER.initialize(nettingEthKey, _mappedShellPrice(nettingEthKey, fewPrice, fewUnderlying0));

        immediate.setLpPool(immediateKey, fewKey);
        netting.setLpPool(nettingKey, fewKey);
        immediate.setLpPool(immediateEthKey, fewKey);
        netting.setLpPool(nettingEthKey, fewKey);

        // Working capital: WETH via deposit, WBTC pre-funded to the deployer out-of-band
        // (needs CLAIM_WBTC + USER_WBTC borrowed WBTC, i.e. 30e8 for the current constants).
        WETH.deposit{value: 400 ether}();
        IERC20(WETH).approve(fewWeth, type(uint256).max);
        IFewWrappedToken(fewWeth).wrap(CLAIM_WETH);
        IERC20(WBTC).approve(fewWbtc, type(uint256).max);
        IFewWrappedToken(fewWbtc).wrap(CLAIM_WBTC);

        // Netting inventory: four claim legs plus a native ETH leg.
        IERC20(WETH).approve(address(netting), CLAIM_WETH);
        netting.depositClaim(Currency.wrap(address(WETH)), CLAIM_WETH);
        IERC20(WBTC).approve(address(netting), CLAIM_WBTC);
        netting.depositClaim(Currency.wrap(WBTC), CLAIM_WBTC);
        IERC20(fewWeth).approve(address(netting), CLAIM_WETH);
        netting.depositClaim(Currency.wrap(fewWeth), CLAIM_WETH);
        IERC20(fewWbtc).approve(address(netting), CLAIM_WBTC);
        netting.depositClaim(Currency.wrap(fewWbtc), CLAIM_WBTC);
        netting.depositClaim{value: CLAIM_ETH}(Currency.wrap(address(0)), CLAIM_ETH);

        // Fund the swap user with ERC20 working balances.
        IERC20(WETH).transfer(user, USER_WETH);
        IERC20(WBTC).transfer(user, USER_WBTC);

        vm.stopBroadcast();

        // Permit2 approvals must come from the user account itself.
        vm.startBroadcast(userPk);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IERC20(WBTC).approve(PERMIT2, type(uint256).max);
        IBenchPermit2Allowance(PERMIT2).approve(address(WETH), UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IBenchPermit2Allowance(PERMIT2).approve(WBTC, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopBroadcast();

        console2.log(string.concat("IMMEDIATE_HOOK=", vm.toString(address(immediate))));
        console2.log(string.concat("NETTING_HOOK=", vm.toString(address(netting))));
        console2.log(string.concat("QUOTER=", vm.toString(address(quoter))));
        console2.log(string.concat("FEW_WETH=", vm.toString(fewWeth)));
        console2.log(string.concat("FEW_WBTC=", vm.toString(fewWbtc)));
        console2.log(string.concat("USER=", vm.toString(user)));
        console2.log("SETUP_OK");
    }

    function _mappedShellPrice(PoolKey memory shellKey, uint160 fewPrice, address fewUnderlying0)
        private
        pure
        returns (uint160)
    {
        address shell0 = Currency.unwrap(shellKey.currency0);
        if (shell0 == address(0)) shell0 = address(WETH);
        return fewUnderlying0 == shell0 ? fewPrice : _invertPrice(fewPrice);
    }
}

/// @notice Executes exactly one Universal Router v4 swap against a bench hook, so the outer script can
///         read the real transaction gasUsed from the anvil receipt and compare immediate vs netting
///         from byte-identical chain state.
/// @dev Env: BENCH_HOOK, BENCH_KIND=erc20|eth, BENCH_ZFO=true|false, BENCH_EXACT_IN=true|false,
///      BENCH_AMOUNT (uint128, token units), ANVIL_USER_PK.
contract AnvilNettingGasBenchSwap is Script, BenchConstants {
    function run() external {
        address hook = vm.envAddress("BENCH_HOOK");
        bool isEth = keccak256(bytes(vm.envString("BENCH_KIND"))) == keccak256(bytes("eth"));
        bool zeroForOne = vm.envBool("BENCH_ZFO");
        bool exactIn = vm.envBool("BENCH_EXACT_IN");
        uint128 amount = uint128(vm.envUint("BENCH_AMOUNT"));
        uint256 userPk = vm.envUint("ANVIL_USER_PK");
        address user = vm.addr(userPk);

        PoolKey memory key = isEth ? _ethShellKey(IHooks(hook)) : _shellKey(IHooks(hook));
        IAggregatorHook aggregator = IAggregatorHook(hook);

        int256 specified = exactIn ? -int256(uint256(amount)) : int256(uint256(amount));
        uint256 unspecified = aggregator.quote(zeroForOne, specified, _poolId(key));

        bytes[] memory inputs = _routerInputs(key, zeroForOne, exactIn, amount, unspecified);
        uint256 deadline = block.timestamp + 600;

        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 value = input.isAddressZero() ? (exactIn ? amount : unspecified) : 0;

        console2.log(string.concat("BENCH_HOOK=", vm.toString(hook)));
        console2.log(string.concat("BENCH_USER=", vm.toString(user)));
        console2.log("BENCH_AMOUNT_IN_LEG_WEI", exactIn ? uint256(amount) : unspecified);
        console2.log("BENCH_AMOUNT_OUT_LEG_WEI", exactIn ? unspecified : uint256(amount));
        console2.log("BENCH_MSG_VALUE", value);
        console2.log(string.concat("BENCH_INPUT_TOKEN=", vm.toString(Currency.unwrap(input))));
        console2.log(string.concat("BENCH_OUTPUT_TOKEN=", vm.toString(Currency.unwrap(output))));

        vm.startBroadcast(userPk);
        IBenchUniversalRouter(UNIVERSAL_ROUTER).execute{value: value}(hex"10", inputs, deadline);
        vm.stopBroadcast();
    }

    function _routerInputs(PoolKey memory key, bool zeroForOne, bool exactIn, uint128 amount, uint256 unspecified)
        private
        pure
        returns (bytes[] memory inputs)
    {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        bytes[] memory params = new bytes[](3);
        bytes memory actions;
        if (exactIn) {
            actions = hex"060c0f";
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: amount,
                    amountOutMinimum: uint128(unspecified),
                    hookData: bytes("")
                })
            );
            params[1] = abi.encode(Currency.unwrap(input), uint256(amount));
            params[2] = abi.encode(Currency.unwrap(output), unspecified);
        } else {
            actions = hex"080c0f";
            params[0] = abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountOut: amount,
                    amountInMaximum: uint128(unspecified),
                    hookData: bytes("")
                })
            );
            params[1] = abi.encode(Currency.unwrap(input), unspecified);
            params[2] = abi.encode(Currency.unwrap(output), uint256(amount));
        }
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }
}
