//SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface SmartFinanceHelper {
    // calculates the token amount that will be received after deducting stargate's fees
    function getDstAmountAfterFees (
        uint16 dstChainId,
        address dstSupportToken,
        address srcSupportToken,
        uint256 srcChainTokenAmt
    ) external view returns(uint256);

    // calculates the protocol fees
    function calculateProtocolFees (
        uint256 _amount,
        bool _islocal
    ) external view returns(uint256);

    // gets the fee address where protocol fees is collected
    function feeAddress() external view returns(address);
}

interface SmartFinanceRouter {
    // smart router's functions that calls stargate's router contract to enable cross chain swap
    function sendSwap(
        address initiator,
        bytes memory stargateData,
        bytes memory payload,
        uint256 dstChainReleaseAmt
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

contract SmartSwap is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable{
    using StringHelper for bytes;
    using StringHelper for uint256;

    // Smart Finance Contracts
    address public smartRouter;
    address public smartHelper;

    // Failed Tx Recovery Address.
    address public failedTxRecovery;
    
    // Mapping for supported tokens by stargate
    mapping(address => bool) public isSupportToken;
    // Mapping for decimals for each stargate's supported token of destination chains.
    mapping(uint16 => mapping(address => uint8)) public dstSupportDecimal;

    bool public isWhitelistActive;
    mapping(address => bool) public isWhitelisted;

    address public swapTarget0x;

    event Swap(
        address initiator,
        address buyToken,
        uint256 buyAmount,
        address sellToken,
        uint256 sellAmount,
        address receiver
    );

    function _authorizeUpgrade(address _newImplementation)
        internal
        override
        onlyOwner
    {}

    /// @notice Using this function to initialize the smart swap's parameters
    /// @param _supportToken Address of the stargate supported stable token
    /// @param _recovery account address that can failed transactions to get tokens out of the account  
    function initialize (
        address _supportToken,
        address _recovery
    ) public initializer {
        require(_supportToken != address(0),"Invalid Address");
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        isSupportToken[_supportToken] = true;
        failedTxRecovery = _recovery; 
    }

    receive() external payable {}

    /// @notice withdraw token from the router contract (Only owner can call this fn)
    /// @param _token address of the token owner wishes to withdraw from the contract
    function withdraw(address _token) onlyOwner external {
        require(_token != address(0), "Invalid Address");
        IERC20(_token).transfer(msg.sender, IERC20(_token).balanceOf(address(this)));
    }

    /// @notice function to Pause smart contract.
    function pause() public onlyOwner whenNotPaused {
        _pause();
    }

    /// @notice function to UnPause smart contract
    function unPause() public onlyOwner whenPaused {
        _unpause();
    }

    /// @notice withdraw chain native token from the router contract (Only owner can call this fn)
    function withdrawETH() public onlyOwner {
        address payable to = payable(msg.sender);
        to.transfer(address(this).balance);
    }

    /// @notice updates the 0x Smart Swap target address.
    function updateswapTarget0x(address _swapTarget) public onlyOwner {
        require(address(_swapTarget) != address(0),"No Zero Address");
        swapTarget0x = _swapTarget;
    }

    /// @notice updates the account address which can call the contract to recover failed transactions
    /// @param _recovery account address
    function updateFailedTxRecoveryAddress(address _recovery) public onlyOwner whenNotPaused {
        failedTxRecovery = _recovery;
    }

    function addToWhitelist(address[] calldata _addresses) public onlyOwner {
        require(_addresses.length <= 100,"Whitelist List exceeds allowed limit.");
        for(uint256 i = 0; i < _addresses.length; i++) {
            require(address(_addresses[i]) != address(0),"No Zero Address");
            isWhitelisted[_addresses[i]] = true;
        }
    }

    function removeFromWhitelist(address[] calldata _addresses) public onlyOwner {
        require(_addresses.length <= 100,"Whitelist List exceeds allowed limit.");
        for(uint256 i = 0; i < _addresses.length; i++) {
            require(address(_addresses[i]) != address(0),"No Zero Address");
            isWhitelisted[_addresses[i]] = false;
        }
    } 

    function toggleWhitelistState() external onlyOwner {
        isWhitelistActive = !isWhitelistActive;
    }

    /// @notice updates smart helper contract
    /// @param _helper smart helper contract address
    function updateHelper(
        address _helper
    ) external onlyOwner whenNotPaused {
        require(_helper != address(0),"Invalid Address");
        smartHelper = _helper;
    }

    /// @notice updates smart router contract
    /// @param _router smart router contract address
    function updateRouter(
        address _router
    ) external onlyOwner whenNotPaused {
        require(_router != address(0),"Invalid Address");
        smartRouter = _router;
    }

    /// @notice updates destination chain's supported tokens
    /// @param _dstChainId destination chain id
    /// @param _dstToken stargate supported destination stable token address
    /// @param _dstTokenDecimal token decimals for the token
    function updateDstSupport(
        uint16 _dstChainId,
        address _dstToken,
        uint8 _dstTokenDecimal
    ) external onlyOwner whenNotPaused {
        require(_dstToken != address(0),"Invalid Address");
        dstSupportDecimal[_dstChainId][_dstToken] = _dstTokenDecimal;
    }

    /// @notice updates src chain's support tokens
    /// @param _supportToken stargate supported src stable token address
    function updateSupportToken(
        address _supportToken
    ) external onlyOwner whenNotPaused {
        require(_supportToken != address(0),"Invalid Address");
        isSupportToken[_supportToken] = true;
    }

    /// @notice updates src chain's support tokens
    /// @param _supportToken stargate supported src stable token address
    function removeSupportToken(
        address _supportToken
    ) external onlyOwner whenNotPaused {
        require(_supportToken != address(0),"Invalid Address");
        isSupportToken[_supportToken] = false;
    }



    /// @notice performs local swap from native to token
    /// @param buyToken token address which the user wants to swap the native token for
    /// @param sellAmt amount of native token user wants to swap
    /// @param receiver address where swapped tokens are to be transferred
    /// @param swapTarget 0x protocol's dex address to enable swap
    /// @param swapData byte data containing the local swap information
    function swapNativeForTokens(
        address buyToken,
        uint256 sellAmt,
        address receiver,
        address swapTarget,
        bytes memory swapData
    ) external payable nonReentrant() whenNotPaused {
        if(isWhitelistActive) {
            require(isWhitelisted[msg.sender],"You are NOT Whitelisted");
        }
        // Track balance of the buyToken to determine how much we've bought.
        uint256 currBuyBal = IERC20(buyToken).balanceOf(address(this));

        // Validate swapTarget
        require(address(swapTarget) == address(swapTarget0x),"Invalid Target Address");

        // Swap Token For Token
        (bool success, bytes memory res) = swapTarget.call{value: sellAmt}(swapData);
        require(success, string(bytes('SWAP_CALL_FAILED: ').concat(bytes(res.getRevertMsg()))));

        uint256 boughtBuyAmt = IERC20(buyToken).balanceOf(address(this)) - currBuyBal;

        // Take the fee.
        payable(SmartFinanceHelper(smartHelper).feeAddress()).transfer(SmartFinanceHelper(smartHelper).calculateProtocolFees(sellAmt, true));

        // Transfer the bought amount to the designated address.
        IERC20(buyToken).transfer(receiver, boughtBuyAmt);

        emit Swap(
            msg.sender, 
            buyToken, 
            boughtBuyAmt, 
            address(0), 
            sellAmt, 
            receiver
        );
    }

    /// @notice performs local swap from token to token
    /// @param buyToken token address which the user wants to swap the native token for
    /// @param sellToken token address which the user wantes to sell
    /// @param sellAmt amount of native token user wants to swap
    /// @param spender 0x protocol's dex address to enable swap ### ADD THIS
    /// @param swapTarget 0x protocol's dex address to enable swap
    /// @param receiver address where swapped tokens are to be transferred
    /// @param swapData byte data containing the local swap information
    function swapTokenForToken(
        address buyToken,
        address sellToken,
        uint256 sellAmt, 
        address spender, 
        address swapTarget,
        address receiver,
        bytes memory swapData
    ) public payable nonReentrant() whenNotPaused {
        if(isWhitelistActive) {
            require(isWhitelisted[msg.sender],"You are NOT Whitelisted");
        }
        // Deposit Tokens into the account
        if (msg.sender != smartRouter){
            if(msg.sender != failedTxRecovery) {
                IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmt);
            }
        }

        // We will always validate the sellAmt in form of Token.
        require(IERC20(sellToken).balanceOf(address(this)) >= sellAmt, "Insufficient Balance");

        // Validate Approval
        require(IERC20(sellToken).approve(spender, sellAmt), "Sell Token Approval Failed");

        uint256 currBuyBal = IERC20(buyToken).balanceOf(address(this));

        // Validate swapTarget
        require(address(swapTarget) == address(swapTarget0x),"Invalid Target Address");

        // Swap Token For Token
        (bool success, bytes memory res) = swapTarget.call(swapData);
        require(success, string(bytes('SWAP_CALL_FAILED: ').concat(bytes(res.getRevertMsg()))));

        uint256 boughtBuyAmt = IERC20(buyToken).balanceOf(address(this)) - currBuyBal;

        // Take the fee.
        payable(SmartFinanceHelper(smartHelper).feeAddress()).transfer(SmartFinanceHelper(smartHelper).calculateProtocolFees(sellAmt, true));

        // Transfer the bought amount to the designated address.
        IERC20(buyToken).transfer(receiver, boughtBuyAmt);

        emit Swap(
            msg.sender, 
            buyToken, 
            boughtBuyAmt, 
            sellToken, 
            sellAmt, 
            receiver
        );
    }

    /// @notice performs local swap from token to native
    /// @param sellToken token address which the user wantes to sell
    /// @param sellAmt amount of native token user wants to swap
    /// @param spender 0x protocol's dex address to enable swap ### ADD THIS
    /// @param swapTarget 0x protocol's dex address to enable swap
    /// @param receiver address where swapped tokens are to be transferred
    /// @param swapData byte data containing the local swap information
    function swapTokenForNative(
        address sellToken,
        uint256 sellAmt,
        address spender, 
        address swapTarget,
        address payable receiver,
        bytes memory swapData
    ) public payable nonReentrant() whenNotPaused {
        if(isWhitelistActive) {
            require(isWhitelisted[msg.sender],"You are NOT Whitelisted");
        }
        // Deposit Tokens into the account
        if (msg.sender != smartRouter){
            if(msg.sender != failedTxRecovery) {
                IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmt);
            }
        }
        
        // We will always validate the sellAmt in form of Token.
        require(IERC20(sellToken).balanceOf(address(this)) >= sellAmt, "Insufficient Balance");

        // Validate Approval
        require(IERC20(sellToken).approve(spender, sellAmt), "Sell Token Approval Failed");

        uint256 currBuyBal = address(this).balance;

        // Validate swapTarget
        require(address(swapTarget) == address(swapTarget0x),"Invalid Target Address");

        // Swap Token For ETH
        (bool success, bytes memory res) = swapTarget.call(swapData);
        require(success, string(bytes('SWAP_CALL_FAILED: ').concat(bytes(res.getRevertMsg()))));

        uint256 boughtBuyAmt = address(this).balance - currBuyBal;

        // Take the fee.
        payable(SmartFinanceHelper(smartHelper).feeAddress()).transfer(SmartFinanceHelper(smartHelper).calculateProtocolFees(sellAmt, true));
        
        // Transfer ETH to the designated address.
        receiver.transfer(boughtBuyAmt);
        
        emit Swap(
            msg.sender, 
            address(0), 
            boughtBuyAmt, 
            sellToken, 
            sellAmt, 
            receiver
        );
    }
    // Helper Functions
    /// @notice creates destination payload to enable swapping to enable user to get the desired token on the destination chain
    /// @dev return payload to enable swapping to enable user to get the desired token on the destination chain
    /// @param dstChainId stargate's destination chain id
    /// @param srcChainToken stargate's src chain stable token
    /// @param srcChainReleaseAmt stargate's src chain stable token amount
    /// @param dstChainSwapData encoded data with information of destination local swap
    function _createDstChainPayload(
        uint16 dstChainId,
        address srcChainToken,
        uint256 srcChainReleaseAmt,
        bytes memory dstChainSwapData
    ) internal view returns (bytes memory payload) {
        (
            address dstChainSupportToken,
            address dstChainToken,
            uint256 dstChainAmount,
            address spender,
            address swapTarget,
            address payable dstReceiver,
            bytes memory swapData
        ) = abi.decode(dstChainSwapData, (address, address, uint256, address, address, address, bytes));

        // Determine the releaseAmt for Destination
        {
            // Normalising the value to 6 decimals.
            srcChainReleaseAmt = srcChainReleaseAmt * 10**6 / (10**IERC20(srcChainToken).decimals());
            uint256 afterStargateFees = SmartFinanceHelper(smartHelper).getDstAmountAfterFees(
                dstChainId,
                dstChainSupportToken,
                srcChainToken,
                srcChainReleaseAmt
            );
            // After Protocol Fees
            afterStargateFees = afterStargateFees - SmartFinanceHelper(smartHelper).calculateProtocolFees(afterStargateFees, false);
            // After Stargate Fees
            afterStargateFees = afterStargateFees * (10**dstSupportDecimal[dstChainId][dstChainSupportToken]) / 10**6;
            // Check if the release amount at destination is greater than what we anticipate.
            require(afterStargateFees >= dstChainAmount,"Insufficient Destination Amount");
        }


        if(dstChainToken == address(0)){
            // Native at Destination
            bytes memory actionObject = abi.encode(
                dstChainSupportToken,
                dstChainAmount,
                spender,
                swapTarget,
                dstReceiver,
                swapData
            );

            return (
                abi.encode(
                    msg.sender,
                    uint16(3),
                    actionObject
                )
            );
        } else if(dstChainToken == dstChainSupportToken) {
            // Support Token at Destination
            bytes memory actionObject = abi.encode(
                dstChainSupportToken,
                dstChainAmount,
                dstReceiver
            );

            return (
                abi.encode(
                    msg.sender,
                    uint16(1),
                    actionObject
                )
            );
        } else {
            // Token at Destination
            bytes memory actionObject = abi.encode(
                dstChainToken,
                dstChainSupportToken,
                dstChainAmount,
                spender,
                swapTarget,
                dstReceiver,
                swapData
            );

            return (
                abi.encode(
                    msg.sender,
                    uint16(2),
                    actionObject
                )
            );
        }
    }

