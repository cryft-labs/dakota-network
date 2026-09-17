// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;
contract AllocationReceiver {
    bool public reject;
    bytes public attempt;
    bool public reentryBlocked;
    function configure(bool reject_, bytes calldata attempt_) external { reject = reject_; attempt = attempt_; }
    function onERC1155Received(address,address,uint256,uint256,bytes calldata) external returns (bytes4) {
        require(!reject, "test receiver rejection");
        if (attempt.length != 0) { (bool ok,) = msg.sender.call(attempt); require(!ok, "unexpected reentry"); reentryBlocked = true; }
        return 0xf23a6e61;
    }
}
