// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import "../src/LimitOrderBatch.sol";
import "../src/LimitOrderBatchTools.sol";

/**
 * @title DeployUnified
 * @notice Unified deployment script for the complete modular batch order system
 * @dev Deploys core contract first, then tools contract, and links them together
 */
contract DeployUnified is Script {
    
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
    
    struct DeploymentResult {
        address coreContract;
        address toolsContract;
        uint160 hookFlags;
        bytes32 salt;
        bool linked;
    }
    
    function setUp() public {}
    
    function run() external returns (DeploymentResult memory result) {
        vm.startBroadcast();
        
        console2.log("=== Deploying Complete Dexter Batch Order System ===");
        console2.log("Deployer address:", msg.sender);
        
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
        
        // Step 1: Calculate hook address with proper permissions
        uint160 flags = BEFORE_INITIALIZE_FLAG | AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG;
        result.hookFlags = flags;
        console2.log("Hook flags:", flags);
        
        // Step 2: Mine the hook address
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            feeRecipient,
            msg.sender, // Owner address (the broadcaster)
            address(0)  // Tools contract will be set after deployment
        );
        
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            flags,
            type(LimitOrderBatch).creationCode,
            constructorArgs
        );
        
        result.salt = salt;
        console2.log("Predicted hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));
        
        // Step 3: Deploy core contract with CREATE2
        LimitOrderBatch coreContract = new LimitOrderBatch{salt: salt}(
            poolManager,
            feeRecipient,
            msg.sender, // Owner address (the broadcaster)
            address(0)  // Tools contract address - will be set later
        );
        
        require(address(coreContract) == hookAddress, "Hook address mismatch!");
        result.coreContract = address(coreContract);
        console2.log(unicode"✅ Core contract deployed at:", address(coreContract));
        
        // Step 4: Deploy tools contract with reference to core
        LimitOrderBatchTools toolsContract = new LimitOrderBatchTools(
            address(coreContract),
            poolManager
        );
        
        result.toolsContract = address(toolsContract);
        console2.log(unicode"✅ Tools contract deployed at:", address(toolsContract));
        
        // Step 5: Link core contract to tools
        coreContract.setToolsContract(address(toolsContract));
        console2.log(unicode"✅ Contracts linked successfully");
        result.linked = true;
        
        // Step 6: Verify the bidirectional connection
        address coreFromTools = toolsContract.CORE_CONTRACT();
        address toolsFromCore = address(coreContract.toolsContract());
        
        require(toolsFromCore == address(toolsContract), "Core->Tools link failed");
        require(coreFromTools == address(coreContract), "Tools->Core link failed");
        console2.log(unicode"✅ Bidirectional linking verified");
        
        // Step 7: Verify hook permissions
        Hooks.Permissions memory permissions = coreContract.getHookPermissions();
        require(permissions.beforeInitialize, "beforeInitialize not set");
        require(permissions.afterInitialize, "afterInitialize not set");
        require(permissions.beforeSwap, "beforeSwap not set");
        require(permissions.afterSwap, "afterSwap not set");
        console2.log(unicode"✅ Hook permissions verified");
        
        // Step 8: Display contract sizes and deployment summary
        console2.log("=== Contract Analysis ===");
        console2.log("Core contract size:", type(LimitOrderBatch).creationCode.length, "bytes");
        console2.log("Tools contract size:", type(LimitOrderBatchTools).creationCode.length, "bytes");
        console2.log("Total system size:", 
            type(LimitOrderBatch).creationCode.length + type(LimitOrderBatchTools).creationCode.length, 
            "bytes");
        
        console2.log("=== Integration Verification ===");
        console2.log("Core -> Tools:", toolsFromCore);
        console2.log("Tools -> Core:", coreFromTools);
        console2.log("Hook Address Match:", address(coreContract) == hookAddress ? unicode"✅" : unicode"❌");
        console2.log("Permission Flags:", flags);
        
        console2.log("=== Deployment Summary ===");
        console2.log(unicode"🎯 Core Contract (LimitOrderBatch):", address(coreContract));
        console2.log(unicode"🔧 Tools Contract (LimitOrderBatchTools):", address(toolsContract));
        console2.log(unicode"⚡ Hook Permissions:", flags);
        console2.log(unicode"🔗 Integration Status: ACTIVE");
        console2.log(unicode"💰 Fee Recipient:", feeRecipient);
        console2.log(unicode"🏊 Pool Manager:", address(poolManager));
        
        vm.stopBroadcast();
        return result;
    }
    
    // Alternative deployment for testing (without hook mining)
    function deployForTesting() external returns (DeploymentResult memory result) {
        vm.startBroadcast();
        
        console2.log("=== Deploying for Testing (No Hook Mining) ===");
        
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
        
        // Deploy core contract directly
        LimitOrderBatch coreContract = new LimitOrderBatch(
            poolManager,
            feeRecipient,
            msg.sender, // Owner address (the broadcaster)
            address(0)  // No tools contract initially
        );
        
        // Deploy tools contract
        LimitOrderBatchTools toolsContract = new LimitOrderBatchTools(
            address(coreContract),
            poolManager
        );
        
        // Link them
        coreContract.setToolsContract(address(toolsContract));
        
        result.coreContract = address(coreContract);
        result.toolsContract = address(toolsContract);
        result.linked = true;
        result.hookFlags = BEFORE_INITIALIZE_FLAG | AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG;
        
        console2.log("Core Contract:", address(coreContract));
        console2.log("Tools Contract:", address(toolsContract));
        console2.log("Linked:", result.linked);
        
        vm.stopBroadcast();
        return result;
    }
    
    // Link existing contracts (if deployed separately)
    function linkExistingContracts(address coreAddress, address toolsAddress) external {
        vm.startBroadcast();
        
        console2.log("=== Linking Existing Contracts ===");
        console2.log("Core Contract:", coreAddress);
        console2.log("Tools Contract:", toolsAddress);
        
        require(coreAddress != address(0) && toolsAddress != address(0), "Invalid addresses");
        require(coreAddress.code.length > 0 && toolsAddress.code.length > 0, "Contracts not deployed");
        
        LimitOrderBatch coreContract = LimitOrderBatch(payable(coreAddress));
        LimitOrderBatchTools toolsContract = LimitOrderBatchTools(toolsAddress);
        
        // Verify tools contract points to core
        require(toolsContract.CORE_CONTRACT() == coreAddress, "Tools contract not linked to core");
        
        // Link core to tools
        coreContract.setToolsContract(toolsAddress);
        
        console2.log(unicode"✅ Contracts linked successfully");
        
        vm.stopBroadcast();
    }
}
