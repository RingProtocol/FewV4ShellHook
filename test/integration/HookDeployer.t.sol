// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV4ShellHook} from "../../src/FewV4ShellHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {MockFewFactory} from "../mocks/MockFewFactory.sol";
import {MockWETH9} from "../mocks/MockWETH9.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Import HookDeployer from the deploy script.
import {HookDeployer} from "../../script/DeployFewV4ShellHookWithOwner.s.sol";

/// @notice Tests that HookDeployer sets the owner at construction time via the constructor
///         parameter, eliminating the need for transferOwner and preventing front-running.
contract HookDeployerTest is Test {
    PoolManager internal manager;
    MockFewFactory internal factory;
    MockWETH9 internal weth;
    V4Quoter internal v4Quoter;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new MockFewFactory();
        weth = new MockWETH9();
        v4Quoter = new V4Quoter(IPoolManager(address(manager)));

        // Create a wrapper so FewFactory has something.
        MockERC20 token = new MockERC20("T", "T", 18);
        factory.createToken(address(token));
    }

    /// @dev The hook owner is set at construction time, not via transferOwner.
    function test_deployHook_setsOwnerAtConstruction() public {
        // Prepare constructor args with a specific owner.
        address newOwner = makeAddr("newOwner");
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            IFewFactory(address(factory)),
            IWETH9(address(weth)),
            IV4Quoter(address(v4Quoter)),
            newOwner
        );
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        // Deploy HookDeployer.
        HookDeployer deployerHelper = new HookDeployer();

        // Mine the hook address from the HookDeployer's address.
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(deployerHelper), flags, type(FewV4ShellHook).creationCode, constructorArgs);

        bytes memory initCode = abi.encodePacked(type(FewV4ShellHook).creationCode, constructorArgs);

        // Deploy the hook — owner should be newOwner immediately, no transferOwner needed.
        address hookAddr = deployerHelper.deployHook(salt, initCode);

        assertEq(hookAddr, expectedHook, "hook address matches mined address");
        assertEq(FewV4ShellHook(payable(hookAddr)).owner(), newOwner, "owner set at construction");
    }

    /// @dev An attacker using a different owner gets a different CREATE2 address,
    ///      so they cannot front-run the deployment at the same address.
    function test_deployHook_differentOwnerDifferentAddress() public {
        address legitOwner = makeAddr("legitOwner");
        address attackerOwner = makeAddr("attackerOwner");

        bytes memory legitArgs = abi.encode(
            IPoolManager(address(manager)),
            IFewFactory(address(factory)),
            IWETH9(address(weth)),
            IV4Quoter(address(v4Quoter)),
            legitOwner
        );
        bytes memory attackerArgs = abi.encode(
            IPoolManager(address(manager)),
            IFewFactory(address(factory)),
            IWETH9(address(weth)),
            IV4Quoter(address(v4Quoter)),
            attackerOwner
        );
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        HookDeployer deployerHelper = new HookDeployer();

        (address legitAddr,) =
            HookMiner.find(address(deployerHelper), flags, type(FewV4ShellHook).creationCode, legitArgs);
        (address attackerAddr,) =
            HookMiner.find(address(deployerHelper), flags, type(FewV4ShellHook).creationCode, attackerArgs);

        // Different owner → different CREATE2 address → cannot front-run at the same address.
        assertTrue(legitAddr != attackerAddr, "different owner -> different address");
    }

    /// @dev Owner(0) in constructor reverts.
    function test_deployHook_revertsOnZeroOwner() public {
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            IFewFactory(address(factory)),
            IWETH9(address(weth)),
            IV4Quoter(address(v4Quoter)),
            address(0)
        );
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        HookDeployer deployerHelper = new HookDeployer();

        (, bytes32 salt) =
            HookMiner.find(address(deployerHelper), flags, type(FewV4ShellHook).creationCode, constructorArgs);

        bytes memory initCode = abi.encodePacked(type(FewV4ShellHook).creationCode, constructorArgs);

        vm.expectRevert();
        deployerHelper.deployHook(salt, initCode);
    }
}
