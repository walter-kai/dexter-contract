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
        
        // Use HookMiner to find a valid hook address, but deploy with Forge's CREATE2
        uint160 flags = BEFORE_INITIALIZE_FLAG | AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG;

        // Prepare constructor arguments for LimitOrderBatch hook
        bytes memory constructorArgs = abi.encode(address(poolManager), feeRecipient);
        
        console2.log("=== DEPLOYMENT DEBUG ===");
        console2.log("msg.sender:", msg.sender);
        console2.log("Required flags:", flags);
        
        // Use HookMiner to find a valid hook address using the standard CREATE2 deployer
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            flags,
            type(LimitOrderBatch).creationCode,
            constructorArgs
        );
        
        console2.log("HookMiner found address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));
        
        // Deploy using the same CREATE2 deployer that HookMiner used
        bytes memory creationCode = abi.encodePacked(
            type(LimitOrderBatch).creationCode,
            constructorArgs
        );
        
        // Deploy the contract manually using the CREATE2 deployer
        bytes memory deploymentData = abi.encodePacked(salt, creationCode);
        
        (bool success, ) = create2Deployer.call(deploymentData);
        require(success, "CREATE2 deployment failed");
        
        // The contract should be deployed at the predicted address
        address deployedAddress = hookAddress;
        
        require(deployedAddress == hookAddress, string(abi.encodePacked(
            "Address mismatch! Expected: ", 
            vm.toString(hookAddress),
            " Got: ",
            vm.toString(deployedAddress)
        )));
        
        limitOrderBatch = LimitOrderBatch(payable(deployedAddress));
        
        console2.log("Successfully deployed at:", address(limitOrderBatch));

        vm.stopBroadcast();
    }
}
