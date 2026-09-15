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

/// @notice Helper contract that deploys FewV4ShellHook via CREATE2 from itself.
///         The hook owner is set at construction time via the constructor parameter,
///         so no transferOwner step is needed. The CREATE2 address is bound to the
///         owner address, making front-running at the same address impossible — an
///         attacker using a different owner gets a different address.
contract HookDeployer {
    /// @dev Deploys the hook via CREATE2. The hook owner is embedded in initCode
    ///      (as a constructor argument), so the owner is set at construction time.
    ///      Returns the hook address.
    function deployHook(bytes32 salt, bytes memory initCode) external returns (address hookAddr) {
        hookAddr = create2(salt, initCode);
        require(hookAddr != address(0), "CREATE2 failed");
    }

    /// @dev Internal CREATE2 deployment.
    function create2(bytes32 salt, bytes memory initCode) internal returns (address addr) {
        assembly {
            let encodedData := add(initCode, 0x20)
            let encodedSize := mload(initCode)
            addr := create2(0, encodedData, encodedSize, salt)
        }
    }
}

/// @notice Deploys FewV4ShellHook via a HookDeployer helper with HOOK_OWNER embedded
///         in the hook constructor arguments.
///
/// Required env:
///   HOOK_OWNER  - the hook owner set during construction
///
/// Optional env (defaults are Ethereum mainnet):
///   V4_POOL_MANAGER, FEW_FACTORY, WETH9, V4_QUOTER
contract DeployFewV4ShellHookWithOwner is Script {
    address internal constant V4_POOL_MANAGER_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address internal constant WETH9_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant V4_QUOTER_DEFAULT = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;

    function run() external {
        address poolManagerAddress = vm.envOr("V4_POOL_MANAGER", V4_POOL_MANAGER_DEFAULT);
        address factoryAddress = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address wethAddress = vm.envOr("WETH9", WETH9_DEFAULT);
        address v4QuoterAddress = vm.envOr("V4_QUOTER", V4_QUOTER_DEFAULT);
        address newOwner = vm.envAddress("HOOK_OWNER");

        uint256 deployerPrivateKey = vm.envUint("ETH_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddress),
            IFewFactory(factoryAddress),
            IWETH9(wethAddress),
            IV4Quoter(v4QuoterAddress),
            newOwner
        );
        bytes memory initCode = abi.encodePacked(type(FewV4ShellHook).creationCode, constructorArgs);
        uint160 flags = _flags();

        // Compute the HookDeployer's address (deployed via CREATE from deployer's next nonce).
        // We need to know this address to mine the hook's CREATE2 address from it.
        uint256 deployerNonce = vm.getNonce(deployer);
        address deployerAddr = vm.computeCreateAddress(deployer, deployerNonce);

        // Mine the hook CREATE2 address from the HookDeployer's address.
        (address expectedHook, bytes32 salt) =
            HookMiner.find(deployerAddr, flags, type(FewV4ShellHook).creationCode, constructorArgs);

        console2.log("=== FewV4ShellHook deployment (owner in constructor) ===");
        console2.log("Deployer:      ", deployer);
        console2.log("HookDeployer:  ", deployerAddr);
        console2.log("Owner:         ", newOwner);
        console2.log("Expected hook: ", expectedHook);
        console2.log("Salt:");
        console2.logBytes32(salt);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the HookDeployer helper (via CREATE, so its address matches deployerAddr).
        HookDeployer deployerHelper = new HookDeployer();
        require(address(deployerHelper) == deployerAddr, "deployer address mismatch");

        // 2. Use the HookDeployer to deploy the hook. Owner is set at construction time.
        address hookAddr = deployerHelper.deployHook(salt, initCode);
        require(hookAddr == expectedHook, "hook address mismatch");

        FewV4ShellHook hook = FewV4ShellHook(payable(hookAddr));

        // 3. Verify deployment.
        require(address(hook.poolManager()) == poolManagerAddress, "deployed manager mismatch");
        require(address(hook.fewFactory()) == factoryAddress, "deployed factory mismatch");
        require(address(hook.weth()) == wethAddress, "deployed weth mismatch");
        require(address(hook.v4Quoter()) == v4QuoterAddress, "deployed v4Quoter mismatch");
        require(hook.owner() == newOwner, "owner should be newOwner");

        vm.stopBroadcast();

        console2.log("=== Deployment verified (owner set at construction) ===");
        console2.log("Hook:        ", address(hook));
        console2.log("poolManager: ", poolManagerAddress);
        console2.log("fewFactory:  ", factoryAddress);
        console2.log("weth9:       ", wethAddress);
        console2.log("v4Quoter:    ", v4QuoterAddress);
        console2.log("Owner:       ", hook.owner());
    }

    function _flags() internal pure returns (uint160) {
        return uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);
    }
}
