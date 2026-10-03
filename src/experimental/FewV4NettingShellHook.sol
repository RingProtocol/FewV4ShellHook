// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV4ShellHook} from "../FewV4ShellHook.sol";
import {IFewFactory} from "../interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";
import {LpRouteLib} from "../libraries/LpRouteLib.sol";

/// @title FewV4NettingShellHook
/// @notice Research implementation that settles Shell swaps from prefunded PoolManager ERC-6909 claims.
/// @dev Each swap changes four claim balances instead of wrapping and unwrapping immediately. The owner
///      periodically converts accumulated origin claims and FewToken claims in one PoolManager unlock.
///      This contract is intentionally kept under `experimental`: it does not yet implement per-pool
///      inventory quotas, pause controls, keeper roles, or multi-provider accounting.
contract FewV4NettingShellHook is FewV4ShellHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    error InvalidClaimRequest();
    error InvalidClaimAmount();
    error InvalidClaimRecipient();
    error InsufficientClaim(Currency currency, uint256 available, uint256 required);
    error ClaimBalanceMismatch(Currency currency, uint256 expected, uint256 actual);
    error NonCanonicalWrapper(address wrapper, address underlying, address canonicalWrapper);

    event ClaimDeposited(address indexed currency, uint256 amount);
    event ClaimWithdrawn(address indexed currency, address indexed recipient, uint256 amount);
    event OriginWrapped(address indexed origin, address indexed fewToken, uint256 amount);
    event FewTokenUnwrapped(address indexed fewToken, address indexed origin, uint256 amount);

    enum RequestKind {
        Deposit,
        Withdraw,
        OriginToFew,
        FewToOrigin,
        PairRebalance
    }

    bytes32 private _activeRequest;

    constructor(IPoolManager manager, IFewFactory factory, IWETH9 wrappedNative, IV4Quoter quoter, address initialOwner)
        FewV4ShellHook(manager, factory, wrappedNative, quoter, initialOwner)
    {}

    /// @notice Registers only canonical FewFactory wrappers as the execution pool for this netting hook.
    function setLpPool(PoolKey calldata shellPoolKey, PoolKey calldata lpPoolKey) public override onlyOwner {
        if (Currency.unwrap(lpPoolKey.currency0) != address(0)) {
            _requireCanonicalWrapper(Currency.unwrap(lpPoolKey.currency0));
            _requireCanonicalWrapper(Currency.unwrap(lpPoolKey.currency1));
        }
        super.setLpPool(shellPoolKey, lpPoolKey);
    }

    /// @notice Deposits owner inventory into PoolManager and records it as a claim owned by this hook.
    /// @dev ERC-20 callers approve this hook first. Native claims require msg.value == amount.
    function depositClaim(Currency currency, uint256 amount) external payable onlyOwner nonReentrant {
        if (amount == 0) revert InvalidClaimAmount();
        if (currency.isAddressZero()) {
            if (msg.value != amount) revert InvalidClaimAmount();
        } else {
            if (msg.value != 0) revert InvalidClaimAmount();
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        }
        _runClaimRequest(RequestKind.Deposit, currency, address(0), amount);
        emit ClaimDeposited(Currency.unwrap(currency), amount);
    }

    /// @notice Withdraws unused claim inventory to an owner-selected recipient.
    function withdrawClaim(Currency currency, address recipient, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert InvalidClaimAmount();
        if (recipient == address(0)) revert InvalidClaimRecipient();
        _runClaimRequest(RequestKind.Withdraw, currency, recipient, amount);
        emit ClaimWithdrawn(Currency.unwrap(currency), recipient, amount);
    }

    /// @notice Uses accumulated origin claims to wrap once and replenish FewToken claims.
    function rebalanceOriginToFew(Currency origin, address fewToken, uint256 amount) external onlyOwner nonReentrant {
        _validatePair(origin, fewToken, amount);
        _runClaimRequest(RequestKind.OriginToFew, origin, fewToken, amount);
    }

    /// @notice Uses accumulated FewToken claims to unwrap once and replenish origin claims.
    function rebalanceFewToOrigin(Currency origin, address fewToken, uint256 amount) external onlyOwner nonReentrant {
        _validatePair(origin, fewToken, amount);
        _runClaimRequest(RequestKind.FewToOrigin, origin, fewToken, amount);
    }

    /// @notice Restores both inventory sides of a one-way Shell flow inside one PoolManager unlock.
    function rebalancePair(
        Currency accumulatedOrigin,
        address depletedFew,
        uint256 wrapAmount,
        Currency depletedOrigin,
        address accumulatedFew,
        uint256 unwrapAmount
    ) external onlyOwner nonReentrant {
        _validatePair(accumulatedOrigin, depletedFew, wrapAmount);
        _validatePair(depletedOrigin, accumulatedFew, unwrapAmount);
        if (Currency.unwrap(accumulatedOrigin) == Currency.unwrap(depletedOrigin)) revert InvalidClaimRequest();

        bytes memory data = abi.encode(
            RequestKind.PairRebalance,
            accumulatedOrigin,
            depletedFew,
            wrapAmount,
            depletedOrigin,
            accumulatedFew,
            unwrapAmount
        );
        _activeRequest = keccak256(data);
        poolManager.unlock(data);
        if (_activeRequest != bytes32(0)) revert InvalidClaimRequest();
    }

    function claimBalance(Currency currency) public view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _activeRequest == bytes32(0) || keccak256(data) != _activeRequest) {
            revert InvalidClaimRequest();
        }
        _activeRequest = bytes32(0);
        RequestKind kind = abi.decode(data, (RequestKind));

        if (kind == RequestKind.PairRebalance) {
            (
                ,
                Currency accumulatedOrigin,
                address depletedFew,
                uint256 wrapAmount,
                Currency depletedOrigin,
                address accumulatedFew,
                uint256 unwrapAmount
            ) = abi.decode(data, (RequestKind, Currency, address, uint256, Currency, address, uint256));
            _originClaimToFewClaim(accumulatedOrigin, depletedFew, wrapAmount);
            _fewClaimToOriginClaim(depletedOrigin, accumulatedFew, unwrapAmount);
            return bytes("");
        }

        (, Currency currency, address target, uint256 amount) =
            abi.decode(data, (RequestKind, Currency, address, uint256));
        if (kind == RequestKind.Deposit) {
            _depositClaim(currency, amount);
        } else if (kind == RequestKind.Withdraw) {
            _withdrawClaim(currency, target, amount);
        } else if (kind == RequestKind.OriginToFew) {
            _originClaimToFewClaim(currency, target, amount);
        } else if (kind == RequestKind.FewToOrigin) {
            _fewClaimToOriginClaim(currency, target, amount);
        } else {
            revert InvalidClaimRequest();
        }
        return bytes("");
    }

    /// @dev If the hook holds enough FewToken claims to cover the inner-pool input, use netting.
    ///      Otherwise fall back to the base hook's flash conversion, which requires PoolManager
    ///      to hold enough physical origin token. Revert only when neither source is available.
    function _requireSettlementInventory(address origin, uint256 amount) internal view override {
        address underlying = origin == address(0) ? address(weth) : origin;
        address fewToken = fewFactory.getWrappedToken(underlying);
        if (claimBalance(Currency.wrap(fewToken)) >= amount) return;
        super._requireSettlementInventory(origin, amount);
    }

    function convertAndSettle(
        LpRouteLib.LpRoute memory route,
        bool shellZeroForOne,
        uint256 amountIn,
        uint256 amountOut
    ) internal override {
        Currency originIn = Currency.wrap(shellZeroForOne ? route.token0 : route.token1);
        Currency originOut = Currency.wrap(shellZeroForOne ? route.token1 : route.token0);
        Currency fewIn = Currency.wrap(shellZeroForOne ? route.few0 : route.few1);
        Currency fewOut = Currency.wrap(shellZeroForOne ? route.few1 : route.few0);

        if (claimBalance(fewIn) >= amountIn && claimBalance(originOut) >= amountOut) {
            // Netting path: pay and receive the real FewToken LP swap with prefunded claims.
            poolManager.burn(address(this), fewIn.toId(), amountIn);
            poolManager.mint(address(this), fewOut.toId(), amountOut);

            // Keep the trader's origin input as a claim and release prefunded origin output inventory.
            poolManager.mint(address(this), originIn.toId(), amountIn);
            poolManager.burn(address(this), originOut.toId(), amountOut);
        } else {
            // Fallback path: run the base hook's immediate wrap/unwrap settlement.
            // _requireSettlementInventory already verified that PoolManager has enough origin token.
            super.convertAndSettle(route, shellZeroForOne, amountIn, amountOut);
        }
    }

    function _runClaimRequest(RequestKind kind, Currency currency, address target, uint256 amount) private {
        bytes memory data = abi.encode(kind, currency, target, amount);
        _activeRequest = keccak256(data);
        poolManager.unlock(data);
        if (_activeRequest != bytes32(0)) revert InvalidClaimRequest();
    }

    function _depositClaim(Currency currency, uint256 amount) private {
        uint256 beforeClaim = claimBalance(currency);
        _settleExact(currency, amount);
        poolManager.mint(address(this), currency.toId(), amount);
        _requireClaimBalance(currency, beforeClaim + amount);
    }

    function _withdrawClaim(Currency currency, address recipient, uint256 amount) private {
        uint256 beforeClaim = claimBalance(currency);
        _requireClaim(currency, amount);
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
        _requireClaimBalance(currency, beforeClaim - amount);
    }

    function _originClaimToFewClaim(Currency origin, address fewToken, uint256 amount) private {
        Currency few = Currency.wrap(fewToken);
        uint256 originBefore = claimBalance(origin);
        uint256 fewBefore = claimBalance(few);
        _requireClaim(origin, amount);

        poolManager.burn(address(this), origin.toId(), amount);
        poolManager.take(origin, address(this), amount);
        _wrapExact(origin, fewToken, amount);
        _settleExact(few, amount);
        poolManager.mint(address(this), few.toId(), amount);

        _requireClaimBalance(origin, originBefore - amount);
        _requireClaimBalance(few, fewBefore + amount);
        emit OriginWrapped(Currency.unwrap(origin), fewToken, amount);
    }

    function _fewClaimToOriginClaim(Currency origin, address fewToken, uint256 amount) private {
        Currency few = Currency.wrap(fewToken);
        uint256 originBefore = claimBalance(origin);
        uint256 fewBefore = claimBalance(few);
        _requireClaim(few, amount);

        poolManager.burn(address(this), few.toId(), amount);
        poolManager.take(few, address(this), amount);
        _unwrapExact(fewToken, origin, amount);
        _settleExact(origin, amount);
        poolManager.mint(address(this), origin.toId(), amount);

        _requireClaimBalance(few, fewBefore - amount);
        _requireClaimBalance(origin, originBefore + amount);
        emit FewTokenUnwrapped(fewToken, Currency.unwrap(origin), amount);
    }

    function _validatePair(Currency origin, address fewToken, uint256 amount) private view {
        if (amount == 0 || fewToken.code.length == 0) revert InvalidClaimAmount();
        address underlying = origin.isAddressZero() ? address(weth) : Currency.unwrap(origin);
        address canonical = fewFactory.getWrappedToken(underlying);
        if (canonical != fewToken || IFewWrappedToken(fewToken).token() != underlying) {
            revert NonCanonicalWrapper(fewToken, underlying, canonical);
        }
    }

    function _requireCanonicalWrapper(address fewToken) private view {
        if (fewToken.code.length == 0) revert InvalidClaimRequest();
        address underlying = IFewWrappedToken(fewToken).token();
        address canonical = fewFactory.getWrappedToken(underlying);
        if (canonical != fewToken) revert NonCanonicalWrapper(fewToken, underlying, canonical);
    }

    function _requireClaim(Currency currency, uint256 amount) private view {
        uint256 available = claimBalance(currency);
        if (available < amount) revert InsufficientClaim(currency, available, amount);
    }

    function _requireClaimBalance(Currency currency, uint256 expected) private view {
        uint256 actual = claimBalance(currency);
        if (actual != expected) revert ClaimBalanceMismatch(currency, expected, actual);
    }
}
