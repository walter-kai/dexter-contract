// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "../src/SwapToken.sol";

/**
 * @title DeploySwapToken
 * @notice Deploy SwapToken router for testing swaps
 */
contract DeploySwapToken is Script {
    
    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);
        
        IPoolManager poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        
        console2.log("=== Deploying SwapToken Router ===");
        console2.log("Deployer:", deployer);
        console2.log("Pool Manager:", address(poolManager));
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy SwapToken
        SwapToken swapToken = new SwapToken(address(poolManager));
        
        vm.stopBroadcast();
        
        console2.log(unicode"✅ SwapToken router deployed at:", address(swapToken));
        console2.log("");
        console2.log("SWAP_TOKEN_ADDRESS=", vm.toString(address(swapToken)));
    }
}
