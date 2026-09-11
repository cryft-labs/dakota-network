// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

interface ICodeCanary {
    function registerUniqueIds(address gift, string calldata chainId, uint256 quantity) external payable;
}

/// @notice Development-only gift, call-target and dummy token. Never a production asset.
contract GenesisCanary {
    address public immutable owner;
    address public immutable tester;
    address public immutable codeManager;
    mapping(bytes32 => address) public recipients;
    mapping(address => uint256) public balanceOf;
    uint256 public deliveries;
    uint256 public marker;
    bool public failDelivery;
    modifier onlyOwner() { require(msg.sender == owner, "Only canary owner"); _; }
    constructor(address owner_, address tester_, address manager_, address treasury_) {
        owner = owner_; tester = tester_; codeManager = manager_;
        balanceOf[treasury_] = 100;
    }
    function register(uint256 count) external payable onlyOwner {
        ICodeCanary(codeManager).registerUniqueIds{value: msg.value}(address(this), "112311", count);
    }
    function setFailure(bool fail) external onlyOwner { failDelivery = fail; }
    function recordRedemption(string calldata uid, address recipient) external {
        require(msg.sender == codeManager, "Only CodeManager");
        require(!failDelivery, "Intentional canary failure");
        bytes32 key = keccak256(bytes(uid));
        require(recipients[key] == address(0), "Already delivered");
        recipients[key] = recipient;
        ++deliveries;
    }
    function isUniqueIdRedeemed(string calldata uid) external view returns (bool) {
        return recipients[keccak256(bytes(uid))] != address(0);
    }
    function setMarker(uint256 value) external { require(msg.sender == tester, "Only delegated tester"); marker = value; }
    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient dummy balance");
        balanceOf[msg.sender] -= amount; balanceOf[recipient] += amount; return true;
    }
    receive() external payable {}
}
