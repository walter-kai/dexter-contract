// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {SwapToken} from "../src/SwapToken.sol";
import {LimitOrderBatchDev} from "../src/testing/LimitOrderBatchDev.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../lib/v4-periphery/src/utils/HookMiner.sol";
import {MockPoolManager} from "../test/mocks/MockContracts.sol";

contract DeployBatchLocal is Script {
    uint160 constant AFTER_SWAP_FLAG = uint160(0x40); // bit 6

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // Get the correct PoolManager address based on the chain
        IPoolManager poolManager;
        bool isLocalDevelopment = false;
        
        if (block.chainid == 1) {
            // Chain ID 1 - check if we're forking mainnet or on live mainnet
            if (address(0x000000000004444c5dc75cB358380D2e3dE08A90).code.length > 0) {
                // We're on mainnet (live or forked), use the real PoolManager
                poolManager = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
                console2.log("=== DEPLOYING TO MAINNET (LIVE OR FORKED) ===");
            } else {
                // Local development - deploy our own MockPoolManager
                console2.log("=== DEPLOYING TO LOCAL DEVELOPMENT ===");
                console2.log("Local development detected - deploying MockPoolManager...");
                MockPoolManager mockPoolManager = new MockPoolManager();
                poolManager = IPoolManager(address(mockPoolManager));
                isLocalDevelopment = true;
            }
        } else {
            revert("This script is only for mainnet development (chain ID 1). Use DeployBatch.s.sol for testnets.");
        }
        
        console2.log("Chain ID:", block.chainid);
        console2.log("Using PoolManager at:", address(poolManager));
        console2.log("PoolManager code size:", address(poolManager).code.length);
        console2.log("Local development mode:", isLocalDevelopment);
        console2.log("Deployer address (msg.sender):", msg.sender);
        console2.log("");

        // Deploy LimitOrderBatchDev as a hook (testing version)
        console2.log("1. Deploying LimitOrderBatchDev Hook (Testing Version)...");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        console2.log("Fee recipient address:", feeRecipient);
        
        LimitOrderBatchDev limitOrderBatch;
        
        // Always use CREATE2 deployment with proper hook address validation
        // This is required for Uniswap v4 hooks regardless of environment
        uint160 flags = AFTER_SWAP_FLAG;
        console2.log("Target hook flags:", flags);

        // Prepare constructor arguments for LimitOrderBatchDev hook
        bytes memory constructorArgs = abi.encode(address(poolManager), feeRecipient);
        
        // Mine a salt that will produce a hook address with the correct flags
        console2.log("Mining salt for LimitOrderBatchDev hook address with flags...");
        (address hookAddress, bytes32 salt) = HookMiner.find(
            msg.sender, // Use msg.sender as the deployer (same as new keyword)
            flags,
            type(LimitOrderBatchDev).creationCode,
            constructorArgs
        );
        
        console2.log("Found valid salt:", vm.toString(salt));
        console2.log("Hook address:", hookAddress);
        
        // Deploy using CREATE2
        limitOrderBatch = new LimitOrderBatchDev{salt: salt}(IPoolManager(poolManager), feeRecipient);
        require(address(limitOrderBatch) == hookAddress, "Hook address mismatch");
        
        console2.log(unicode"✅ LimitOrderBatchDev Hook deployed at:", address(limitOrderBatch));

        console2.log("");
        console2.log(unicode"=== DEPLOYMENT COMPLETE ===");
        console2.log(unicode"📝 Summary:");
        console2.log(unicode"   LimitOrderBatchDev Hook:", address(limitOrderBatch));
        console2.log(unicode"   PoolManager:            ", address(poolManager));
        console2.log(unicode"   Fee Recipient:          ", feeRecipient);
        console2.log(unicode"   Local Development:      ", isLocalDevelopment);
        console2.log("");
        console2.log(unicode"=== COPY TO YOUR .ENV FILES ===");
        console2.log("LIMIT_ORDER_BATCH_HOOK_ADDRESS=", address(limitOrderBatch));
        console2.log("");
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Copy the address above to your .env files");
        console2.log("2. Use the CLI to create and manage limit orders");
        console2.log("3. Orders will be automatically executed via the integrated hook");
        console2.log("4. Use testing functions for development and testing");

        vm.stopBroadcast();
    }
}
