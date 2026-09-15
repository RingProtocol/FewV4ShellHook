// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice Minimal single-owner access control. The owner is set to `_owner` at construction
///         and can be transferred via `transferOwner`.
abstract contract LpOwner {
    error NotOwner(address caller, address owner);
    error ZeroAddress();

    event OwnerChanged(address indexed previousOwner, address indexed newOwner);

    address public owner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender, owner);
        _;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    /// @notice Transfers ownership to `newOwner`. The new owner must not be the zero address.
    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }
}
