pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


interface smartswap{

    function sendCrossSwapNativeForToken(
        uint16 dstChainId,
        bytes memory srcChainSwapData,
        bytes memory dstChainSwapData,
        bytes memory stargateData
    ) external payable;

    function sendCrossSwapTokenForToken(
        uint16 dstChainId,
        bytes memory srcChainSwapData,
        bytes memory dstChainSwapData,
        bytes memory stargateData
    ) external payable;

    function receivePayload(
        uint256 amountLD,
        bytes memory payload
    ) external payable;
}

library StringHelper {
    function concat(
        bytes memory a,
        bytes memory b
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(a, b);
    }
    
    function getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        if (_returnData.length < 68) return 'Transaction reverted silently';
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}

contract smartpay is Ownable, ReentrancyGuard{

    address public smartRouter;
    address public smartHelper;

    function sendTokenForNFT(
        uint16 dstChainId,
        bytes memory srcChainSwapData,
        bytes memory dstChainSwapData,
        bytes memory stargateData
    )external payable nonReentrant(){

    }

    function sendNativeForNFT(
        uint16 dstChainId,
        bytes memory srcChainSwapData,
        bytes memory dstChainSwapData,
        bytes memory stargateData
    )external payable nonReentrant(){

    }

    function mintNFT(
        uint256 amountLD,
        bytes memory payload
    )external payable{
        
    }
}