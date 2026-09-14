// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Development acceptance fixtures only. Never advertised as customer collections.
interface IInventoryReceiver {
    function onERC721Received(address,address,uint256,bytes calldata) external returns(bytes4);
    function onERC1155Received(address,address,uint256,uint256,bytes calldata) external returns(bytes4);
}
contract InventoryTestNFT {
    string public constant name="Dakota inventory acceptance";
    string public constant symbol="DEVINV";
    address public minter=msg.sender;
    mapping(uint256=>address) private owners;
    mapping(uint256=>string) public tokenURI;
    event Transfer(address indexed from,address indexed to,uint256 indexed tokenId);
    function supportsInterface(bytes4 id) external pure returns(bool){return id==0x01ffc9a7||id==0x80ac58cd||id==0x5b5e139f;}
    function ownerOf(uint256 id) external view returns(address){require(owners[id]!=address(0));return owners[id];}
    function balanceOf(address account) external view returns(uint256){return owners[1]==account?1:0;}
    function mint(address to,uint256 id,string calldata uri) external {require(msg.sender==minter&&to!=address(0)&&owners[id]==address(0));owners[id]=to;tokenURI[id]=uri;emit Transfer(address(0),to,id);}
    function transferFrom(address from,address to,uint256 id) public {require(msg.sender==from&&owners[id]==from&&to!=address(0));owners[id]=to;emit Transfer(from,to,id);}
    function safeTransferFrom(address from,address to,uint256 id) external {transferFrom(from,to,id);if(to.code.length!=0)require(IInventoryReceiver(to).onERC721Received(msg.sender,from,id,"")==0x150b7a02);}
}
contract InventoryTestEdition {
    address public minter=msg.sender;
    mapping(address=>mapping(uint256=>uint256)) private balances;
    string private _uri;
    event TransferSingle(address indexed operator,address indexed from,address indexed to,uint256 id,uint256 value);
    constructor(string memory metadata){_uri=metadata;}
    function uri(uint256) external view returns(string memory){return _uri;}
    function supportsInterface(bytes4 id) external pure returns(bool){return id==0x01ffc9a7||id==0xd9b67a26;}
    function balanceOf(address account,uint256 id) external view returns(uint256){return balances[account][id];}
    function mint(address to,uint256 id,uint256 quantity) external {require(msg.sender==minter&&to!=address(0));balances[to][id]+=quantity;emit TransferSingle(msg.sender,address(0),to,id,quantity);}
    function safeTransferFrom(address from,address to,uint256 id,uint256 quantity,bytes calldata data) external {require(msg.sender==from&&to!=address(0)&&balances[from][id]>=quantity);balances[from][id]-=quantity;balances[to][id]+=quantity;emit TransferSingle(msg.sender,from,to,id,quantity);if(to.code.length!=0)require(IInventoryReceiver(to).onERC1155Received(msg.sender,from,id,quantity,data)==0xf23a6e61);}
}
