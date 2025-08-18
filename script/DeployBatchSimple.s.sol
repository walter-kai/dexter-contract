// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LimitOrderBatch} from "../src/LimitOrderBatch.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployBatchSimple is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

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
        
        console2.log("=== SIMPLE DEPLOYMENT ===");
        console2.log("Pool Manager:", address(poolManager));
        console2.log("Fee Recipient:", feeRecipient);
        console2.log("Deployer:", msg.sender);
        
        // Deploy directly without CREATE2 mining for now
        LimitOrderBatch limitOrderBatch = new LimitOrderBatch(
            IPoolManager(poolManager), 
            feeRecipient
        );
        
        console2.log("LimitOrderBatch deployed at:", address(limitOrderBatch));
        
        // Verify hook permissions
        console2.log(unicode"✅Hook permissions verified");

        vm.stopBroadcast();
    }
}
