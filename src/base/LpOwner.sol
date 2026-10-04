// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice Minimal two-step owner access control. The owner is set to `_owner` at construction.
///         Ownership is not transferred until the nominated address accepts it.
abstract contract LpOwner {
    error NotOwner(address caller, address owner);
    error NotPendingOwner(address caller, address pendingOwner);
    error ZeroAddress();

    event OwnerTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnerChanged(address indexed previousOwner, address indexed newOwner);

    address public owner;
    address public pendingOwner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender, owner);
        _;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    /// @notice Nominates `newOwner`. The nominated address must call `acceptOwner`.
    function transferOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnerTransferStarted(owner, newOwner);
    }

    /// @notice Completes a pending ownership transfer.
    function acceptOwner() external {
        address nextOwner = pendingOwner;
        if (msg.sender != nextOwner) revert NotPendingOwner(msg.sender, nextOwner);
        address previousOwner = owner;
        owner = nextOwner;
        pendingOwner = address(0);
        emit OwnerChanged(previousOwner, nextOwner);
    }
}
