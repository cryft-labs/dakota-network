// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.2 <0.9.0;

/*
   ___       _            __       __  ___     __       _____       ___       __
  / _ \____(_)  _____ _  / /____  /  |/  /__ / /____ _/_  _/_ __ / _ \___ _/ /__ ___ __
 / ___/ __/ / |/ / _ `/ / __/ -_) /|_/ / -_) __/ _ `/ / / \\ \/ / , _/ -_) / _ `/ // /
/_/  /_/ /_/|___/\_,_/  \__/\__/_/  /_/\__/\__/\_,_/ /_/ /___/ /_/|_|\__/_/\_,_/\_, /
                                                                                /___/ By: CryftCreator

  Version 1.0 — Private Meta-Transaction Relay  [PENTE PRIVACY GROUP]

  ┌──────────────── Contract Architecture ──────────────────────────────┐
  │                                                                     │
  │  DEPLOYED INSIDE A PALADIN PENTE PRIVACY GROUP.                     │
  │  All state is private to privacy group members.                     │
  │  All configuration is compile-time constant — changes               │
  │  require a contract upgrade via proxy.                              │
  │                                                                     │
  │  Meta-transaction relay for PrivateComboStorage. Enables            │
  │  gas-covered operations where the Paladin signer pays gas           │
  │  on behalf of end users. Users sign EIP-712 typed data              │
  │  off-chain; the admin (Paladin signer) submits the signed           │
  │  payload to this relay, which recovers the original signer          │
  │  and forwards the call using the ERC-2771 trusted forwarder         │
  │  pattern.                                                           │
  │                                                                     │
  │  Flow:                                                              │
  │    1. User signs ForwardRequest (EIP-712) off-chain                 │
  │    2. Any privacy group member calls execute(request, signature)    │
  │    3. Relay verifies signature, increments nonce                    │
  │    4. Relay calls PrivateComboStorage with appended sender          │
  │       (ERC-2771: last 20 bytes of calldata = original signer)      │
  │    5. PrivateComboStorage extracts real sender via _msgSender()     │
  │       and enforces its own access control (ADMIN / AUTHORIZED /    │
  │       UID manager) against the recovered signer                    │
  │                                                                     │
  │  Security model:                                                    │
  │    • The relay itself is open — any privacy group member may        │
  │      submit signed requests on behalf of a signer                  │
  │    • Authorization is enforced by PrivateComboStorage, not the      │
  │      relay — the recovered signer must satisfy the target           │
  │      function's access control (onlyAdmin / onlyAuthorized /       │
  │      per-UID manager check)                                        │
  │    • EIP-712 signatures with per-signer nonces prevent replay       │
  │    • Deadline enforcement prevents stale request execution          │
  │    • EIP-2 low-s check prevents signature malleability              │
  │    • ERC-2771 appended sender preserves authorization semantics     │
  │      in PrivateComboStorage's _msgSender()                         │
  │                                                                     │
  │  Upgradeable via TransparentUpgradeableProxy (OZ 5.2).             │
  │  Patent: U.S. App. Ser. No. 18/930,857                              │
  └─────────────────────────────────────────────────────────────────────┘
*/

import "./Interfaces/IPrivateMetaTxRelay.sol";

