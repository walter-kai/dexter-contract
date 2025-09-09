// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILimitOrderBatch
 * @notice Interface for consolidated batch limit orders with multiple price levels
 */
interface ILimitOrderBatch {
    
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
    
    function createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint32 slippage,
        uint256 deadline
    ) external payable returns (uint256 batchId);

    function cancelBatchOrder(uint256 batchId) external;

    // ===== VIEW FUNCTIONS =====

    /// @notice Get comprehensive batch and contract info in one call
    function getBatchInfo(uint256 batchId) external view returns (
        address user,
        address currency0,
        address currency1, 
        uint256 totalAmount,
        uint256 executedAmount,
        uint256 claimableAmount,
        bool isActive,
        bool isFullyExecuted,
        uint256 expirationTime,
        bool zeroForOne,
        uint256 totalBatches,
        uint24 currentFee
    );

    // ===== ADMIN FUNCTIONS =====

    /// @notice Manually execute a specific batch level at current market price
    function executeBatchLevel(uint256 batchId, uint256 levelIndex) 
        external 
        returns (bool isFullyExecuted);
}
