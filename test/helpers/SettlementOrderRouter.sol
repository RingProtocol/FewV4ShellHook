// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Test-only executor for SETTLE -> SWAP -> TAKE and SWAP -> SETTLE -> TAKE.
contract SettlementOrderRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bool prepay)
        external
        payable
        returns (BalanceDelta delta)
    {
        require(!prepay || params.amountSpecified < 0, "exact-in prepayment only");
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params, prepay)), (BalanceDelta));
        if (address(this).balance != 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address payer, PoolKey memory key, SwapParams memory params, bool prepay) =
            abi.decode(data, (address, PoolKey, SwapParams, bool));
        if (prepay) {
            _pay(params.zeroForOne ? key.currency0 : key.currency1, payer, uint256(-params.amountSpecified));
        }
        BalanceDelta delta = manager.swap(key, params, "");
        _close(key.currency0, payer);
        _close(key.currency1, payer);
        return abi.encode(delta);
    }

    function _close(Currency currency, address payer) internal {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) _pay(currency, payer, uint256(-delta));
        else if (delta > 0) manager.take(currency, payer, uint256(delta));
    }

    function _pay(Currency currency, address payer, uint256 amount) internal {
        manager.sync(currency);
        if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), amount);
            manager.settle();
        }
    }

    receive() external payable {}
}
