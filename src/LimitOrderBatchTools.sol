// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILimitOrderBatch} from "./interfaces/ILimitOrderBatch.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FixedPointMathLib} from "@uniswap/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";

/**
 * @title LimitOrderBatchTools - Advanced Features Extension
 * @notice Provides advanced functionality for batch limit orders including best execution queue,
 *         complex analytics, pool initialization tracking, and optimization algorithms
 * @dev Extension contract to keep core contract under size limits while providing advanced features
 */
contract LimitOrderBatchTools {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    // ========== STORAGE ==========
    
    address public immutable CORE_CONTRACT;
    IPoolManager public immutable poolManager;
    address public owner;
    
    // Advanced features storage
    mapping(PoolId => BestExecutionQueue) public bestExecutionQueues;
    mapping(PoolId => PoolInitializationTracker) public poolTrackers;
    mapping(PoolId => PriceAnalytics) public priceAnalytics;
    mapping(uint256 => AdvancedBatchMetrics) public advancedMetrics;
    
    // Best execution queue structure - optimized for gas efficiency
    struct BestExecutionQueue {
        uint256[] queuedOrderIds;
        mapping(uint256 => uint256) orderPositions; // orderId => position in queue
        uint64 lastProcessedTimestamp;     // 8 bytes
        uint64 bestExecutionTimeout;      // 8 bytes  
        uint32 currentIndex;              // 4 bytes
        int24 bestExecutionTick;          // 3 bytes
        // Total: 23 bytes (fits in one slot with 9 bytes padding)
    }
    
    // Pool initialization tracking - packed for gas efficiency
    struct PoolInitializationTracker {
        uint160 initialSqrtPriceX96;      // 20 bytes
        uint64 initializationTimestamp;   // 8 bytes
        uint32 totalOrdersProcessed;      // 4 bytes
        // Total: 32 bytes (exactly one slot)
        
        uint64 firstOrderTimestamp;       // 8 bytes
        int24 initialTick;                // 3 bytes
        bool isInitialized;               // 1 byte
        // Total: 12 bytes (fits in one slot with 20 bytes padding)
    }
    
    // Price analytics - optimized struct
    struct PriceAnalytics {
        int24[] recentTicks;
        uint256[] recentTimestamps;
        uint64 lastAnalysisTimestamp;     // 8 bytes
        uint32 volatilityScore;           // 4 bytes
        uint32 averageTickMovement;       // 4 bytes
        int24 trendDirection;             // 3 bytes
        // Total: 19 bytes (fits in one slot with 13 bytes padding)
    }
    
    // Advanced batch metrics - packed for efficiency
    struct AdvancedBatchMetrics {
        uint64 creationTimestamp;         // 8 bytes
        uint64 expectedExecutionTime;     // 8 bytes
        uint64 actualExecutionTime;       // 8 bytes
        uint32 creationGasPrice;          // 4 bytes
        uint32 bestPriceAchieved;         // 4 bytes
        // Total: 32 bytes (exactly one slot)
        
        uint32 slippageRealized;          // 4 bytes
        uint32 gasSavingsRealized;        // 4 bytes
        bool usedBestExecution;           // 1 byte
        // Total: 9 bytes (fits in one slot with 23 bytes padding)
    }

    // ========== CONSTANTS ==========
    
    uint256 public constant QUEUE_TIMEOUT = 300; // 5 minutes default
    uint256 public constant MAX_QUEUE_SIZE = 100;
    uint256 public constant ANALYTICS_WINDOW = 50; // Track last 50 price points
    int24 public constant TREND_THRESHOLD = 10; // Minimum tick movement for trend detection
    int24 public constant BEST_EXECUTION_TICKS = 1; // Minimum tick improvement for best execution
    
    // ========== EVENTS ==========
    
    event OrderQueuedForBestExecution(uint256 indexed orderId, PoolId indexed poolId, int24 currentTick);
    event BestExecutionTriggered(uint256 indexed orderId, int24 executionTick, uint256 improvementBps);
    event QueueTimeoutProcessed(uint256 indexed orderId, uint256 ordersProcessed);
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint160 sqrtPriceX96);
    event PriceTrendDetected(PoolId indexed poolId, int24 direction, uint256 confidence);
    event AdvancedMetricsCalculated(uint256 indexed orderId, uint256 gasSavings, uint256 priceImprovement);

    // ========== ERRORS ==========
    
    error OnlyCore();
    error OnlyOwner();
    error QueueFull();
    error InvalidOrder();
    error QueueEmpty();

    // ========== MODIFIERS ==========
    
    modifier onlyCore() {
        require(msg.sender == CORE_CONTRACT, "Only core contract");
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ========== CONSTRUCTOR ==========
    
    constructor(address _coreContract, IPoolManager _poolManager) {
        CORE_CONTRACT = _coreContract;
        poolManager = _poolManager;
        owner = msg.sender;
    }

    // ========== BEST EXECUTION QUEUE FUNCTIONS ==========
    
    /**
     * @notice Queue an order for best execution
     * @dev Called by core contract when price is at target but can potentially improve
     */
    function queueForBestExecution(
        uint256 orderId,
        PoolKey calldata key,
        int24 currentTick,
        uint256 timeout
    ) external onlyCore {
        PoolId poolId = key.toId();
        BestExecutionQueue storage queue = bestExecutionQueues[poolId];
        
        require(queue.queuedOrderIds.length < MAX_QUEUE_SIZE, "Queue full");
        
        // Add to queue
        queue.queuedOrderIds.push(orderId);
        queue.orderPositions[orderId] = queue.queuedOrderIds.length - 1;
        queue.bestExecutionTick = currentTick;
        queue.bestExecutionTimeout = uint64(timeout > 0 ? timeout : QUEUE_TIMEOUT);
        queue.lastProcessedTimestamp = uint64(block.timestamp);
        
        emit OrderQueuedForBestExecution(orderId, poolId, currentTick);
    }
    
    /**
     * @notice Process best execution queue for a pool
     * @dev Called by core contract during price movements
     */
    function processBestExecutionQueue(
        PoolKey calldata key,
        int24 currentTick
    ) external onlyCore returns (uint256[] memory executedOrders) {
        PoolId poolId = key.toId();
        BestExecutionQueue storage queue = bestExecutionQueues[poolId];
        
        if (queue.queuedOrderIds.length == 0) {
            return new uint256[](0);
        }
        
        // Check for better execution price or timeout
        bool shouldExecute = _shouldExecuteBestPrice(queue, currentTick) || 
                            _isQueueTimeout(queue);
        
        if (shouldExecute) {
            executedOrders = new uint256[](queue.queuedOrderIds.length);
            uint256 length = queue.queuedOrderIds.length;
            unchecked {
                for (uint256 i; i < length; ++i) {
                    executedOrders[i] = queue.queuedOrderIds[i];
                    delete queue.orderPositions[queue.queuedOrderIds[i]];
                }
            }
            
            // Clear queue
            delete queue.queuedOrderIds;
            queue.currentIndex = 0;
            queue.lastProcessedTimestamp = uint64(block.timestamp);
            
            emit QueueTimeoutProcessed(executedOrders[0], executedOrders.length);
        }
        
        return executedOrders;
    }
    
    /**
     * @notice Get queue status for a pool
     */
    function getQueueStatus(PoolKey calldata key) external view returns (
        uint256 queueLength,
        uint256 currentIndex,
        uint256[] memory orders
    ) {
        PoolId poolId = key.toId();
        BestExecutionQueue storage queue = bestExecutionQueues[poolId];
        
        return (
            queue.queuedOrderIds.length,
            queue.currentIndex,
            queue.queuedOrderIds
        );
    }
    
    /**
     * @notice Clear expired orders from queue
     */
    function clearExpiredQueuedOrders(PoolKey calldata key) external returns (uint256 clearedCount) {
        PoolId poolId = key.toId();
        BestExecutionQueue storage queue = bestExecutionQueues[poolId];
        
        if (_isQueueTimeout(queue)) {
            clearedCount = queue.queuedOrderIds.length;
            
            // Clear all positions - optimized loop
            uint256 length = queue.queuedOrderIds.length;
            unchecked {
                for (uint256 i; i < length; ++i) {
                    delete queue.orderPositions[queue.queuedOrderIds[i]];
                }
            }
            
            // Reset queue
            delete queue.queuedOrderIds;
            queue.currentIndex = 0;
            queue.lastProcessedTimestamp = uint64(block.timestamp);
        }
        
        return clearedCount;
    }

    // ========== POOL INITIALIZATION TRACKING ==========
    
    /**
     * @notice Track pool initialization
     * @dev Called by core contract when pool is first initialized
     */
    function trackPoolInitialization(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external onlyCore {
        PoolId poolId = key.toId();
        PoolInitializationTracker storage tracker = poolTrackers[poolId];
        
        if (!tracker.isInitialized) {
            tracker.isInitialized = true;
            tracker.initialSqrtPriceX96 = sqrtPriceX96;
            tracker.initialTick = tick;
            tracker.initializationTimestamp = uint64(block.timestamp);
            
            emit PoolInitializationTracked(poolId, tick, sqrtPriceX96);
        }
    }
    
    /**
     * @notice Record first order for a pool
     */
    function recordFirstOrder(PoolKey calldata key) external onlyCore {
        PoolId poolId = key.toId();
        PoolInitializationTracker storage tracker = poolTrackers[poolId];
        
        if (tracker.firstOrderTimestamp == 0) {
            tracker.firstOrderTimestamp = uint64(block.timestamp);
        }
        tracker.totalOrdersProcessed++;
    }
    
    /**
     * @notice Check if pool is initialized
     */
    function poolInitialized(PoolKey calldata key) external view returns (bool) {
        return poolTrackers[key.toId()].isInitialized;
    }

    // ========== PRICE ANALYTICS ==========
    
    /**
     * @notice Update price analytics for a pool
     * @dev Called by core contract on significant price movements
     */
    function updatePriceAnalytics(
        PoolKey calldata key,
        int24 newTick
    ) external onlyCore {
        PoolId poolId = key.toId();
        PriceAnalytics storage analytics = priceAnalytics[poolId];
        
        // Add new tick to history
        if (analytics.recentTicks.length >= ANALYTICS_WINDOW) {
            // Shift array to maintain window size - optimized loop
            unchecked {
                for (uint256 i; i < ANALYTICS_WINDOW - 1; ++i) {
                    analytics.recentTicks[i] = analytics.recentTicks[i + 1];
                    analytics.recentTimestamps[i] = analytics.recentTimestamps[i + 1];
                }
            }
            analytics.recentTicks[ANALYTICS_WINDOW - 1] = newTick;
            analytics.recentTimestamps[ANALYTICS_WINDOW - 1] = block.timestamp;
        } else {
            analytics.recentTicks.push(newTick);
            analytics.recentTimestamps.push(block.timestamp);
        }
        
        // Update trend analysis
        _updateTrendAnalysis(analytics);
        analytics.lastAnalysisTimestamp = uint64(block.timestamp);
    }
    
    /**
     * @notice Get price trend for a pool
     */
    function getPriceTrend(PoolKey calldata key) external view returns (
        int24 direction,
        uint256 confidence,
        uint256 volatility
    ) {
        PriceAnalytics storage analytics = priceAnalytics[key.toId()];
        return (
            analytics.trendDirection,
            _calculateTrendConfidence(analytics),
            analytics.volatilityScore
        );
    }

    // ========== ADVANCED METRICS ==========
    
    /**
     * @notice Calculate advanced metrics for a batch order
     */
    function calculateAdvancedMetrics(
        uint256 orderId,
        uint256 executionTick,
        uint256 gasUsed,
        bool usedBestExecution
    ) external onlyCore {
        AdvancedBatchMetrics storage metrics = advancedMetrics[orderId];
        
        metrics.actualExecutionTime = uint64(block.timestamp);
        metrics.bestPriceAchieved = uint32(executionTick);
        metrics.usedBestExecution = usedBestExecution;
        
        // Calculate gas savings if best execution was used
        if (usedBestExecution) {
            metrics.gasSavingsRealized = uint32(_calculateGasSavings(orderId, gasUsed));
        }
        
        // Calculate price improvement
        uint256 priceImprovement = _calculatePriceImprovement(orderId, executionTick);
        
        emit AdvancedMetricsCalculated(orderId, metrics.gasSavingsRealized, priceImprovement);
    }
    
    /**
     * @notice Get advanced metrics for an order
     */
    function getAdvancedMetrics(uint256 orderId) external view returns (
        uint256 creationGasPrice,
        uint256 expectedExecutionTime,
        uint256 actualExecutionTime,
        uint256 gasSavingsRealized,
        bool usedBestExecution
    ) {
        AdvancedBatchMetrics storage metrics = advancedMetrics[orderId];
        return (
            uint256(metrics.creationGasPrice),
            uint256(metrics.expectedExecutionTime),
            uint256(metrics.actualExecutionTime),
            uint256(metrics.gasSavingsRealized),
            metrics.usedBestExecution
        );
    }

    // ========== OPTIMIZATION ALGORITHMS ==========
    
    /**
     * @notice Calculate optimal execution strategy
     * @dev Analyzes market conditions to recommend execution approach
     */
    function calculateOptimalExecutionStrategy(
        PoolKey calldata key,
        uint256 orderAmount,
        int24 targetTick
    ) external view returns (
        bool shouldUseQueue,
        uint256 recommendedTimeout,
        uint256 expectedImprovement
    ) {
        PoolId poolId = key.toId();
        PriceAnalytics storage analytics = priceAnalytics[poolId];
        
        // Analyze volatility and trend
        uint256 volatility = uint256(analytics.volatilityScore);
        int24 trend = analytics.trendDirection;
        
        // High volatility + favorable trend = use queue with shorter timeout
        if (volatility > 500 && ((trend > 0 && targetTick > 0) || (trend < 0 && targetTick < 0))) {
            return (true, QUEUE_TIMEOUT / 2, 150); // 1.5% expected improvement
        }
        
        // Low volatility = execute immediately
        if (volatility < 100) {
            return (false, 0, 0);
        }
        
        // Default: use queue with standard timeout
        return (true, QUEUE_TIMEOUT, 50); // 0.5% expected improvement
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========
    
    function _shouldExecuteBestPrice(
        BestExecutionQueue storage queue,
        int24 currentTick
    ) internal view returns (bool) {
        // Execute if price improved by at least BEST_EXECUTION_TICKS
        return (currentTick > queue.bestExecutionTick + BEST_EXECUTION_TICKS) ||
               (currentTick < queue.bestExecutionTick - BEST_EXECUTION_TICKS);
    }
    
    function _isQueueTimeout(BestExecutionQueue storage queue) internal view returns (bool) {
        return block.timestamp >= uint256(queue.lastProcessedTimestamp) + uint256(queue.bestExecutionTimeout);
    }
    
    function _updateTrendAnalysis(PriceAnalytics storage analytics) internal {
        if (analytics.recentTicks.length < 3) return;
        
        uint256 len = analytics.recentTicks.length;
        int24 start = analytics.recentTicks[0];
        int24 end = analytics.recentTicks[len - 1];
        
        int24 totalMovement = end - start;
        uint256 absTotalMovement = totalMovement >= 0 ? uint256(int256(totalMovement)) : uint256(int256(-totalMovement));
        analytics.averageTickMovement = uint32(absTotalMovement / len);
        
        if (totalMovement > TREND_THRESHOLD) {
            analytics.trendDirection = 1; // Uptrend
        } else if (totalMovement < -TREND_THRESHOLD) {
            analytics.trendDirection = -1; // Downtrend
        } else {
            analytics.trendDirection = 0; // Sideways
        }
        
        // Calculate volatility
        analytics.volatilityScore = uint32(_calculateVolatility(analytics));
    }
    
    function _calculateVolatility(PriceAnalytics storage analytics) internal view returns (uint256) {
        if (analytics.recentTicks.length < 2) return 0;
        
        uint256 sumSquaredDiffs = 0;
        uint256 len = analytics.recentTicks.length;
        
        unchecked {
            for (uint256 i = 1; i < len; ++i) {
                int24 diff = analytics.recentTicks[i] - analytics.recentTicks[i-1];
                uint256 absDiff = diff >= 0 ? uint256(int256(diff)) : uint256(int256(-diff));
                sumSquaredDiffs += absDiff * absDiff;
            }
        }
        
        return sumSquaredDiffs / (len - 1);
    }
    
    function _calculateTrendConfidence(PriceAnalytics storage analytics) internal view returns (uint256) {
        if (analytics.recentTicks.length == 0) return 0;
        
        // Simple confidence based on consistency of direction
        uint256 consistentMoves = 0;
        uint256 totalMoves = 0;
        
        unchecked {
            for (uint256 i = 1; i < analytics.recentTicks.length; ++i) {
                int24 move = analytics.recentTicks[i] - analytics.recentTicks[i-1];
                totalMoves++;
                
                if ((analytics.trendDirection > 0 && move > 0) ||
                    (analytics.trendDirection < 0 && move < 0)) {
                    consistentMoves++;
                }
            }
        }
        
        return totalMoves > 0 ? (consistentMoves * 100) / totalMoves : 0;
    }
    
    function _calculateGasSavings(uint256 orderId, uint256 gasUsed) internal view returns (uint256) {
        AdvancedBatchMetrics storage metrics = advancedMetrics[orderId];
        
        // Estimate gas savings from batching vs individual execution
        uint256 estimatedIndividualGas = gasUsed * 150 / 100; // 50% more gas for individual
        return estimatedIndividualGas > gasUsed ? estimatedIndividualGas - gasUsed : 0;
    }
    
    function _calculatePriceImprovement(uint256 orderId, uint256 executionTick) internal view returns (uint256) {
        // Simple price improvement calculation
        // In a real implementation, this would compare against initial target price
        return 50; // 0.5% improvement placeholder
    }

    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Set new owner
     */
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }
    
    /**
     * @notice Emergency function to clear stuck queue
     */
    function emergencyClearQueue(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        BestExecutionQueue storage queue = bestExecutionQueues[poolId];
        
        // Clear all positions - optimized loop
        uint256 length = queue.queuedOrderIds.length;
        unchecked {
            for (uint256 i; i < length; ++i) {
                delete queue.orderPositions[queue.queuedOrderIds[i]];
            }
        }
        
        // Reset queue
        delete queue.queuedOrderIds;
        queue.currentIndex = 0;
        queue.lastProcessedTimestamp = uint64(block.timestamp);
    }
}
