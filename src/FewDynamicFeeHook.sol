// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LpOwner} from "./base/LpOwner.sol";
import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";
import {FwInventoryFeeMath as FeeMath} from "./libraries/FwInventoryFeeMath.sol";

/// @notice Live inventory LP fees, identical for Shell and direct fw swaps.
/// @dev Non-upgradeable. Does not custody assets or return accounting deltas.
contract FewDynamicFeeHook is BaseHook, LpOwner {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    IFewFactory public immutable fewFactory;

    struct PoolConfig {
        address underlying0;
        address underlying1;
        FeeMath.Config fee;
        bool configured;
    }
    mapping(PoolId => PoolConfig) public configs;
    error InvalidPool();
    error InvalidWrapper(address wrapper);
    error NotConfigured();
    event FeeConfigUpdated(PoolId indexed poolId, uint24 minFee, uint24 baseFee, uint24 maxFee);

    constructor(IPoolManager manager, IFewFactory factory, address initialOwner)
        BaseHook(manager)
        LpOwner(initialOwner)
    {
        if (address(manager).code.length == 0 || address(factory).code.length == 0) {
            revert InvalidPool();
        }
        fewFactory = factory;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
    }

    /// @notice Configure before PoolManager.initialize; existing pools may update fee bounds.
    function configurePool(PoolKey calldata key, FeeMath.Config calldata fee) external onlyOwner {
        if (
            address(key.hooks) != address(this) || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)
        ) revert InvalidPool();
        FeeMath.validate(fee);
        address u0 = _underlying(Currency.unwrap(key.currency0));
        address u1 = _underlying(Currency.unwrap(key.currency1));
        if (u0 == u1) revert InvalidPool();
        configs[key.toId()] = PoolConfig(u0, u1, fee, true);
        emit FeeConfigUpdated(key.toId(), fee.minFee, fee.baseFee, fee.maxFee);
    }

    function _underlying(address wrapper) private view returns (address u) {
        if (wrapper.code.length == 0) revert InvalidWrapper(wrapper);
        u = IFewWrappedToken(wrapper).token();
        if (u.code.length == 0 || fewFactory.getWrappedToken(u) != wrapper) revert InvalidWrapper(wrapper);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != owner) revert NotOwner(sender, owner);
        if (!configs[key.toId()].configured) revert NotConfigured();
        return IHooks.beforeInitialize.selector;
    }

    function getFee(PoolKey calldata key) external view returns (uint24 zeroForOne, uint24 oneForZero) {
        (zeroForOne, oneForZero,,,,) = getFeeState(key);
    }

    /// @notice Instantaneous quote only; does not promise sufficient unwrap/settlement inventory.
    function getFeeState(PoolKey calldata key)
        public
        view
        returns (
            uint24 zeroForOne,
            uint24 oneForZero,
            int256 skew,
            uint160 sqrtPrice,
            uint256 backing0,
            uint256 backing1
        )
    {
        PoolId id = key.toId();
        PoolConfig memory c = configs[id];
        if (!c.configured) revert NotConfigured();
        (sqrtPrice,,,) = poolManager.getSlot0(id);
        backing0 = IERC20(c.underlying0).balanceOf(Currency.unwrap(key.currency0));
        backing1 = IERC20(c.underlying1).balanceOf(Currency.unwrap(key.currency1));
        (zeroForOne, oneForZero, skew) = FeeMath.fees(c.fee, sqrtPrice, backing0, backing1);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint24 f0, uint24 f1,,,,) = getFeeState(key);
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            (params.zeroForOne ? f0 : f1) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }
}
