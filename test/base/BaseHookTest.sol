// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/testing/LimitOrderBatchDev.sol";
import "../mocks/MockContracts.sol";
import {HookMiner} from "../../lib/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/**
 * @title BaseHookTest
 * @notice Base test contract that properly deploys LimitOrderBatchDev as a hook
 */
abstract contract BaseHookTest is Test {
    LimitOrderBatchDev public limitOrderBatch;
    MockPoolManager public mockPoolManager;
    address public feeRecipient = address(0x999);
    
    uint160 constant AFTER_SWAP_FLAG = uint160(0x40); // bit 6

    function setUp() public virtual {
        mockPoolManager = new MockPoolManager();
        
        // Deploy LimitOrderBatch hook with proper CREATE2 address
        _deployHookWithValidAddress();
    }
    
    function _deployHookWithValidAddress() internal {
        uint160 flags = AFTER_SWAP_FLAG;
        
        // Prepare constructor arguments
        bytes memory constructorArgs = abi.encode(address(mockPoolManager), feeRecipient);
        
        // Mine a salt that will produce a hook address with the correct flags
        // Use address(this) as deployer instead of CREATE2_DEPLOYER for tests
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(LimitOrderBatchDev).creationCode,
            constructorArgs
        );
        
        // Deploy using CREATE2 with the proper salt  
        // Cast the mock to IPoolManager interface for testing
        limitOrderBatch = new LimitOrderBatchDev{salt: salt}(IPoolManager(address(mockPoolManager)), feeRecipient);
        
        // Verify the address matches
        require(address(limitOrderBatch) == hookAddress, "Hook address mismatch");
        
        // Verify hook permissions
        Hooks.Permissions memory permissions = limitOrderBatch.getHookPermissions();
        require(permissions.afterSwap, "afterSwap should be enabled");
    }
}
