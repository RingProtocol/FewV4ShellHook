// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {FewV4ShellHook} from "../src/FewV4ShellHook.sol";

/// @notice Validates an initialized shell/LP pair and prints the owner transaction calldata.
/// @dev Set BROADCAST_CONFIG=true and provide ETH_PRIVATE_KEY only when the owner is an EOA.
///      For a Safe-owned hook, leave broadcasting off and submit the printed target/calldata in Safe.
contract ConfigureLpPool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        FewV4ShellHook hook = FewV4ShellHook(payable(vm.envAddress("SHELL_HOOK")));

        PoolKey memory shellKey = _poolKey("SHELL");
        PoolKey memory lpKey = _poolKey("LP");
        require(address(shellKey.hooks) == address(hook), "shell hook mismatch");

        IPoolManager manager = hook.poolManager();
        PoolId shellPoolId = shellKey.toId();
        PoolId lpPoolId = lpKey.toId();
        (uint160 shellPrice,,,) = manager.getSlot0(shellPoolId);
        (uint160 lpPrice,,,) = manager.getSlot0(lpPoolId);
        require(shellPrice != 0, "shell pool not initialized");
        require(lpPrice != 0, "LP pool not initialized");
        require(manager.getLiquidity(lpPoolId) != 0, "LP pool has no active liquidity");

        bytes memory callData = abi.encodeCall(FewV4ShellHook.setLpPool, (shellKey, lpKey));
        console2.log("Hook owner:", hook.owner());
        console2.log("Target:", address(hook));
        console2.log("Shell PoolId:");
        console2.logBytes32(PoolId.unwrap(shellPoolId));
        console2.log("LP PoolId:");
        console2.logBytes32(PoolId.unwrap(lpPoolId));
        console2.log("setLpPool calldata:");
        console2.logBytes(callData);

        if (vm.envOr("BROADCAST_CONFIG", false)) {
            uint256 ownerPrivateKey = _privateKey();
            require(hook.owner() == vm.addr(ownerPrivateKey), "broadcaster is not hook owner");
            vm.startBroadcast(ownerPrivateKey);
            hook.setLpPool(shellKey, lpKey);
            vm.stopBroadcast();
        }
    }

    function _poolKey(string memory prefix) internal view returns (PoolKey memory key) {
        address currency0 = vm.envAddress(string.concat(prefix, "_CURRENCY0"));
        address currency1 = vm.envAddress(string.concat(prefix, "_CURRENCY1"));
        require(currency0 < currency1, "currencies must be sorted");

        uint256 fee = vm.envUint(string.concat(prefix, "_FEE"));
        int256 tickSpacing = vm.envInt(string.concat(prefix, "_TICK_SPACING"));
        require(fee <= type(uint24).max, "fee overflow");
        require(tickSpacing >= type(int24).min && tickSpacing <= type(int24).max, "tick spacing overflow");

        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: uint24(fee),
            tickSpacing: int24(tickSpacing),
            hooks: IHooks(vm.envAddress(string.concat(prefix, "_HOOK")))
        });
    }

    function _privateKey() internal view returns (uint256) {
        string memory raw = vm.envString("ETH_PRIVATE_KEY");
        bytes memory value = bytes(raw);
        if (value.length == 64) return vm.parseUint(string.concat("0x", raw));
        require(value.length == 66 && value[0] == "0" && value[1] == "x", "invalid ETH_PRIVATE_KEY");
        return vm.parseUint(raw);
    }
}