contract PrivateMetaTxRelay is IPrivateMetaTxRelay {

    // ── Compile-Time Constants ───────────────────────────────
    //
    //    All configuration is compile-time constant. To change
    //    addresses, deploy a new implementation and upgrade
    //    the proxy.
    //

    /// @dev Admin — the Paladin signer. Retained for potential
    ///      future admin-only relay functions.
    ///      Update via contract upgrade.
    address public constant ADMIN = address(0x01d5E8F6aa4650e571acAa8733F46c3d16fa13cB);

    /// @dev Target contract — PrivateComboStorage proxy address within
    ///      the Pente privacy group. All forwarded calls are routed here.
    ///      Update via contract upgrade.
    address public constant PRIVATE_COMBO_STORAGE = address(0x000000000000000000000000000000000000c0b0);

    // ── EIP-712 Type Hashes ────────────────────────────────

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 private constant _NAME_HASH =
        keccak256("PrivateMetaTxRelay");

    bytes32 private constant _VERSION_HASH =
        keccak256("1");

    bytes32 private constant _FORWARD_REQUEST_TYPEHASH =
        keccak256(
            "ForwardRequest(address from,bytes data,uint256 nonce,uint256 deadline)"
        );

    // ── State ─────────────────────────────────────────────

    /// @dev Per-signer nonce for replay protection. Monotonically
    ///      increasing — consumed on every successful signature verification.
    mapping(address => uint256) private _nonces;

    // ── Constructor ───────────────────────────────────────

    /// @dev No constructor logic needed. All configuration is
    ///      compile-time constant. Upgrades are handled via proxy.

    // ── Execution ─────────────────────────────────────────

    /// @inheritdoc IPrivateMetaTxRelay
    function execute(
        ForwardRequest calldata request,
        bytes calldata signature
    ) external override returns (bytes memory returnData) {
        _verifyAndConsumeNonce(request, signature);

        bool success;
        (success, returnData) = PRIVATE_COMBO_STORAGE.call(
            abi.encodePacked(request.data, request.from)
        );

        if (!success) {
            _bubbleRevert(returnData);
        }

        emit MetaTxExecuted(request.from, request.nonce, returnData);
    }

    /// @inheritdoc IPrivateMetaTxRelay
    function executeBatch(
        ForwardRequest[] calldata requests,
        bytes[] calldata signatures
    ) external override returns (bool[] memory successes, bytes[] memory results) {
        uint256 len = requests.length;
        require(len == signatures.length, "Array length mismatch");
        require(len > 0, "Empty batch");

        successes = new bool[](len);
        results = new bytes[](len);

        for (uint256 i = 0; i < len; ) {
            if (signatures[i].length != 65) {
                emit MetaTxFailed(i, requests[i].from, "Bad signature length");
                unchecked { ++i; }
                continue;
            }

            if (block.timestamp > requests[i].deadline) {
                emit MetaTxFailed(i, requests[i].from, "Expired");
                unchecked { ++i; }
                continue;
            }

            if (requests[i].nonce != _nonces[requests[i].from]) {
                emit MetaTxFailed(i, requests[i].from, "Invalid nonce");
                unchecked { ++i; }
                continue;
            }

            if (!_verifySignature(requests[i], signatures[i])) {
                emit MetaTxFailed(i, requests[i].from, "Invalid signature");
                unchecked { ++i; }
                continue;
            }

            unchecked { ++_nonces[requests[i].from]; }

            (successes[i], results[i]) = PRIVATE_COMBO_STORAGE.call(
                abi.encodePacked(requests[i].data, requests[i].from)
            );

            if (successes[i]) {
                emit MetaTxExecuted(requests[i].from, requests[i].nonce, results[i]);
            } else {
                emit MetaTxFailed(i, requests[i].from, "Call failed");
            }

            unchecked { ++i; }
        }
    }

    // ── Views ─────────────────────────────────────────────

    /// @inheritdoc IPrivateMetaTxRelay
    function getNonce(address from) external view override returns (uint256) {
        return _nonces[from];
    }

    /// @inheritdoc IPrivateMetaTxRelay
    function verify(
        ForwardRequest calldata request,
        bytes calldata signature
    ) external view override returns (bool) {
        return signature.length == 65 &&
            block.timestamp <= request.deadline &&
            request.nonce == _nonces[request.from] &&
            _verifySignature(request, signature);
    }

    /// @inheritdoc IPrivateMetaTxRelay
    function domainSeparator() external view override returns (bytes32) {
        return _domainSeparator();
    }

    // ── Internal Helpers ──────────────────────────────────

    /// @dev Verify the signature, enforce nonce and deadline, then consume the nonce.
    ///      Reverts on any failure — used by single-entry execute().
    function _verifyAndConsumeNonce(
        ForwardRequest calldata request,
        bytes calldata signature
    ) internal {
        require(block.timestamp <= request.deadline, "Expired");
        require(request.nonce == _nonces[request.from], "Invalid nonce");

        bytes32 digest = _forwardRequestDigest(request);
        address signer = _recoverSigner(digest, signature);
        require(signer == request.from, "Invalid signature");

        unchecked { ++_nonces[request.from]; }
    }

    /// @dev Non-reverting signature verification. Returns true only if
    ///      the recovered signer matches request.from. Does NOT check
    ///      nonce or deadline — those are checked separately by callers.
    function _verifySignature(
        ForwardRequest calldata request,
        bytes calldata signature
    ) internal view returns (bool) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        if (
            uint256(s) >
            0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        ) return false;
        if (v != 27 && v != 28) return false;

        bytes32 digest = _forwardRequestDigest(request);
        address recovered = ecrecover(digest, v, r, s);
        return recovered != address(0) && recovered == request.from;
    }

    /// @dev Compute the EIP-712 domain separator.
    ///      Uses address(this) as verifyingContract — in a proxy context
    ///      this is the proxy address, giving each deployment a unique domain.
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

    /// @dev Build the EIP-712 typed-data digest for a ForwardRequest.
    function _forwardRequestDigest(
        ForwardRequest calldata request
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        _FORWARD_REQUEST_TYPEHASH,
                        request.from,
                        keccak256(request.data),
                        request.nonce,
                        request.deadline
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
        require(sig.length == 65, "Bad signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }

        require(
            uint256(s) <=
                0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "Malleable signature"
        );
        require(v == 27 || v == 28, "Invalid v value");

        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0), "Invalid signature");
        return recovered;
    }

    /// @dev Re-throw the revert reason from a failed low-level call.
    function _bubbleRevert(bytes memory returnData) internal pure {
        if (returnData.length > 0) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        revert("Call reverted");
    }
}
