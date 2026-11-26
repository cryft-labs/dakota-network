// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
pragma solidity >=0.8.20 <0.9.0;

import "./GasSponsor.sol";

/// @notice GasSponsor 1.2: mandatory platform-approved contract/function sponsorship.
/// @dev New isolated storage; inherited account balances, limits and roles are unchanged.
/// Approval is not safe for arbitrary forwarding, upgrade or deployment functions.
/// Review every allowed method and all downstream calls before admitting it.
contract ApprovedGasSponsor is GasSponsor {
    address private constant _APPROVAL_PROXY_ADMIN = 0x0000000000000000000000000000000000FacAdE;
    address public constant CANONICAL_CODE_MANAGER = 0x000000000000000000000000000000000000c0DE;
    bytes32 private constant _APPROVAL_SLOT = keccak256("cryft.storage.ApprovedGasSponsor.v1");

    struct CallApproval {
        bytes32 codeHash;
        address implementation; // Zero only for a reviewed, non-upgradeable contract.
        bytes32 implementationHash;
        uint256 maxValue;
        bool canonicalManagerRequired;
        address proxyReader;
        bytes32 proxyReaderHash;
    }
    struct Permission {
        address target;
        bytes4 selector;
        CallApproval approval;
    }
    struct ApprovalStorage {
        bool initialized;
        mapping(address => mapping(bytes4 => CallApproval)) calls;
    }
    error CallNotApproved(address target, bytes4 selector);
    error InvalidApproval();
    error ApprovalInitializationDenied();
    event CallApprovalUpdated(address indexed target, bytes4 indexed selector, bytes32 codeHash,
        address implementation, bytes32 implementationHash, uint256 maxValue, bool canonicalManagerRequired,
        address proxyReader, bytes32 proxyReaderHash);

    // GasSponsor 1.5.1 (2026-11-23): initializeCallApprovals is gone (the 32 KB budget). The platform administrator's
    // setCallApprovals seeds and changes approvals alike; `initialized` stays in the struct, unread (0x…FEeD holds 1 there).

    /// @notice Only platform governance grants/revokes approval. No tenant-level bypass.
    /// Revocation uses a zero codeHash and remains possible when a target is broken.
    function setCallApprovals(Permission[] calldata permissions) external onlyPlatformAdmin {
        _setApprovals(permissions);
    }

    function getCallApproval(address target, bytes4 selector) external view returns (CallApproval memory) {
        return _approvals().calls[target][selector];
    }

    function approvedCall(address target, uint256 value, bytes calldata data) external view returns (bool) {
        return data.length >= 4 && _approved(target, value, bytes4(data[:4]));
    }

    function _setApprovals(Permission[] calldata permissions) private {
        if (permissions.length == 0 || permissions.length > 64) revert InvalidApproval();
        for (uint256 i; i < permissions.length; ++i) {
            Permission calldata p = permissions[i];
            if (p.target == address(0) || p.target == address(this) || p.selector == bytes4(0)) revert InvalidApproval();
            if (p.approval.codeHash != bytes32(0)) {
                if (p.target.code.length == 0 || p.target.code.length == 23 || p.target.codehash != p.approval.codeHash)
                    revert InvalidApproval();
                if ((p.approval.implementation == address(0)) != (p.approval.implementationHash == bytes32(0)))
                    revert InvalidApproval();
                if ((p.approval.implementation == address(0)) != (p.approval.proxyReader == address(0))
                    || (p.approval.proxyReader == address(0)) != (p.approval.proxyReaderHash == bytes32(0))) revert InvalidApproval();
                if (p.approval.proxyReader != address(0) && (p.approval.proxyReader.code.length == 0
                    || p.approval.proxyReader.codehash != p.approval.proxyReaderHash)) revert InvalidApproval();
                // A genesis proxy cannot be admitted as if it were immutable.
                address implementation = _implementation(p.target, p.approval.proxyReader == address(0)
                    ? _APPROVAL_PROXY_ADMIN : p.approval.proxyReader);
                if (implementation != p.approval.implementation) revert InvalidApproval();
                if (implementation != address(0) && (implementation.code.length == 0
                    || implementation.codehash != p.approval.implementationHash)) revert InvalidApproval();
                // 1.5.2 (X-66): nor any other upgradeable proxy. A contract that may be read as immutable (no implementation)
                // must not carry the EIP-1967 implementation or beacon slot in its code (OZ transparent, UUPS, beacon proxies).
                if (implementation == address(0) && _hasProxySlot(p.target)) revert InvalidApproval();
            }
            _approvals().calls[p.target][p.selector] = p.approval;
            emit CallApprovalUpdated(p.target, p.selector, p.approval.codeHash, p.approval.implementation,
                p.approval.implementationHash, p.approval.maxValue, p.approval.canonicalManagerRequired,
                p.approval.proxyReader, p.approval.proxyReaderHash);
        }
    }

    /// @dev Whether `target`'s code holds PUSH32 of the EIP-1967 implementation slot or beacon slot. EVM code cannot read another
    /// contract's storage, so the code is scanned instead: every OpenZeppelin-style proxy (and UUPS implementation) pushes its slot
    /// constant. Bounded: at most the code size (<= 32,768 bytes on Cryft), admin-only. A false positive only refuses an approval.
    function _hasProxySlot(address target) private view returns (bool found) {
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 beaconSlot = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
        bytes memory code = target.code;
        uint256 length = code.length;
        if (length < 33) return false;
        assembly ("memory-safe") {
            let start := add(code, 32)
            let last := add(start, sub(length, 33))
            for { let at := start } iszero(gt(at, last)) { at := add(at, 1) } {
                if eq(byte(0, mload(at)), 0x7f) {
                    let word := mload(add(at, 1))
                    if or(eq(word, implementationSlot), eq(word, beaconSlot)) { found := 1 break }
                }
            }
        }
    }

    function _implementation(address target, address reader) private view returns (address result) {
        (bool ok, bytes memory data) = reader.staticcall{gas: 100000}(
            abi.encodeWithSignature("getProxyImplementation(address)", target));
        if (ok && data.length == 32) result = abi.decode(data, (address));
    }

    function _approved(address target, uint256 value, bytes4 selector) private view returns (bool) {
        CallApproval storage p = _approvals().calls[target][selector];
        if (p.codeHash == bytes32(0) || target.codehash != p.codeHash || value > p.maxValue) return false;
        if (p.implementation != address(0) && (p.proxyReader.codehash != p.proxyReaderHash
            || _implementation(target, p.proxyReader) != p.implementation
            || p.implementation.codehash != p.implementationHash)) return false;
        if (p.canonicalManagerRequired) {
            (bool ok, bytes memory result) = target.staticcall{gas: 100000}(abi.encodeWithSignature("codeManagerAddress()"));
            if (!ok || result.length != 32 || abi.decode(result, (address)) != CANONICAL_CODE_MANAGER) return false;
        }
        return true;
    }

    function _validateSponsoredTargets(bytes calldata data) internal view virtual override {
        _requireApprovedCalls(_calls(data));
    }

    /// @dev Every call of the (validated) execution envelope is a platform-approved (target, selector, value). GasSponsor
    /// 1.5.1 (ProgramGasSponsor) calls it for every sponsor but a developer program's.
    function _requireApprovedCalls(ICryftDelegation.Call[] memory calls) internal view {
        for (uint256 i; i < calls.length; ++i) {
            ICryftDelegation.Call memory item = calls[i];
            bytes4 selector = bytes4(item.data);
            if (item.data.length < 4 || !_approved(item.target, item.value, selector)) revert CallNotApproved(item.target, selector);
        }
    }

    /// @dev The envelope's calls (its shape is validated before this runs): 1 to 32 of them. 1.5.2: decoded in one place.
    function _calls(bytes calldata executionData) internal pure returns (ICryftDelegation.Call[] memory calls) {
        (ICryftDelegation.SponsoredExecutionRequest memory request,) =
            abi.decode(executionData[4:], (ICryftDelegation.SponsoredExecutionRequest, bytes));
        calls = request.calls;
        if (calls.length == 0 || calls.length > 32) revert InvalidExecutionEnvelope();
    }

    function _approvals() private pure returns (ApprovalStorage storage state) {
        bytes32 slot = _APPROVAL_SLOT;
        assembly ("memory-safe") { state.slot := slot }
    }
}
