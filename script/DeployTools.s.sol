// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "../src/LimitOrderBatchTools.sol";

/**
 * @title DeployTools
 * @notice Deployment script for the LimitOrderBatchTools contract only
 * @dev Requires the core contract address to be provided
 */
contract DeployTools is Script {
    
    function setUp() public {}
    
    function run() external returns (address toolsContract) {
        vm.startBroadcast();
        
        console2.log("=== Deploying Dexter Tools Contract ===");
        
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
        
        // Get core contract address from environment
        address coreContractAddress = vm.envAddress("CORE_CONTRACT_ADDRESS");
        
        console2.log("Core Contract:", coreContractAddress);
        console2.log("Pool Manager:", address(poolManager));
        
        // Validate core contract address
        require(coreContractAddress != address(0), "Core contract address required");
        require(coreContractAddress.code.length > 0, "Core contract not deployed");
        
        // Deploy tools contract
        LimitOrderBatchTools deployedTools = new LimitOrderBatchTools(
            coreContractAddress,
            poolManager
        );
        
        console2.log(unicode"✅ Tools contract deployed at:", address(deployedTools));
        
        // Verify deployment
        require(deployedTools.CORE_CONTRACT() == coreContractAddress, "Core contract link failed");
        require(address(deployedTools.poolManager()) == address(poolManager), "Pool manager link failed");
        console2.log(unicode"✅ Contract links verified");
        
        // Display contract info
        console2.log("=== Tools Contract Info ===");
        console2.log("Address:", address(deployedTools));
        console2.log("Core Contract:", deployedTools.CORE_CONTRACT());
        console2.log("Pool Manager:", address(deployedTools.poolManager()));
        console2.log("Owner:", deployedTools.owner());
        console2.log("Contract Size:", type(LimitOrderBatchTools).creationCode.length, "bytes");
        
        vm.stopBroadcast();
        return address(deployedTools);
    }
    
    // Deploy with manual core contract address (for testing)
    function deployWithCoreAddress(address coreContractAddress) external returns (address) {
        vm.startBroadcast();
        
        console2.log("=== Manual Tools Deployment ===");
        console2.log("Core Contract:", coreContractAddress);
        
        require(coreContractAddress != address(0), "Invalid core contract address");
        
        // Get PoolManager
        IPoolManager poolManager;
        if (block.chainid == 1) {
            poolManager = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        } else if (block.chainid == 11155111) {
            poolManager = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        } else {
            revert("Unsupported chain");
        }
        
        LimitOrderBatchTools toolsContract = new LimitOrderBatchTools(
            coreContractAddress,
            poolManager
        );
        
        console2.log("Tools Contract:", address(toolsContract));
        
        vm.stopBroadcast();
        return address(toolsContract);
    }
}
