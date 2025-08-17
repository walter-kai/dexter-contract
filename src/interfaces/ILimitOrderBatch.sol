// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILimitOrderBatch
 * @notice Interface for consolidated batch limit orders with multiple price levels
 */
interface ILimitOrderBatch {
    
    // ===== STRUCTS =====
    
    /// @notice Parameters for creating a batch order with multiple price levels
    struct BatchParams {
        address currency0;
        address currency1;
        bool zeroForOne;
        uint256[] targetPrices;     // Array of trigger prices
        uint256[] targetAmounts;    // Array of amounts for each price level
        uint256 expirationTime;
        uint256 bestPriceTimeout; // Seconds to wait for better price, 0 = disabled
    }

    // ===== EVENTS =====
    
    event BatchOrderCreated(
        uint256 indexed batchId,
        address indexed user,
        address currency0,
        address currency1,
        uint256 totalAmount,
        uint256[] targetPrices,
        uint256[] targetAmounts
    );

    event BatchLevelExecuted(
        uint256 indexed batchId,
        uint256 priceLevel,
        uint256 price,
        uint256 amountExecuted
    );

    event ManualBatchLevelExecuted(
        uint256 indexed batchId,
        uint256 priceLevel,
        address indexed owner,
        uint256 amount
    );

    event BatchFullyExecuted(
        uint256 indexed batchId,
        uint256 totalAmountExecuted,
        uint256 totalAmountReceived
    );

    event BatchCancelled(
        uint256 indexed batchId,
        address indexed user,
        uint256 refundAmount
    );

    event FeeCollected(
        uint256 indexed batchId,
        uint256 priceLevel,
        address indexed token,
        uint256 feeAmount,
        address indexed feeRecipient
    );

    event Debug(string message, uint256 value);

    event GasPriceTracked(uint128 gasPrice, uint128 newAverage, uint104 count);

    // ===== FUNCTIONS =====
    
    function createBatchOrder(BatchParams calldata params) 
        external 
        payable 
        returns (uint256 batchId);

    /// @notice Manually execute a specific batch level (owner only)
    /// @dev Allows owner to execute orders at favorable prices for optimal execution
    /// @param batchId The batch order ID to execute
    /// @param priceLevel The specific price level to execute
    /// @return isFullyExecuted Whether the entire batch is now fully executed
    function executeBatchLevel(uint256 batchId, uint256 priceLevel) 
        external 
        returns (bool isFullyExecuted);

    function cancelBatchOrder(uint256 batchId) external;

    function getBatchOrder(uint256 batchId) 
        external 
        view 
        returns (
            address user,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256[] memory targetPrices,
            uint256[] memory targetAmounts,
            bool isActive,
            bool isFullyExecuted
        );

    // ===== VIEW FUNCTIONS =====

    /// @notice Get all order IDs for a batch (compatibility function)
    /// @return orderIds Array of order IDs in the batch
    function getBatchOrders(uint256 /* batchId */) external pure returns (uint256[] memory orderIds);

    /// @notice Get detailed batch order information including expiration
    /// @param batchId The batch order ID
    /// @return user Address of the user who created the order
    /// @return currency0 First currency address
    /// @return currency1 Second currency address
    /// @return totalAmount Total amount to be swapped
    /// @return executedAmount Amount already executed
    /// @return targetPrices Array of target prices
    /// @return targetAmounts Array of target amounts
    /// @return expirationTime Order expiration timestamp
    /// @return isActive Whether order is active
    /// @return isFullyExecuted Whether order is fully executed
    /// @return executedLevels Bitmask of executed levels
    function getBatchOrderDetails(uint256 batchId) external view returns (
        address user,
        address currency0,
        address currency1,
        uint256 totalAmount,
        uint256 executedAmount,
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 expirationTime,
        bool isActive,
        bool isFullyExecuted,
        uint256 executedLevels,
        bool zeroForOne
    );

    /// @notice Get which levels have been executed for a batch order
    /// @param batchId The batch order ID
    /// @return executedLevels Bitmask of executed levels
    /// @return levelStatus Array of boolean values indicating which levels are executed
    function getExecutedLevels(uint256 batchId) external view returns (uint256 executedLevels, bool[] memory levelStatus);

    /// @notice Get batch statistics
    /// @return totalBatches Total number of batches created
    function getBatchStatistics() external view returns (uint256 totalBatches);

    // ===== ADMIN FUNCTIONS =====

    /// @notice Emergency withdraw function - converts ERC-6909 tokens back to underlying ERC20/ETH
    /// @param token The underlying token address (address(0) for ETH)
    /// @param amount The amount of ERC-6909 tokens to convert and withdraw
    function emergencyWithdraw(address token, uint256 amount) external;


}
