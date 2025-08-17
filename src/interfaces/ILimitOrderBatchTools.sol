// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title ILimitOrderBatchTools
 * @notice Interface for the LimitOrderBatchTools contract that provides advanced features
 */
interface ILimitOrderBatchTools {
    // ========== BEST EXECUTION QUEUE ==========
    
    function queueForBestExecution(
        uint256 orderId,
        PoolKey calldata key,
        int24 currentTick,
        uint256 timeout
    ) external;
    
    function processBestExecutionQueue(
        PoolKey calldata key,
        int24 currentTick
    ) external returns (uint256[] memory executedOrders);
    
    function getQueueStatus(PoolKey calldata key) external view returns (
        uint256 queueLength,
        uint256 currentIndex,
        uint256[] memory orders
    );
    
    function clearExpiredQueuedOrders(PoolKey calldata key) external returns (uint256 clearedCount);

    // ========== POOL INITIALIZATION TRACKING ==========
    
    function trackPoolInitialization(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external;
    
    function recordFirstOrder(PoolKey calldata key) external;
    
    function poolInitialized(PoolKey calldata key) external view returns (bool);

    // ========== PRICE ANALYTICS ==========
    
    function updatePriceAnalytics(
        PoolKey calldata key,
        int24 newTick
    ) external;
    
    function getPriceTrend(PoolKey calldata key) external view returns (
        int24 direction,
        uint256 confidence,
        uint256 volatility
    );

    // ========== ADVANCED METRICS ==========
    
    function calculateAdvancedMetrics(
        uint256 orderId,
        uint256 executionTick,
        uint256 gasUsed,
        bool usedBestExecution
    ) external;
    
    function getAdvancedMetrics(uint256 orderId) external view returns (
        uint256 creationGasPrice,
        uint256 expectedExecutionTime,
        uint256 actualExecutionTime,
        uint256 gasSavingsRealized,
        bool usedBestExecution
    );

    // ========== OPTIMIZATION ALGORITHMS ==========
    
    function calculateOptimalExecutionStrategy(
        PoolKey calldata key,
        uint256 orderAmount,
        int24 targetTick
    ) external view returns (
        bool shouldUseQueue,
        uint256 recommendedTimeout,
        uint256 expectedImprovement
    );

    // ========== ADMIN FUNCTIONS ==========
    
    function setOwner(address newOwner) external;
    function emergencyClearQueue(PoolKey calldata key) external;
}
