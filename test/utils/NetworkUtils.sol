// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title NetworkUtils
 * @notice Utility contract for detecting network environment and providing appropriate test parameters
 */
library NetworkUtils {
    
    // Forge VM for fork detection
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    
    enum Network {
        FORKED_MAINNET, // Anvil forked from mainnet (Chain ID 1 + fork active)
        SEPOLIA,        // Chain ID 11155111  
        MAINNET,        // Chain ID 1 (live mainnet, no fork active)
        OTHER
    }
    
    /**
     * @notice Detect current network based on chain ID and fork status
     * @return network The detected network
     */
    function detectNetwork() internal view returns (Network network) {
        uint256 chainId = block.chainid;
        
        if (chainId == 1) {
            // Chain ID 1: Check if we're in a fork (Anvil) or live mainnet
            if (isFork()) {
                return Network.FORKED_MAINNET;
            } else {
                return Network.MAINNET;
            }
        } else if (chainId == 11155111) {
            return Network.SEPOLIA;
        } else {
            return Network.OTHER;
        }
    }
    
    /**
     * @notice Check if running in a fork (Anvil)
     * @return true if running in a fork
     */
    function isFork() internal view returns (bool) {
        try vm.activeFork() {
            return true;
        } catch (bytes memory) {
            return false;
        }
    }
    
    /**
     * @notice Get safe test amounts based on network
     * @return orderAmount Safe amount for creating orders
     * @return userBalance Safe amount to mint to test users
     * @return ethAmount Safe amount of ETH to give to test users
     */
    function getTestAmounts() internal view returns (
        uint256 orderAmount,
        uint256 userBalance, 
        uint256 ethAmount
    ) {
        Network network = detectNetwork();
        
        if (network == Network.FORKED_MAINNET) {
            // Forked Mainnet (Anvil): Use large amounts for comprehensive testing
            orderAmount = 1000e18;     // 1000 tokens
            userBalance = 10000e18;    // 10,000 tokens
            ethAmount = 100 ether;     // 100 ETH
        } else if (network == Network.SEPOLIA) {
            // Sepolia: Use moderate amounts (testnet ETH has some value)
            orderAmount = 1e18;        // 1 token
            userBalance = 10e18;       // 10 tokens  
            ethAmount = 1 ether;       // 1 ETH
        } else if (network == Network.MAINNET) {
            // Live Mainnet: Use very small amounts to minimize cost/risk
            orderAmount = 1e15;        // 0.001 tokens (1000 wei)
            userBalance = 1e16;        // 0.01 tokens (10000 wei)
            ethAmount = 1e15;          // 0.001 ETH
        } else {
            // Unknown network: Use conservative amounts
            orderAmount = 1e16;        // 0.01 tokens
            userBalance = 1e17;        // 0.1 tokens
            ethAmount = 1e16;          // 0.01 ETH
        }
    }
    
    /**
     * @notice Get safe price levels for testing based on network
     * @return prices Array of target prices
     * @return amounts Array of target amounts  
     */
    function getTestPriceLevels() internal view returns (
        uint256[] memory prices,
        uint256[] memory amounts
    ) {
        (uint256 orderAmount,,) = getTestAmounts();
        
        prices = new uint256[](2);
        amounts = new uint256[](2);
        
        // Split order amount across two levels - each level gets half
        uint256 halfAmount = orderAmount / 2;
        
        prices[0] = 2500e18;  // Price levels remain the same
        prices[1] = 2400e18;
        amounts[0] = halfAmount;  // This should be 500e18 when orderAmount is 1000e18
        amounts[1] = halfAmount;  // This should be 500e18 when orderAmount is 1000e18
    }
    
    /**
     * @notice Check if liquidity validation should be performed
     * @return shouldValidate True if liquidity should be checked
     */
    function shouldValidateLiquidity() internal view returns (bool shouldValidate) {
        Network network = detectNetwork();
        
        // Skip liquidity validation on forked mainnet since we're testing
        // Enable on testnets and live mainnet where proper pools exist
        return network != Network.FORKED_MAINNET;
    }
    
    /**
     * @notice Get network name for logging
     * @return networkName Human readable network name
     */
    function getNetworkName() internal view returns (string memory networkName) {
        Network network = detectNetwork();
        
        if (network == Network.FORKED_MAINNET) {
            return "Forked Mainnet (Anvil)";
        } else if (network == Network.SEPOLIA) {
            return "Sepolia Testnet";
        } else if (network == Network.MAINNET) {
            return "Ethereum Mainnet";
        } else {
            return "Unknown Network";
        }
    }
}
