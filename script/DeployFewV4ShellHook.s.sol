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
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";

/// @notice Deploys one constructor-allowlisted shell Hook and optionally initializes its outer pool.
/// @dev Run MineFewV4ShellHookAddress first with identical environment values.
///
/// Required:
///   TOKEN_A, TOKEN_B, HOOK_SALT, EXPECTED_HOOK_ADDRESS
///
/// Optional Ethereum defaults:
///   V4_POOL_MANAGER, V4_QUOTER, FEW_FACTORY, POOL_FEE=500, TICK_SPACING=10,
///   SKIP_INIT_POOL=false
contract DeployFewV4ShellHook is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant V4_POOL_MANAGER_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant V4_QUOTER_DEFAULT = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address internal constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;

    function run() external {
        address poolManagerAddress = vm.envOr("V4_POOL_MANAGER", V4_POOL_MANAGER_DEFAULT);
        address quoterAddress = vm.envOr("V4_QUOTER", V4_QUOTER_DEFAULT);
        address factoryAddress = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(500)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(10)));
        bytes32 salt = vm.envBytes32("HOOK_SALT");
        address expectedHook = vm.envAddress("EXPECTED_HOOK_ADDRESS");
        bool skipInit = vm.envOr("SKIP_INIT_POOL", false);

        (address token0, address token1) = _sort(tokenA, tokenB);
        IPoolManager poolManager = IPoolManager(poolManagerAddress);
        IFewFactory factory = IFewFactory(factoryAddress);
        require(address(IV4Quoter(quoterAddress).poolManager()) == poolManagerAddress, "quoter/manager mismatch");

        address few0 = factory.getWrappedToken(token0);
        address few1 = factory.getWrappedToken(token1);
        require(few0 != address(0) && few1 != address(0) && few0 != few1, "canonical wrapper missing");
        require(IFewWrappedToken(few0).token() == token0, "few0 underlying mismatch");
        require(IFewWrappedToken(few1).token() == token1, "few1 underlying mismatch");
        PoolKey memory innerKey = _poolKey(few0, few1, fee, tickSpacing, IHooks(address(0)));
        PoolId innerPoolId = innerKey.toId();
        (uint160 innerPrice,,,) = poolManager.getSlot0(innerPoolId);
        require(innerPrice != 0 && poolManager.getLiquidity(innerPoolId) != 0, "inner route unavailable");

        PoolId[] memory allowlist = new PoolId[](1);
        allowlist[0] = innerPoolId;
        bytes memory constructorArgs = abi.encode(poolManager, factory, IV4Quoter(quoterAddress), allowlist);
        bytes memory initCode = abi.encodePacked(type(FewV4ShellHook).creationCode, constructorArgs);
        address predicted = HookMiner.computeAddress(CREATE2_DEPLOYER, uint256(salt), initCode);
        require(predicted == expectedHook, "salt/init-code address mismatch");
        require(uint160(expectedHook) & Hooks.ALL_HOOK_MASK == _flags(), "wrong hook permission bits");

        vm.startBroadcast();
        if (expectedHook.code.length == 0) {
            (bool deployed,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
            require(deployed, "CREATE2 deployment failed");
        }
        require(expectedHook.code.length != 0, "hook bytecode missing");

        FewV4ShellHook shell = FewV4ShellHook(expectedHook);
        require(address(shell.poolManager()) == poolManagerAddress, "deployed manager mismatch");
        require(address(shell.fewFactory()) == factoryAddress, "deployed factory mismatch");
        require(address(shell.quoter()) == quoterAddress, "deployed quoter mismatch");
        require(shell.allowedInnerPools(innerPoolId), "inner pool not allowlisted");

        PoolKey memory outerKey = _poolKey(token0, token1, fee, tickSpacing, IHooks(expectedHook));
        PoolId outerPoolId = outerKey.toId();
        (uint160 outerPrice,,,) = poolManager.getSlot0(outerPoolId);
        if (!skipInit && outerPrice == 0) {
            (,,,, uint160 recommendedPrice) = shell.previewRoute(token0, token1, fee, tickSpacing);
            poolManager.initialize(outerKey, recommendedPrice);
            (outerPrice,,,) = poolManager.getSlot0(outerPoolId);
            require(outerPrice == recommendedPrice, "outer init verification failed");
        }
        vm.stopBroadcast();

        console2.log("=== FewV4ShellHook deployment verified ===");
        console2.log("Hook:          ", expectedHook);
        console2.log("token0:        ", token0);
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

    function _poolKey(address a, address b, uint24 fee, int24 tickSpacing, IHooks hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        (address first, address second) = _sort(a, b);
        return PoolKey({
            currency0: Currency.wrap(first),
            currency1: Currency.wrap(second),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
    }

    function _sort(address a, address b) internal pure returns (address first, address second) {
        require(a != address(0) && b != address(0) && a != b, "invalid currencies");
        return a < b ? (a, b) : (b, a);
    }

    function _flags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
