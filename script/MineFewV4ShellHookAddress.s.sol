// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

/// @notice Read-only preflight and CREATE2 address mining for FewV4ShellHook.
///
/// Optional Ethereum defaults:
///   V4_POOL_MANAGER, FEW_FACTORY, WETH9, V4_QUOTER
contract MineFewV4ShellHookAddress is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant V4_POOL_MANAGER_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant WETH9_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant V4_QUOTER_DEFAULT = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;

    function run() external view {
        address poolManagerAddress = vm.envOr("V4_POOL_MANAGER", V4_POOL_MANAGER_DEFAULT);
        address factoryAddress = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address wethAddress = vm.envOr("WETH9", WETH9_DEFAULT);
        address v4QuoterAddress = vm.envOr("V4_QUOTER", V4_QUOTER_DEFAULT);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddress),
            IFewFactory(factoryAddress),
            IWETH9(wethAddress),
            IV4Quoter(v4QuoterAddress)
        );
        uint160 flags = _flags();
        (address expectedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(FewV4ShellHook).creationCode, constructorArgs);

        console2.log("=== FewV4ShellHook preflight ===");
        console2.log("poolManager:  ", poolManagerAddress);
        console2.log("fewFactory:   ", factoryAddress);
        console2.log("weth9:        ", wethAddress);
        console2.log("v4Quoter:     ", v4QuoterAddress);
        console2.log("permission mask:", flags);
        console2.log("HOOK_SALT:");
        console2.logBytes32(salt);
        console2.log("EXPECTED_HOOK_ADDRESS:", expectedHook);
    }

    function _flags() internal pure returns (uint160) {
        return uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
    }
}
