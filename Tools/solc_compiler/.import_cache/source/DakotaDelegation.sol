// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
   ___       __        __       ___      __              __  _
  / _ \___ _/ /_____  / /____ _/ _ \___ / /__ ___ ____ _/ /_(_)__  ___
 / // / _ `/  '_/ _ \/ __/ _ `/ // / -_) / -_) _ `/ _ `/ __/ / _ \/ _ \
/____/\_,_/_/\_\\___/\__/\_,_/____/\__/_/\__/\_, /\_,_/\__/_/\___/_//_/
                                            /___/  By: CryftCreator

  Version 1.0 — EIP-7702 Delegation Target  [UPGRADEABLE]

  ┌──────────────── Contract Architecture ───────────────┐
  │                                                      │
  │  Delegation target for EIP-7702 (tx type 0x04).      │
  │  EOAs delegate to this contract to gain smart-       │
  │  account capabilities without creating a separate    │
  │  smart-contract wallet.                              │
  │                                                      │
  │  Features:                                           │
  │    • Single & batch call execution                   │
  │    • Sponsored execution (EIP-712 signed)            │
  │    • Session keys with expiry                        │
  │    • EIP-1271 signature validation                   │
  │    • ERC-721 / ERC-1155 token receiving              │
  │    • ERC-7201 namespaced storage                     │
  │    • Reentrancy protection                           │
  │                                                      │
  │  Security model:                                     │
  │    Only the EOA owner (address(this) in delegated    │
  │    context) or valid session keys can initiate       │
  │    calls.  Sponsored execution requires the owner's  │
  │    EIP-712 signature, nonce, and deadline.           │
  │                                                      │
  │  Upgradeable (Initializable + proxy pattern).        │
  │  Can also re-delegate EOAs via a new type 0x04 tx.  │
  └──────────────────────────────────────────────────────┘
*/

import "../OpenZeppelin_openzeppelin-contracts-upgradeable/v4.9.0/contracts/security/ReentrancyGuardUpgradeable.sol";
import "../OpenZeppelin_openzeppelin-contracts-upgradeable/v4.9.0/contracts/proxy/utils/Initializable.sol";

import "./interfaces/IDakotaDelegation.sol";