    // Cross Swap
    /// @notice performs cross chain swap from native on src chain to token on destination chain
    /// @param dstChainId stargate's destination chain id
    /// @param srcChainSwapData encoded data with information of src chain local swap
    /// @param dstChainSwapData encoded data with information of destination chain local swap
    /// @param stargateData encoded data with information of stargate cross chain swap
    function sendCrossSwapNativeForToken(
        uint16 dstChainId,
        bytes memory srcChainSwapData,
        bytes memory dstChainSwapData,
        bytes memory stargateData
    ) external payable nonReentrant() whenNotPaused {
        if(isWhitelistActive) {
            require(isWhitelisted[msg.sender],"You are NOT Whitelisted");
        }
        // Break the Src Chain Swap Data
        (
            uint256 sellAmt,
            address srcBuyToken,
            address swapTarget,
            bytes memory swapData
        ) = abi.decode(srcChainSwapData, (uint256, address, address, bytes));

        uint256 balance = IERC20(srcBuyToken).balanceOf(address(this));

        require(isSupportToken[srcBuyToken],"Not Support Token");

        // Swap Native for Support Token
        {
            // Validate swapTarget
            require(address(swapTarget) == address(swapTarget0x),"Invalid Target Address");

            // Swap Native For Token
            (bool success, bytes memory res) = swapTarget.call{value: sellAmt}(swapData);
            require(success, string(bytes('SWAP_CALL_FAILED: ').concat(bytes(res.getRevertMsg()))));
        }

        // Updated Balance
        balance = IERC20(srcBuyToken).balanceOf(address(this)) - balance;

        // Create Payload for Destination
        bytes memory payload = _createDstChainPayload(
            dstChainId,
            srcBuyToken,
            balance, 
            dstChainSwapData
        );

        // Transfer tokens to smartRouter
        IERC20(srcBuyToken).transfer(smartRouter, balance);
        // Sends the native token along with destination payload to enable swap on the destination chain
        SmartFinanceRouter(smartRouter).sendSwap{value: msg.value - sellAmt}(
            msg.sender,
            stargateData, 
            payload,
            balance
        );

    }

