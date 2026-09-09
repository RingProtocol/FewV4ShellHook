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

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";

/// @notice Read-only preflight and CREATE2 address mining for one FewToken v4 shell route.
///         Supports native ETH when TOKEN_A or TOKEN_B is address(0).
///
/// Required:
///   TOKEN_A, TOKEN_B, HOOK_OWNER
///
/// Optional Ethereum defaults:
///   V4_POOL_MANAGER, V4_QUOTER, V4_POSITION_MANAGER, FEW_FACTORY, WETH, POOL_FEE=500, TICK_SPACING=10
contract MineFewV4ShellHookAddress is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant V4_POOL_MANAGER_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant V4_QUOTER_DEFAULT = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address internal constant V4_POSITION_MANAGER_DEFAULT = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant WETH_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external view {
        address poolManagerAddress = vm.envOr("V4_POOL_MANAGER", V4_POOL_MANAGER_DEFAULT);
        address quoterAddress = vm.envOr("V4_QUOTER", V4_QUOTER_DEFAULT);
        address positionManagerAddress = vm.envOr("V4_POSITION_MANAGER", V4_POSITION_MANAGER_DEFAULT);
        address hookOwner = vm.envAddress("HOOK_OWNER");
        address factoryAddress = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address wethAddress = vm.envOr("WETH", WETH_DEFAULT);
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(500)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(10)));

        (address token0, address token1) = _sort(tokenA, tokenB);
        IPoolManager poolManager = IPoolManager(poolManagerAddress);
        IFewFactory factory = IFewFactory(factoryAddress);
        require(address(IV4Quoter(quoterAddress).poolManager()) == poolManagerAddress, "quoter/manager mismatch");
        require(
            address(IPositionManager(positionManagerAddress).poolManager()) == poolManagerAddress,
            "position manager/manager mismatch"
        );
        require(hookOwner != address(0), "hook owner unset");

        address origin0 = token0 == address(0) ? wethAddress : token0;
        address origin1 = token1 == address(0) ? wethAddress : token1;
        address few0 = factory.getWrappedToken(origin0);
        address few1 = factory.getWrappedToken(origin1);
        require(few0 != address(0) && few1 != address(0) && few0 != few1, "canonical wrapper missing");
        require(IFewWrappedToken(few0).token() == origin0, "few0 underlying mismatch");
        require(IFewWrappedToken(few1).token() == origin1, "few1 underlying mismatch");

        PoolKey memory innerKey = _innerKey(few0, few1, fee, tickSpacing);
        PoolId innerPoolId = innerKey.toId();
        (uint160 innerPrice,,,) = poolManager.getSlot0(innerPoolId);
        require(innerPrice != 0, "inner pool uninitialized");
        require(poolManager.getLiquidity(innerPoolId) != 0, "inner pool has no active liquidity");

        PoolId[] memory allowlist = new PoolId[](1);
        allowlist[0] = innerPoolId;
        bytes memory constructorArgs = abi.encode(
            poolManager,
            factory,
            IV4Quoter(quoterAddress),
            IWETH9(wethAddress),
            allowlist,
            hookOwner,
            IPositionManager(positionManagerAddress)
        );
        uint160 flags = _flags();
        (address expectedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(FewV4ShellHook).creationCode, constructorArgs);

        console2.log("=== FewV4ShellHook preflight ===");
        console2.log("weth:         ", wethAddress);
        console2.log("token0:       ", token0);
        console2.log("token1:       ", token1);
        console2.log("few0:         ", few0);
        console2.log("few1:         ", few1);
        console2.log("owner:        ", hookOwner);
        console2.log("posm:         ", positionManagerAddress);
        console2.log("fee:          ", fee);
        console2.log("tick spacing: ", tickSpacing);
        console2.log("active L:     ", poolManager.getLiquidity(innerPoolId));
        console2.log("inner price:  ", innerPrice);
        console2.log("inner PoolId:");
        console2.logBytes32(PoolId.unwrap(innerPoolId));
        console2.log("permission mask:", flags);
        console2.log("HOOK_SALT:");
        console2.logBytes32(salt);
        console2.log("EXPECTED_HOOK_ADDRESS:", expectedHook);
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
