// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import "../src/LimitOrderBatch.sol";

/**
 * @title DeployCore
 * @notice Deployment script for the core LimitOrderBatch contract only
 * @dev Uses hook mining to deploy at the correct address with proper permissions
 */
contract DeployCore is Script {
    
    // Use the correct flags that match hook permissions
    // Based on LimitOrderBatch.getHookPermissions() and Hooks library:
    // - beforeInitialize: true (bit 13)
    // - afterInitialize: true (bit 12) 
    // - beforeSwap: true (bit 7)
    // - afterSwap: true (bit 6)
    uint160 constant BEFORE_INITIALIZE_FLAG = uint160(1 << 13);
    uint160 constant AFTER_INITIALIZE_FLAG = uint160(1 << 12);
    uint160 constant BEFORE_SWAP_FLAG = uint160(1 << 7);
    uint160 constant AFTER_SWAP_FLAG = uint160(1 << 6);
    
    function setUp() public {}
    
    function run() external returns (address coreContract) {
        vm.startBroadcast();
        
        console2.log("=== Deploying Dexter Core Contract ===");
        
        // Get the correct PoolManager address based on the chain
        IPoolManager poolManager;
        
        if (block.chainid == 1) {
            // Ethereum mainnet - use official PoolManager
            poolManager = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        } else if (block.chainid == 11155111) {
            // Sepolia testnet - use official PoolManager
            poolManager = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        } else {
            revert("Unsupported chain - this script only supports mainnet (1) and Sepolia (11155111)");
        }

        // Get fee recipient from environment
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        
        console2.log("Pool Manager:", address(poolManager));
        console2.log("Fee Recipient:", feeRecipient);
        
        // Calculate hook flags
        uint160 flags = BEFORE_INITIALIZE_FLAG | AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG;
        
        // Prepare constructor arguments (tools contract = address(0) initially)
        bytes memory constructorArgs = abi.encode(
            address(poolManager), 
            feeRecipient,
            msg.sender, // Owner address (the broadcaster)
            address(0)  // No tools contract initially
        );
        
        console2.log("Required flags:", flags);
        
        // Use HookMiner to find a valid hook address
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            flags,
            type(LimitOrderBatch).creationCode,
            constructorArgs
        );
        
        console2.log("Predicted hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));
        
        // Deploy using CREATE2 with the found salt
        LimitOrderBatch deployedContract = new LimitOrderBatch{salt: salt}(
            poolManager,
            feeRecipient,
            msg.sender, // Owner address (the broadcaster)
            address(0)  // Tools contract will be set later
        );
        
        require(address(deployedContract) == hookAddress, "Address mismatch!");
        
        console2.log(unicode"✅ Core contract deployed at:", address(deployedContract));
        console2.log(unicode"✅ Ready for tools contract integration");
        
        // Verify hook permissions
        Hooks.Permissions memory permissions = deployedContract.getHookPermissions();
        require(permissions.beforeInitialize, "beforeInitialize not set");
        require(permissions.afterInitialize, "afterInitialize not set");
        require(permissions.beforeSwap, "beforeSwap not set");
        require(permissions.afterSwap, "afterSwap not set");
        console2.log(unicode"✅ Hook permissions verified");
        
        // Display contract info
        console2.log("=== Core Contract Info ===");
        console2.log("Address:", address(deployedContract));
        console2.log("Owner:", deployedContract.owner());
        console2.log("Fee Recipient:", deployedContract.FEE_RECIPIENT());
        console2.log("Tools Contract:", address(deployedContract.toolsContract()));
        console2.log("Contract Size:", type(LimitOrderBatch).creationCode.length, "bytes");
        
        vm.stopBroadcast();
        return address(deployedContract);
    }
    
    // Alternative deployment without hook mining (for testing)
    function deploySimple() external returns (address) {
        vm.startBroadcast();
        
        console2.log("=== Simple Core Deployment (No Hook Mining) ===");
        
        // Get PoolManager and fee recipient
        IPoolManager poolManager;
        if (block.chainid == 1) {
            poolManager = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        } else if (block.chainid == 11155111) {
            poolManager = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        } else {
            revert("Unsupported chain");
        }
        
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        
        LimitOrderBatch coreContract = new LimitOrderBatch(
            poolManager,
            feeRecipient,
            msg.sender, // Owner address (the broadcaster)
            address(0)  // No tools contract
        );
        
        console2.log("Core Contract:", address(coreContract));
        
        vm.stopBroadcast();
        return address(coreContract);
    }
}
