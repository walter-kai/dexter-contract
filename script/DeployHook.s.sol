// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import "../src/LimitOrderBatch.sol";

/**
 * @title DeployHookContract
 * @notice Deploy LimitOrderBatch hook with proper hook mining
 */
contract DeployHookContract is Script {
    
    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);
        
        IPoolManager poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        address feeRecipient = 0x3Fef4207017024b01eFd67d3f4336df88F47A3F3;
        
        console2.log("=== Deploying LimitOrderBatch Hook ===");
        console2.log("Deployer:", deployer);
        console2.log("Pool Manager:", address(poolManager));
        console2.log("Fee Recipient:", feeRecipient);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Calculate required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        
        console2.log("Required flags:", flags);
        
        // CREATE2_DEPLOYER address for Foundry scripts
        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        
        // Prepare constructor arguments
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            feeRecipient,
            deployer
        );
        
        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(LimitOrderBatch).creationCode,
            constructorArgs
        );
        
        console2.log("Found valid hook address:", hookAddress);
        console2.log("Using salt:", vm.toString(salt));
        
        // Deploy the hook using CREATE2 with the mined salt
        LimitOrderBatch limitOrderBatch = new LimitOrderBatch{salt: salt}(
            poolManager,
            feeRecipient,
            deployer
        );
        
        // Verify the deployed address matches the mined address
        require(address(limitOrderBatch) == hookAddress, "Hook address mismatch!");
        console2.log("Deployed hook address:", address(limitOrderBatch));
        
        vm.stopBroadcast();
        
        console2.log(unicode"✅ LimitOrderBatch hook deployed at:", address(limitOrderBatch));
        console2.log("");
        console2.log("LIMIT_ORDER_BATCH_ADDRESS=", vm.toString(address(limitOrderBatch)));
    }
}
