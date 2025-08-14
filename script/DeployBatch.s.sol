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
    uint160 constant AFTER_INITIALIZE_FLAG = uint160(1 << 12); // bit 12
    uint160 constant AFTER_SWAP_FLAG = uint160(1 << 6); // bit 6

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
        uint160 flags = AFTER_INITIALIZE_FLAG | AFTER_SWAP_FLAG; // Match hook permissions

        // Prepare constructor arguments for LimitOrderBatch hook
        bytes memory constructorArgs = abi.encode(address(poolManager), feeRecipient);
        
        // Mine a salt that will produce a hook address with the correct flags
        // In forge script, CREATE2 deployments use the CREATE2 deployer proxy
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer, // Use CREATE2 deployer proxy, not msg.sender
            flags,
            type(LimitOrderBatch).creationCode,
            constructorArgs
        );
        
        console2.log("=== DEPLOYMENT DEBUG ===");
        console2.log("Hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));
        console2.log("CREATE2 Deployer:", create2Deployer);
        console2.log("Flags:", flags);
        
        // Deploy using CREATE2
        limitOrderBatch = new LimitOrderBatch{salt: salt}(IPoolManager(poolManager), feeRecipient);
        require(address(limitOrderBatch) == hookAddress, "Hook address mismatch");

        vm.stopBroadcast();
    }
}