contract DakotaDelegation is Initializable, ReentrancyGuardUpgradeable, IDakotaDelegation {

    // ═══════════════════════════════════════════════════════
    //  ERC-7201 Namespaced Storage
    //
    //  Avoids slot collisions if the EOA later re-delegates
    //  to a different contract implementation.
    //  Slot = keccak256("dakota.delegation.v1")
    // ═══════════════════════════════════════════════════════

    bytes32 private constant _STORAGE_SLOT =
        keccak256("dakota.delegation.v1");

    /// @dev All mutable state lives here, anchored at _STORAGE_SLOT.
    struct DelegationState {
        uint256 nonce;                                // sponsored-exec nonce
        mapping(address => bool)    isSessionKey;     // active session keys
        mapping(address => uint256) sessionKeyExpiry;  // expiry timestamps
    }

    // ── EIP-712 Type Hashes ────────────────────────────────

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 private constant _NAME_HASH =
        keccak256("DakotaDelegation");

    bytes32 private constant _VERSION_HASH =
        keccak256("1");

    bytes32 private constant _CALL_TYPEHASH =
        keccak256(
            "Call(address target,uint256 value,bytes data)"
        );

    bytes32 private constant _EXECUTE_SPONSORED_TYPEHASH =
        keccak256(
            "ExecuteSponsored(Call[] calls,uint256 nonce,uint256 deadline)"
            "Call(address target,uint256 value,bytes data)"
        );

    // ── EIP-1271 ───────────────────────────────────────────

    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;

    // ═══════════════════════════════════════════════════════
    //  Initialization
    // ═══════════════════════════════════════════════════════

    /// @notice Initializes the reentrancy guard.  Called once by the proxy.
    function initialize() external initializer {
        __ReentrancyGuard_init();
    }

    // ═══════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════

    /// @dev Only the EOA owner.
    ///      In delegated EIP-7702 context, address(this) == the EOA.
    ///      Self-calls occur when the EOA sends a tx to its own address.
    modifier onlySelf() {
        require(
            msg.sender == address(this),
            "DakotaDelegation: caller is not the account owner"
        );
        _;
    }

    /// @dev Account owner OR a valid (non-expired) session key.
    modifier onlyAuthorized() {
        if (msg.sender != address(this)) {
            DelegationState storage s = _state();
            require(
                s.isSessionKey[msg.sender] &&
                    s.sessionKeyExpiry[msg.sender] > block.timestamp,
                "DakotaDelegation: unauthorized"
            );
        }
        _;
    }

    // ═══════════════════════════════════════════════════════
    //  Execution
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IDakotaDelegation
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    )
        external
        payable
        override
        onlyAuthorized
        nonReentrant
        returns (bytes memory result)
    {
        result = _call(target, value, data);
        emit Executed(target, value, data);
    }

    /// @inheritdoc IDakotaDelegation
    function executeBatch(Call[] calldata calls)
        external
        payable
        override
        onlyAuthorized
        nonReentrant
        returns (bytes[] memory results)
    {
        results = _batchCall(calls);
        emit BatchExecuted(calls.length);
    }

    // ═══════════════════════════════════════════════════════
    //  Sponsored Execution
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IDakotaDelegation
    function executeSponsored(
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        bytes calldata ownerSignature
    )
        external
        payable
        override
        nonReentrant
        returns (bytes[] memory results)
    {
        require(block.timestamp <= deadline, "DakotaDelegation: expired");

        DelegationState storage s = _state();
        require(nonce == s.nonce, "DakotaDelegation: invalid nonce");
        unchecked { s.nonce++; }

        // Build EIP-712 digest and verify the owner's signature
        bytes32 digest = _sponsoredDigest(calls, nonce, deadline);
        address signer  = _recoverSigner(digest, ownerSignature);
        require(
            signer == address(this),
            "DakotaDelegation: invalid sponsor signature"
        );

        results = _batchCall(calls);
        emit SponsoredExecution(msg.sender, nonce, calls.length);
    }

    // ═══════════════════════════════════════════════════════
    //  Session Keys
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IDakotaDelegation
    function addSessionKey(address key, uint256 expiry)
        external
        override
        onlySelf
    {
        require(key != address(0), "DakotaDelegation: zero address");
        require(expiry > block.timestamp, "DakotaDelegation: past expiry");

        DelegationState storage s = _state();
        s.isSessionKey[key]     = true;
        s.sessionKeyExpiry[key] = expiry;
        emit SessionKeyAdded(key, expiry);
    }

    /// @inheritdoc IDakotaDelegation
    function removeSessionKey(address key) external override onlySelf {
        DelegationState storage s = _state();
        s.isSessionKey[key]     = false;
        s.sessionKeyExpiry[key] = 0;
        emit SessionKeyRemoved(key);
    }

    // ═══════════════════════════════════════════════════════
    //  EIP-1271 Signature Validation
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IDakotaDelegation
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view override returns (bytes4) {
        if (
            signature.length == 65 &&
            _recoverSigner(hash, signature) == address(this)
        ) {
            return _EIP1271_MAGIC;
        }
        return 0xffffffff;
    }

    // ═══════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IDakotaDelegation
    function getNonce() external view override returns (uint256) {
        return _state().nonce;
    }

    /// @inheritdoc IDakotaDelegation
    function isValidSessionKey(address key)
        external
        view
        override
        returns (bool)
    {
        DelegationState storage s = _state();
        return s.isSessionKey[key] &&
               s.sessionKeyExpiry[key] > block.timestamp;
    }

    /// @notice Returns the EIP-712 domain separator for this account.
    /// @dev    In EIP-7702 context, address(this) is the delegating EOA,
    ///         so each account has a unique domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ═══════════════════════════════════════════════════════
    //  Token Receivers
    // ═══════════════════════════════════════════════════════

    /// @notice Accept native token transfers.
    receive() external payable {}

    /// @notice ERC-721 safeTransfer callback.
    function onERC721Received(
        address, address, uint256, bytes calldata
    ) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    /// @notice ERC-1155 single transfer callback.
    function onERC1155Received(
        address, address, uint256, uint256, bytes calldata
    ) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    /// @notice ERC-1155 batch transfer callback.
    function onERC1155BatchReceived(
        address, address, uint256[] calldata, uint256[] calldata, bytes calldata
    ) external pure returns (bytes4) {
        return 0xbc197c81;
    }

    // ═══════════════════════════════════════════════════════
    //  Internal Helpers
    // ═══════════════════════════════════════════════════════

    /// @dev Execute a single low-level call; bubble up revert on failure.
    function _call(
        address target,
        uint256 value,
        bytes calldata data
    ) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) _bubbleRevert(ret);
        return ret;
    }

    /// @dev Execute an array of low-level calls sequentially.
    function _batchCall(Call[] calldata calls)
        internal
        returns (bytes[] memory results)
    {
        uint256 len = calls.length;
        results = new bytes[](len);
        for (uint256 i; i < len; ) {
            (bool ok, bytes memory ret) =
                calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) _bubbleRevert(ret);
            results[i] = ret;
            unchecked { ++i; }
        }
    }

    /// @dev Re-throw the revert reason from a failed low-level call.
    function _bubbleRevert(bytes memory returnData) internal pure {
        if (returnData.length > 0) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        revert("DakotaDelegation: call reverted");
    }

    /// @dev ERC-7201 namespaced storage accessor.
    function _state()
        internal
        pure
        returns (DelegationState storage s)
    {
        bytes32 slot = _STORAGE_SLOT;
        assembly { s.slot := slot }
    }

    /// @dev Compute the EIP-712 domain separator.
    ///      Uses address(this) as verifyingContract — in EIP-7702 context
    ///      this is the delegating EOA, giving each account a unique domain.
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                _NAME_HASH,
                _VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    /// @dev Build the EIP-712 typed-data digest for executeSponsored.
    function _sponsoredDigest(
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        uint256 len = calls.length;
        bytes32[] memory callHashes = new bytes32[](len);
        for (uint256 i; i < len; ) {
            callHashes[i] = keccak256(
                abi.encode(
                    _CALL_TYPEHASH,
                    calls[i].target,
                    calls[i].value,
                    keccak256(calls[i].data)
                )
            );
            unchecked { ++i; }
        }

        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        _EXECUTE_SPONSORED_TYPEHASH,
                        keccak256(abi.encodePacked(callHashes)),
                        nonce,
                        deadline
                    )
                )
            )
        );
    }

    /// @dev Recover the signer address from a 65-byte ECDSA signature.
    ///      Enforces EIP-2 low-s requirement.
    function _recoverSigner(
        bytes32 digest,
        bytes calldata sig
    ) internal pure returns (address) {
        require(sig.length == 65, "DakotaDelegation: bad sig length");

        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }

        // EIP-2: restrict s to lower half of secp256k1 curve order
        require(
            uint256(s) <=
                0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "DakotaDelegation: malleable s"
        );
        require(v == 27 || v == 28, "DakotaDelegation: invalid v");

        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0), "DakotaDelegation: invalid sig");
        return recovered;
    }
}