    /// @notice performs cross chain swap from non-native on src chain to token on destination chain
    /// @param dstChainId stargate's destination chain id
    /// @param srcChainSwapData encoded data with information of src chain local swap
    /// @param dstChainSwapData encoded data with information of destination chain local swap
    /// @param stargateData encoded data with information of stargate cross chain swap
    function sendCrossSwapTokenForToken(
        uint16 dstChainId,
        bytes memory srcChainSwapData,
        bytes memory dstChainSwapData,
        bytes memory stargateData
    ) external payable nonReentrant() whenNotPaused {
        if(isWhitelistActive) {
            require(isWhitelisted[msg.sender],"You are NOT Whitelisted");
        }
        // Break the Src Chain Swap Data
        (
            address srcSellToken,
            uint256 sellAmt,
            address srcBuyToken,
            address swapTarget,
            address spender,
            bytes memory swapData
        ) = abi.decode(srcChainSwapData, (address, uint256, address, address, address, bytes));

        // Transfer Tokens
        IERC20(srcSellToken).transferFrom(msg.sender, address(this), sellAmt);

        uint256 balance = IERC20(srcBuyToken).balanceOf(address(this));

        require(isSupportToken[srcBuyToken],"Not Support Token");

        if(isSupportToken[srcSellToken]){
            // Update Balance to the support Token Sell Amt.
            balance = sellAmt;
        } else 
        {
            // Swap Token for Support Token
            {
                // Validate Approval
                require(IERC20(srcSellToken).approve(spender, sellAmt), "Sell Token Approval Failed");

                // Validate swapTarget
                require(address(swapTarget) == address(swapTarget0x),"Invalid Target Address");

                // Swap Token For Token
                (bool success, bytes memory res) = swapTarget.call(swapData);
                require(success, string(bytes('SWAP_CALL_FAILED: ').concat(bytes(res.getRevertMsg()))));
            }

            // Updated Balance
            balance = IERC20(srcBuyToken).balanceOf(address(this)) - balance;
        }
        
        // Create Payload for Destination
        bytes memory payload = _createDstChainPayload(
            dstChainId,
            srcBuyToken,
            balance, 
            dstChainSwapData
        );

        // Transfer tokens to smartRouter
        IERC20(srcBuyToken).transfer(smartRouter, balance);

        // Sends the native token along with destination payload to enable swap on the destination chain
        SmartFinanceRouter(smartRouter).sendSwap{value: msg.value}(
            msg.sender,
            stargateData, 
            payload,
            balance
        );
    }

