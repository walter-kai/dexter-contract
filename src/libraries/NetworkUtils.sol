// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title NetworkUtils
 * @notice Utility library for network detection and configuration
 * @dev Provides functions to detect the current network environment
 */
library NetworkUtils {
    // Known chain IDs
    uint256 constant MAINNET_CHAIN_ID = 1;
    uint256 constant SEPOLIA_CHAIN_ID = 11155111;

    // Known addresses for mainnet
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /**
     * @notice Check if the current network is mainnet
     * @return true if running on Ethereum mainnet
     */
    function isMainnet() internal view returns (bool) {
        return block.chainid == MAINNET_CHAIN_ID;
    }

    /**
     * @notice Check if the current network is Sepolia testnet
     * @return true if running on Sepolia testnet
     */
    function isSepolia() internal view returns (bool) {
        return block.chainid == SEPOLIA_CHAIN_ID;
    }

    /**
     * @notice Check if the current network is forked mainnet (Anvil)
     * @dev Since Anvil forks from mainnet, it uses chain ID 1 but we can detect
     * it by checking if we're in a testing environment
     * @return true if running on Anvil (forked mainnet)
     */
    function isAnvil() internal pure returns (bool) {
        // For Anvil detection, we could check for specific test conditions
        // or rely on the caller to pass this information
        // For now, we'll assume all chain ID 1 could be Anvil in testing
        return false; // This should be set by the calling context
    }

    /**
     * @notice Check if we should perform real liquidity checks
     * @dev Returns true for mainnet and testnets where we have access
     * @return true if liquidity checks should be performed
     */
    function shouldPerformLiquidityCheck() internal view returns (bool) {
        // Only perform real liquidity checks on mainnet and sepolia
        // For Anvil (forked mainnet), this depends on testing context
        return isMainnet() || isSepolia();
    }

    /**
     * @notice Check if we should use the HookManager for liquidity validation
     * @dev Returns true when we have a deployed hook that can access pool state
     * @return true if HookManager-based validation should be used
     */
    function shouldUseHookManagerValidation() internal view returns (bool) {
        // Use HookManager validation on mainnet where hooks are properly deployed
        return isMainnet();
    }

    /**
     * @notice Get the expected PoolManager address for the current network
     * @return The PoolManager address for the current network
     */
    function getPoolManagerAddress() internal view returns (address) {
        if (isMainnet()) {
            return MAINNET_POOL_MANAGER;
        }
        // For other networks, return zero address to indicate no known address
        return address(0);
    }
}
