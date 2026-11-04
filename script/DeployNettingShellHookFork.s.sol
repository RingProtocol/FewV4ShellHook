// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {FewV4NettingShellHook} from "../src/experimental/FewV4NettingShellHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";

/// @notice Deploys FewV4NettingShellHook against the real mainnet environment (PoolManager,
///         FewFactory, WETH9, V4Quoter at their mainnet addresses). Intended for an anvil
///         mainnet fork; works unchanged on live mainnet if the env vars are provided.
/// @dev The hook address is mined via CREATE2 so its low 14 bits equal the required flags
///      (0x2088 = BEFORE_INITIALIZE | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA), same as V2/V3.
///
/// @dev Usage (anvil mainnet fork on 8545):
///   anvil --fork-url $ETH_RPC_URL --port 8545 &
///   cast rpc anvil_setBalance 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 10ether --rpc-url http://127.0.0.1:8545
///   forge script script/DeployNettingShellHookFork.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast -vvv
contract DeployNettingShellHookFork is Script {
    // Mainnet constants (see testresult/mainnet-deployment-report.md).
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IFewFactory internal constant FEW_FACTORY = IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD);
    IWETH9 internal constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);

    // anvil account 0 - fine for forks, override with DEPLOYER_PK for real deploys.
    uint256 internal constant ANVIL_ACCOUNT_0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // CREATE2 Deployer Proxy: forge scripts execute `new Hook{salt}` through this proxy, so the
    // mining deployer must be the proxy itself (see HookMiner.find natspec).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerPk = vm.envOr("DEPLOYER_PK", ANVIL_ACCOUNT_0);
        address deployer = vm.addr(deployerPk);
        address owner = vm.envOr("HOOK_OWNER", deployer);

        vm.startBroadcast(deployerPk);

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, FEW_FACTORY, WETH, QUOTER, owner);
        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(FewV4NettingShellHook).creationCode, constructorArgs);

        FewV4NettingShellHook hook =
            new FewV4NettingShellHook{salt: salt}(POOL_MANAGER, FEW_FACTORY, WETH, QUOTER, owner);
        require(address(hook) == mined, "mined address mismatch");

        console2.log("Deployer:", deployer);
        console2.log("Owner:", owner);
        console2.log("NettingShellHook:", address(hook));
        console2.log("Salt:", vm.toString(salt));

        vm.stopBroadcast();
    }
}
