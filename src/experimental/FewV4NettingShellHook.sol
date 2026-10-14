// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

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
///      Canonical-wrapper checks are inherited: the base `setLpPool` already rejects non-canonical
///      wrappers, so no registration hook is overridden here.
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

    /// @notice Deposits owner inventory into PoolManager and records it as a claim owned by this hook.
    /// @dev ERC-20 callers approve this hook first. Native claims require msg.value == amount.
    function depositClaim(Currency currency, uint256 amount) external payable onlyOwner isNotLocked {
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
    function withdrawClaim(Currency currency, address recipient, uint256 amount) external onlyOwner isNotLocked {
        if (amount == 0) revert InvalidClaimAmount();
        if (recipient == address(0)) revert InvalidClaimRecipient();
        _runClaimRequest(RequestKind.Withdraw, currency, recipient, amount);
        emit ClaimWithdrawn(Currency.unwrap(currency), recipient, amount);
    }

    /// @notice Uses accumulated origin claims to wrap once and replenish FewToken claims.
    function rebalanceOriginToFew(Currency origin, address fewToken, uint256 amount) external onlyOwner isNotLocked {
        _validatePair(origin, fewToken, amount);
        _runClaimRequest(RequestKind.OriginToFew, origin, fewToken, amount);
    }

    /// @notice Uses accumulated FewToken claims to unwrap once and replenish origin claims.
    function rebalanceFewToOrigin(Currency origin, address fewToken, uint256 amount) external onlyOwner isNotLocked {
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
    ) external onlyOwner isNotLocked {
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

    /// @dev The base hook checks PoolManager cash because it takes physical origin tokens before router
    ///      settlement. This implementation pays the inner pool by burning prefunded FewToken claims.
    function _requireSettlementInventory(address origin, uint256 amount) internal view override {
        address underlying = origin == address(0) ? address(weth) : origin;
        address fewToken = fewFactory.getWrappedToken(underlying);
        _requireClaim(Currency.wrap(fewToken), amount);
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

        _requireClaim(fewIn, amountIn);
        _requireClaim(originOut, amountOut);

        // Pay and receive the real FewToken LP swap with claims already held by this hook.
        poolManager.burn(address(this), fewIn.toId(), amountIn);
        poolManager.mint(address(this), fewOut.toId(), amountOut);

        // Keep the trader's origin input as a claim and release prefunded origin output inventory.
        poolManager.mint(address(this), originIn.toId(), amountIn);
        poolManager.burn(address(this), originOut.toId(), amountOut);
    }

    function _runClaimRequest(RequestKind kind, Currency currency, address target, uint256 amount) private {
        bytes memory data = abi.encode(kind, currency, target, amount);
        _activeRequest = keccak256(data);
        poolManager.unlock(data);
        if (_activeRequest != bytes32(0)) revert InvalidClaimRequest();
    }

    function _depositClaim(Currency currency, uint256 amount) private {
        _settleExact(currency, amount);
        _mintClaim(currency, amount);
    }

    function _withdrawClaim(Currency currency, address recipient, uint256 amount) private {
        _burnClaim(currency, amount);
        poolManager.take(currency, recipient, amount);
    }

    /// @dev Claim bookkeeping is verified on each side separately: keeping the expected balance in a
    ///      narrow scope is what the settlement helpers need to stay clear of the stack limit.
    function _burnClaim(Currency currency, uint256 amount) private {
        uint256 before = claimBalance(currency);
        _requireClaim(currency, amount);
        poolManager.burn(address(this), currency.toId(), amount);
        _requireClaimBalance(currency, before - amount);
    }

    function _mintClaim(Currency currency, uint256 amount) private {
        uint256 before = claimBalance(currency);
        poolManager.mint(address(this), currency.toId(), amount);
        _requireClaimBalance(currency, before + amount);
    }

    function _originClaimToFewClaim(Currency origin, address fewToken, uint256 amount) private {
        Currency few = Currency.wrap(fewToken);
        _burnClaim(origin, amount);
        poolManager.take(origin, address(this), amount);
        // Wrap directly into the PoolManager and settle there, reusing the base's measured checks.
        _wrapAndSettle(origin, fewToken, amount, origin.balanceOfSelf());
        _mintClaim(few, amount);
        emit OriginWrapped(Currency.unwrap(origin), fewToken, amount);
    }

    function _fewClaimToOriginClaim(Currency origin, address fewToken, uint256 amount) private {
        Currency few = Currency.wrap(fewToken);
        _burnClaim(few, amount);
        poolManager.take(few, address(this), amount);
        // Unwrap straight to the PoolManager and settle there, reusing the base's measured checks.
        _unwrapAndSettle(fewToken, origin, amount, few.balanceOfSelf());
        _mintClaim(origin, amount);
        emit FewTokenUnwrapped(fewToken, Currency.unwrap(origin), amount);
    }

    function _validatePair(Currency origin, address fewToken, uint256 amount) private view {
        if (amount == 0 || fewToken.code.length == 0) revert InvalidClaimAmount();
        address underlying = origin.isAddressZero() ? address(weth) : Currency.unwrap(origin);
        address canonical = fewFactory.getWrappedToken(underlying);
        if (canonical != fewToken) revert NonCanonicalWrapper(fewToken, canonical);
        address wrappedUnderlying = IFewWrappedToken(fewToken).token();
        if (wrappedUnderlying != underlying) revert WrapperUnderlyingMismatch(fewToken, underlying, wrappedUnderlying);
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
