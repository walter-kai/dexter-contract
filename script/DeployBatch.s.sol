// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SwapToken} from "../src/SwapToken.sol";
import {LimitOrderBatch} from "../src/LimitOrderBatch.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";


contract DeployBatch is Script {
    // Anvil default accounts (for local development)
    address constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant ANVIL_ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    
    // Use the correct flags that match your hook permissions
    // Based on LimitOrderBatch.getHookPermissions():
    // - beforeInitialize: true (bit 15)
    // - afterInitialize: true (bit 14) 
    // - beforeSwap: true (bit 7)
    // - afterSwap: true (bit 6)
    uint160 constant BEFORE_INITIALIZE_FLAG = uint160(1 << 15);
    uint160 constant AFTER_INITIALIZE_FLAG = uint160(1 << 14);
    uint160 constant BEFORE_SWAP_FLAG = uint160(1 << 7);
    uint160 constant AFTER_SWAP_FLAG = uint160(1 << 6);

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

        // Deploy LimitOrderBatch as a hook
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        
        LimitOrderBatch limitOrderBatch;
        
        // Always use CREATE2 deployment with proper hook address validation
        // This is required for Uniswap v4 hooks regardless of environment
        uint160 flags = BEFORE_INITIALIZE_FLAG | AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG;

        // Prepare constructor arguments for LimitOrderBatch hook
        bytes memory constructorArgs = abi.encode(address(poolManager), feeRecipient);
        
        // Mine a salt that will produce a hook address with the correct flags
        // For forge script deployments, use the broadcaster address (msg.sender)
        (address hookAddress, bytes32 salt) = HookMiner.find(
            msg.sender, // Use the broadcaster address, not the script contract
            flags,
            type(LimitOrderBatch).creationCode,
            constructorArgs
        );
        
        console2.log("=== DEPLOYMENT DEBUG ===");
        console2.log("Hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));
        console2.log("Deployer (msg.sender):", msg.sender);
        console2.log("Flags:", flags);
        
        // Deploy using CREATE2
        limitOrderBatch = new LimitOrderBatch{salt: salt}(IPoolManager(poolManager), feeRecipient);
        require(address(limitOrderBatch) == hookAddress, "Hook address mismatch");

        vm.stopBroadcast();
    }
}