    /// @notice receives payload from the smart router on the destination chain to enable swapping of received stargate supported tokens into the token the user wants
    /// @param amountLD amount received from stargate's router
    /// @param payload encoded data containing information for local swap
    function receivePayload(
        uint256 amountLD,
        bytes memory payload
    ) external payable {
        require(msg.sender == smartRouter,"Only SmartFinanceRouter");
        (
            ,
            uint16 actionType,
            bytes memory actionObject
        ) = abi.decode(payload, (address, uint16, bytes));

        if(actionType == uint16(1)){
            (
                address token,
                ,
                address receiver
            ) = abi.decode(actionObject, (address, uint256, address));

            {
                // Send to the receiver
                uint256 fee = SmartFinanceHelper(smartHelper).calculateProtocolFees(amountLD, false);

                // Send Tokens
                IERC20(token).transfer(receiver, amountLD-fee);

                // Send TOkensxs
                IERC20(token).transfer(SmartFinanceHelper(smartHelper).feeAddress(), fee);
            }
        } else if(actionType == uint16(2)) {
            (
                address buyToken,
                address sellToken,
                uint256 sellAmt,
                address spender,
                address swapTarget,
                address receiver,
                bytes memory swapData
            ) = abi.decode(actionObject, (address, address, uint256, address, address, address, bytes));

            // Swap Support Token for Designated Token
            {
                // Get the ideal balance of the contract before transfer from Router.
                uint256 idealBalance = IERC20(sellToken).balanceOf(address(this)) - amountLD;

                // We will always validate the sellAmt.
                require(idealBalance + amountLD >= sellAmt, "Insufficient Balance");

                // Validate Approval
                require(IERC20(sellToken).approve(spender, sellAmt), "Sell Token Approval Failed");

                uint256 currBuyBal = IERC20(buyToken).balanceOf(address(this));

                // Validate swapTarget
                require(address(swapTarget) == address(swapTarget0x),"Invalid Target Address");

                // Swap Token For Token
                (bool success, bytes memory res) = swapTarget.call(swapData);
                require(success, string(bytes('SWAP_CALL_FAILED: ').concat(bytes(res.getRevertMsg()))));

                uint256 boughtBuyAmt = IERC20(buyToken).balanceOf(address(this)) - currBuyBal;

                // Calculate Fee
                uint256 fee = IERC20(sellToken).balanceOf(address(this)) - idealBalance;
                require(fee >= SmartFinanceHelper(smartHelper).calculateProtocolFees(sellAmt, false), "Service Fee too low.");
                
                // Transfer the bought amount to the designated address.
                IERC20(buyToken).transfer(receiver, boughtBuyAmt);

                // Transfer the fees to feeAddress
                IERC20(sellToken).transfer(SmartFinanceHelper(smartHelper).feeAddress(), fee);
            }
        } else {
            (
                address sellToken,
                uint256 sellAmt,
                address spender,
                address swapTarget,
                address payable receiver,
                bytes memory swapData
            ) = abi.decode(actionObject, (address, uint256, address, address, address, bytes));
            
            // Swap Support Tokens For Native Asset
            {
                // Get the ideal balance of the contract before transfer from Router.
                uint256 idealBalance = IERC20(sellToken).balanceOf(address(this)) - amountLD;

                // We will always validate the sellAmt.
                require(idealBalance + amountLD >= sellAmt, "Insufficient Balance");

                // Validate Approval
                require(IERC20(sellToken).approve(spender, sellAmt), "Sell Token Approval Failed");

                uint256 currBuyBal = address(this).balance;

                // Validate swapTarget
                require(address(swapTarget) == address(swapTarget0x),"Invalid Target Address");
                
                // Swap Token For Token
                (bool success, bytes memory res) = swapTarget.call(swapData);
                require(success, string(bytes('SWAP_CALL_FAILED: ').concat(bytes(res.getRevertMsg()))));

                uint256 boughtBuyAmt = address(this).balance - currBuyBal;

                // Calculate Fee
                uint256 fee = IERC20(sellToken).balanceOf(address(this)) - idealBalance;
                require(fee >= SmartFinanceHelper(smartHelper).calculateProtocolFees(sellAmt, false), "Service Fee too low.");
                
                // Transfer the bought amount to the designated address.
                receiver.transfer(boughtBuyAmt);

                // Transfer the fees to feeAddress
                IERC20(sellToken).transfer(SmartFinanceHelper(smartHelper).feeAddress(), fee);
            }
        }
    }
}