// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {DeltaResolver} from "v4-periphery/src/base/DeltaResolver.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";
import {LpRouteLib} from "../libraries/LpRouteLib.sol";

/// @notice Wrap/unwrap/settle primitives shared by the hook. Extracted to limit main-contract audit scope.
abstract contract LpSettlement is DeltaResolver {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    error WrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error UnwrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error InsufficientConversionBalance(address token, uint256 available, uint256 required);
    error TokenBalanceMismatch(address token, uint256 expectedBalance, uint256 actualBalance);
    error WrapperBackingDeltaMismatch(address wrapper, uint256 expectedBalance, uint256 actualBalance);
    error SettlementAmountMismatch(address token, uint256 paid, uint256 expected);

    IWETH9 internal immutable _weth;
    mapping(address wrapper => bool approved) internal _wrapperApproved;

    constructor(IWETH9 weth) {
        _weth = weth;
    }

    function convertAndSettle(
        LpRouteLib.LpRoute memory route,
        bool shellZeroForOne,
        uint256 amountIn,
        uint256 amountOut
    ) internal {
        Currency input = Currency.wrap(shellZeroForOne ? route.token0 : route.token1);
        Currency output = Currency.wrap(shellZeroForOne ? route.token1 : route.token0);
        address fewIn = shellZeroForOne ? route.few0 : route.few1;
        address fewOut = shellZeroForOne ? route.few1 : route.few0;

        // Input leg: take origin from PoolManager and mint fewToken directly back to PoolManager.
        uint256 inputBaseline = input.balanceOfSelf();
        uint256 fewInBaseline = IERC20(fewIn).balanceOf(address(this));
        _take(input, address(this), amountIn);
        _wrapAndSettle(input, fewIn, amountIn, inputBaseline + amountIn);
        _requireBalance(Currency.wrap(fewIn), fewInBaseline);

        // Output leg: take fewToken from PoolManager and unwrap ERC20 output directly back to it.
        // Native ETH still passes through this contract because WETH must be withdrawn first.
        uint256 outputBaseline = output.balanceOfSelf();
        uint256 fewOutBaseline = IERC20(fewOut).balanceOf(address(this));
        _take(Currency.wrap(fewOut), address(this), amountOut);
        _unwrapAndSettle(fewOut, output, amountOut, fewOutBaseline + amountOut);
        _requireBalance(output, outputBaseline);
    }

    /// @dev Call only with a wrapper explicitly validated against FewFactory or resolved from it.
    function _authorizeWrapper(address underlying, address fewToken) internal {
        if (_wrapperApproved[fewToken]) return;
        // Effects before interaction: any reentrant attempt observes the wrapper as already handled.
        // A failed approval reverts this flag with the rest of the transaction.
        _wrapperApproved[fewToken] = true;
        IERC20(underlying).forceApprove(fewToken, type(uint256).max);
    }

    function _wrapAndSettle(Currency input, address fewToken, uint256 amount, uint256 inputBefore) internal {
        address underlying;
        uint256 wethBefore = 0;

        if (input.isAddressZero()) {
            wethBefore = IERC20(address(_weth)).balanceOf(address(this));
            _weth.deposit{value: amount}();
            underlying = address(_weth);
        } else {
            underlying = Currency.unwrap(input);
        }

        if (inputBefore < amount) revert InsufficientConversionBalance(Currency.unwrap(input), inputBefore, amount);

        uint256 backingBefore = IERC20(underlying).balanceOf(fewToken);
        _authorizeWrapper(underlying, fewToken);
        poolManager.sync(Currency.wrap(fewToken));
        uint256 returnedAmount = IFewWrappedToken(fewToken).wrapTo(amount, address(poolManager));
        if (returnedAmount != amount) revert WrapReturnMismatch(returnedAmount, amount);
        _requireWrapperBacking(fewToken, underlying, backingBefore + amount);
        uint256 paid = poolManager.settle();
        if (paid != amount) revert SettlementAmountMismatch(fewToken, paid, amount);

        _requireBalance(input, inputBefore - amount);
        if (input.isAddressZero()) _requireBalance(Currency.wrap(address(_weth)), wethBefore);
    }

    function _unwrapAndSettle(address fewToken, Currency output, uint256 amount, uint256 fewBefore) internal {
        if (fewBefore < amount) revert InsufficientConversionBalance(fewToken, fewBefore, amount);
        address underlying = IFewWrappedToken(fewToken).token();
        uint256 backingBefore = IERC20(underlying).balanceOf(fewToken);
        if (backingBefore < amount) revert InsufficientConversionBalance(underlying, backingBefore, amount);

        if (output.isAddressZero()) {
            uint256 wethBefore = IERC20(address(_weth)).balanceOf(address(this));
            uint256 returnedAmount = IFewWrappedToken(fewToken).unwrapTo(amount, address(this));
            if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);
            _requireWrapperBacking(fewToken, underlying, backingBefore - amount);
            _weth.withdraw(amount);
            _requireBalance(Currency.wrap(address(_weth)), wethBefore);
            _settleExact(output, amount);
        } else {
            poolManager.sync(output);
            uint256 returnedAmount = IFewWrappedToken(fewToken).unwrapTo(amount, address(poolManager));
            if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);
            _requireWrapperBacking(fewToken, underlying, backingBefore - amount);
            uint256 paid = poolManager.settle();
            if (paid != amount) revert SettlementAmountMismatch(Currency.unwrap(output), paid, amount);
        }

        _requireBalance(Currency.wrap(fewToken), fewBefore - amount);
    }

    function _settleExact(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        uint256 paid;
        if (currency.isAddressZero()) {
            paid = poolManager.settle{value: amount}();
        } else {
            currency.transfer(address(poolManager), amount);
            paid = poolManager.settle();
        }
        if (paid != amount) revert SettlementAmountMismatch(Currency.unwrap(currency), paid, amount);
    }

    function _requireBalance(Currency currency, uint256 expected) internal view {
        uint256 actual = currency.balanceOfSelf();
        if (actual != expected) revert TokenBalanceMismatch(Currency.unwrap(currency), expected, actual);
    }

    function _requireWrapperBacking(address wrapper, address underlying, uint256 expected) internal view {
        uint256 actual = IERC20(underlying).balanceOf(wrapper);
        if (actual != expected) revert WrapperBackingDeltaMismatch(wrapper, expected, actual);
    }

    // Required abstract DeltaResolver override; this release settles explicitly through `_settleExact`.
    // slither-disable-next-line dead-code
    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }
}
