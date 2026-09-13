// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023-2026 Cryft Labs. All rights reserved.
// This software is part of a patented system. See LICENSE and PATENT NOTICE.
// Licensed under the Apache License, Version 2.0.

pragma solidity >=0.8.20 <0.9.0;

/*
  MomentCardAccount — ERC-6551 account for moment.cards inventories

  Bound to one parent ERC-721 through the ERC-6551 registry proxy footer.
  Ownership is the current ownerOf(parent). Transfer of the card transfers
  control immediately. Burn of the parent makes ownerOf revert and locks
  execute. Nested CARD NFTs from the parent collection are rejected.
*/

import "./Interfaces/IERC6551Account.sol";
import "./Interfaces/IERC6551Executable.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title MomentCardAccount
/// @notice Token-bound account for moment.cards inventories.
/// @dev Deployed as an ERC-1167 proxy by ERC6551Registry. Direct calls to this
///      implementation are rejected. Only CALL execution is enabled.
contract MomentCardAccount is IERC6551Account, IERC6551Executable {
    error DirectImplementationCall();
    error InvalidSigner();
    error InvalidSignature();
    error Expired();
    error InvalidNonce(uint256 expected, uint256 supplied);
    error OperationNotSupported(uint8 operation);
    error NestedCardNft(address tokenContract, uint256 tokenId);
    error ReentrantExecution();
    error TokenBoundMismatch();

    bytes4 private constant _ERC165_ID = 0x01ffc9a7;
    bytes4 private constant _ERC721_RECEIVER_ID = 0x150b7a02;
    bytes4 private constant _ERC1155_RECEIVER_ID = 0x4e2312e0;
    bytes4 private constant _ERC1155_ACCEPTED = 0xf23a6e61;
    bytes4 private constant _ERC1155_BATCH_ACCEPTED = 0xbc197c81;
    bytes4 private constant _EIP1271_MAGIC = 0x1626ba7e;
    bytes4 private constant _EIP1271_FAIL = 0xffffffff;
    bytes4 private constant _SIGNER_MAGIC = 0x523e3260;

    uint256 private constant _MAX_VALID_S =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256("MomentCardAccount");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 private constant _EXECUTE_TYPEHASH = keccak256(
        "Execute(address to,uint256 value,bytes data,uint8 operation,uint256 nonce,uint256 deadline)"
    );

    /// @notice Application salt for moment.cards TBA derivation.
    bytes32 public constant APPLICATION_SALT = keccak256("moment.cards:tba:v1");

    uint256 private _state;
    uint256 private _reentrancyStatus;
    address private immutable _implementation;

    event Executed(
        address indexed operator,
        address indexed to,
        uint256 value,
        uint8 operation,
        uint256 nonce
    );

    constructor() {
        _implementation = address(this);
    }

    modifier onlyProxy() {
        if (address(this) == _implementation) {
            revert DirectImplementationCall();
        }
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == 1) {
            revert ReentrantExecution();
        }
        _reentrancyStatus = 1;
        _;
        _reentrancyStatus = 0;
    }

    receive() external payable {
        if (address(this) == _implementation) {
            revert DirectImplementationCall();
        }
    }

    /// @inheritdoc IERC6551Executable
    function execute(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external payable override onlyProxy nonReentrant returns (bytes memory result) {
        if (!_isValidSigner(msg.sender)) {
            revert InvalidSigner();
        }
        result = _execute(msg.sender, to, value, data, operation);
    }

    /// @notice Replay-protected signed execute with an expiry.
    /// @dev `nonce` must equal `state()`. The recovered signer must be the
    ///      current parent NFT owner. Anyone may submit the signature.
    function executeSigned(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external payable onlyProxy nonReentrant returns (bytes memory result) {
        if (block.timestamp > deadline) {
            revert Expired();
        }
        if (nonce != _state) {
            revert InvalidNonce(_state, nonce);
        }
        address signer = _recover(_executeDigest(to, value, data, operation, nonce, deadline), signature);
        if (signer == address(0) || !_isValidSigner(signer)) {
            revert InvalidSignature();
        }
        result = _execute(signer, to, value, data, operation);
    }

    /// @inheritdoc IERC6551Account
    function token()
        public
        view
        override
        returns (uint256 chainId, address tokenContract, uint256 tokenId)
    {
        if (address(this) == _implementation) {
            revert DirectImplementationCall();
        }
        bytes memory footer = new bytes(0x60);
        assembly ("memory-safe") {
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }
        return abi.decode(footer, (uint256, address, uint256));
    }

    /// @inheritdoc IERC6551Account
    function state() external view override returns (uint256) {
        return _state;
    }

    /// @inheritdoc IERC6551Account
    function isValidSigner(
        address signer,
        bytes calldata
    ) external view override returns (bytes4 magicValue) {
        if (address(this) == _implementation) {
            revert DirectImplementationCall();
        }
        if (_isValidSigner(signer)) {
            return _SIGNER_MAGIC;
        }
    }

    /// @notice Current holder of the parent ERC-721. Reverts if the token is burned.
    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) {
            revert TokenBoundMismatch();
        }
        return IERC721Owner(tokenContract).ownerOf(tokenId);
    }

    function isValidSignature(
        bytes32 digest,
        bytes calldata signature
    ) external view returns (bytes4) {
        if (address(this) == _implementation) {
            revert DirectImplementationCall();
        }
        address recovered = _recover(digest, signature);
        if (recovered != address(0) && recovered == owner()) {
            return _EIP1271_MAGIC;
        }
        return _EIP1271_FAIL;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == _ERC165_ID ||
            interfaceId == type(IERC6551Account).interfaceId ||
            interfaceId == type(IERC6551Executable).interfaceId ||
            interfaceId == _EIP1271_MAGIC ||
            interfaceId == _ERC721_RECEIVER_ID ||
            interfaceId == _ERC1155_RECEIVER_ID;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    function getExecuteDigest(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _executeDigest(to, value, data, operation, nonce, deadline);
    }

    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    ) external view onlyProxy returns (bytes4) {
        _rejectNestedCard(msg.sender, tokenId);
        return _ERC721_RECEIVER_ID;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external view onlyProxy returns (bytes4) {
        return _ERC1155_ACCEPTED;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view onlyProxy returns (bytes4) {
        return _ERC1155_BATCH_ACCEPTED;
    }

    function _execute(
        address operator,
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) private returns (bytes memory result) {
        if (operation != 0) {
            revert OperationNotSupported(operation);
        }

        uint256 nonce = _state;
        unchecked {
            _state = nonce + 1;
        }

        bool success;
        (success, result) = to.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }

        _rejectIfParentHeld();
        emit Executed(operator, to, value, operation, nonce);
    }

    function _rejectNestedCard(address tokenContract, uint256 tokenId) private view {
        (, address parentContract,) = token();
        if (tokenContract == parentContract) {
            revert NestedCardNft(tokenContract, tokenId);
        }
    }

    function _rejectIfParentHeld() private view {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) {
            return;
        }
        if (IERC721Owner(tokenContract).ownerOf(tokenId) == address(this)) {
            revert NestedCardNft(tokenContract, tokenId);
        }
    }

    function _isValidSigner(address signer) private view returns (bool) {
        return signer != address(0) && signer == owner();
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
        );
    }

    function _executeDigest(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 nonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(_EXECUTE_TYPEHASH, to, value, keccak256(data), operation, nonce, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _recover(
        bytes32 digest,
        bytes calldata signature
    ) private pure returns (address recovered) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (signature.length == 65) {
            assembly ("memory-safe") {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 0x20))
                v := byte(0, calldataload(add(signature.offset, 0x40)))
            }
            if (v < 27) {
                unchecked {
                    v += 27;
                }
            }
        } else if (signature.length == 64) {
            bytes32 vs;
            assembly ("memory-safe") {
                r := calldataload(signature.offset)
                vs := calldataload(add(signature.offset, 0x20))
            }
            s = vs & bytes32(
                0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
            );
            v = uint8((uint256(vs) >> 255) + 27);
        } else {
            return address(0);
        }

        if (uint256(s) > _MAX_VALID_S || (v != 27 && v != 28)) {
            return address(0);
        }
        recovered = ecrecover(digest, v, r, s);
    }
}
