// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";

/// @notice Deploys a FewV4ShellHook for an ETH/<TOKEN> route on Sepolia.
/// @dev ETH is represented by address(0) and always becomes currency0 of the outer pool.
///      Set the Sepolia v4 contract addresses via environment variables; WETH defaults to the canonical Sepolia WETH.
///
/// Required env:
///   TOKEN (the non-ETH ERC20), HOOK_OWNER
///
/// Optional:
///   V4_POOL_MANAGER, V4_QUOTER, FEW_FACTORY, WETH, POOL_FEE=500, TICK_SPACING=10, SKIP_INIT_POOL=false
contract DeployFewV4EthShellHook is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() external {
        address poolManagerAddress = vm.envAddress("V4_POOL_MANAGER");
        address quoterAddress = vm.envAddress("V4_QUOTER");
        address factoryAddress = vm.envAddress("FEW_FACTORY");
        address wethAddress = vm.envOr("WETH", WETH_SEPOLIA);
        address token = vm.envAddress("TOKEN");
        address hookOwner = vm.envAddress("HOOK_OWNER");
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(500)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(10)));
        bool skipInit = vm.envOr("SKIP_INIT_POOL", false);

        require(token != address(0), "TOKEN cannot be address(0)");

        // ETH (address(0)) sorts before any ERC20, so it is always currency0 of the outer pool.
        address token0 = address(0);
        address token1 = token;

        IPoolManager poolManager = IPoolManager(poolManagerAddress);
        IFewFactory factory = IFewFactory(factoryAddress);
        require(address(IV4Quoter(quoterAddress).poolManager()) == poolManagerAddress, "quoter/manager mismatch");
        require(hookOwner != address(0), "hook owner unset");

        address fwEth = factory.getWrappedToken(wethAddress);
        address fwToken = factory.getWrappedToken(token);
        require(fwEth != address(0) && fwToken != address(0) && fwEth != fwToken, "canonical wrapper missing");
        require(IFewWrappedToken(fwEth).token() == wethAddress, "fwETH underlying mismatch");
        require(IFewWrappedToken(fwToken).token() == token, "fwTOKEN underlying mismatch");

        (address few0, address few1) = fwEth < fwToken ? (fwEth, fwToken) : (fwToken, fwEth);
        PoolKey memory innerKey = _innerKey(few0, few1, fee, tickSpacing);
        PoolId innerPoolId = innerKey.toId();

        (uint160 innerPrice,,,) = poolManager.getSlot0(innerPoolId);
        require(innerPrice != 0 && poolManager.getLiquidity(innerPoolId) != 0, "inner route uninitialized or empty");

        PoolId[] memory allowlist = new PoolId[](1);
        allowlist[0] = innerPoolId;
        bytes memory constructorArgs =
            abi.encode(poolManager, factory, IV4Quoter(quoterAddress), IWETH9(wethAddress), allowlist, hookOwner);
        bytes memory initCode = abi.encodePacked(type(FewV4ShellHook).creationCode, constructorArgs);
        uint160 flags = _flags();
        (address expectedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(FewV4ShellHook).creationCode, constructorArgs);
        require(uint160(expectedHook) & Hooks.ALL_HOOK_MASK == flags, "wrong hook permission bits");

        vm.startBroadcast();
        if (expectedHook.code.length == 0) {
            (bool deployed,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
            require(deployed, "CREATE2 deployment failed");
        }
        require(expectedHook.code.length != 0, "hook bytecode missing");

        FewV4ShellHook shell = FewV4ShellHook(payable(expectedHook));
        require(address(shell.poolManager()) == poolManagerAddress, "deployed manager mismatch");
        require(address(shell.fewFactory()) == factoryAddress, "deployed factory mismatch");
        require(address(shell.quoter()) == quoterAddress, "deployed quoter mismatch");
        require(address(shell.weth()) == wethAddress, "deployed weth mismatch");
        require(shell.allowedInnerPools(innerPoolId), "inner pool not allowlisted");
        require(shell.owner() == hookOwner, "deployed owner mismatch");

        PoolKey memory outerKey = _outerKey(token0, token1, fee, tickSpacing, IHooks(expectedHook));
        PoolId outerPoolId = outerKey.toId();
        (uint160 outerPrice,,,) = poolManager.getSlot0(outerPoolId);
        if (!skipInit && outerPrice == 0) {
            (,,,, uint160 recommendedPrice) = shell.previewRoute(token0, token1, fee, tickSpacing);
            poolManager.initialize(outerKey, recommendedPrice);
            (outerPrice,,,) = poolManager.getSlot0(outerPoolId);
            require(outerPrice == recommendedPrice, "outer init verification failed");
        }
        vm.stopBroadcast();

        console2.log("=== FewV4EthShellHook deployment verified ===");
        console2.log("Hook:          ", expectedHook);
        console2.log("owner:         ", hookOwner);
        console2.log("weth:          ", wethAddress);
        console2.log("token0 (ETH):  ", token0);
        console2.log("token1:        ", token1);
        console2.log("few0:          ", few0);
        console2.log("few1:          ", few1);
        console2.log("outer price:   ", outerPrice);
        console2.log("inner liquidity:", poolManager.getLiquidity(innerPoolId));
        console2.log("inner PoolId:");
        console2.logBytes32(PoolId.unwrap(innerPoolId));
        console2.log("outer PoolId:");
        console2.logBytes32(PoolId.unwrap(outerPoolId));
        console2.log("No source-list or aggregator inclusion is implied by deployment.");
    }

    function _innerKey(address few0, address few1, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory)
    {
        (address first, address second) = _sort(few0, few1);
        return PoolKey({
            currency0: Currency.wrap(first),
            currency1: Currency.wrap(second),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _outerKey(address token0, address token1, uint24 fee, int24 tickSpacing, IHooks hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        (address first, address second) = _sort(token0, token1);
        return PoolKey({
            currency0: Currency.wrap(first),
            currency1: Currency.wrap(second),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function _sort(address a, address b) internal pure returns (address first, address second) {
        require(a != b, "identical currencies");
        return a < b ? (a, b) : (b, a);
    }

    function _flags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
