// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/**
 * @title BatchOrderLogic
 * @notice External library to reduce LimitOrderBatch contract size
 * @dev Contains complex batch order execution logic
 */
library BatchOrderLogic {
    using PoolIdLibrary for PoolKey;

    /// @notice Queued order struct
    struct QueuedOrder {
        uint256 batchOrderId;
        int24 originalTick;
        int24 targetTick;
        uint256 amount;
        uint256 queueTime;
        uint256 maxWaitTime;
        bool zeroForOne;
    }

    /// @notice Events
    event OrderExecutedFromQueue(
        uint256 indexed batchOrderId,
        int24 originalTick,
        int24 executionTick,
        uint256 amount,
        bool wasTimeout
    );

    event OrderQueuedForBestExecution(
        uint256 indexed batchOrderId,
        int24 currentTick,
        int24 targetTick,
        uint256 amount
    );

    /**
     * @notice Process queued orders for best execution
     * @param key Pool key
     * @param currentTick Current pool tick
     * @param bestPriceQueue Storage reference to the queue
     * @param queueIndex Storage reference to queue index
     * @param poolManager Pool manager instance
     * @param contractAddress Address of the calling contract
     */
    function processQueuedOrders(
        PoolKey calldata key,
        int24 currentTick,
        mapping(PoolId => QueuedOrder[]) storage bestPriceQueue,
        mapping(PoolId => uint256) storage queueIndex,
        IPoolManager poolManager,
        address contractAddress
    ) external {
        PoolId poolId = key.toId();
        QueuedOrder[] storage queue = bestPriceQueue[poolId];
        uint256 currentIndex = queueIndex[poolId];
        
        // Process orders in queue
        while (currentIndex < queue.length) {
            QueuedOrder storage order = queue[currentIndex];
            bool shouldExecute = false;
            
            // Check if best execution achieved or timeout
            if (order.zeroForOne && currentTick >= order.targetTick) {
                shouldExecute = true; // Better sell price for token0
            } else if (!order.zeroForOne && currentTick <= order.targetTick) {
                shouldExecute = true; // Better sell price for token1
            } else if (block.timestamp >= order.maxWaitTime) {
                shouldExecute = true; // Timeout - execute at current price
            }
            
            if (shouldExecute) {
                // Execute the order using delegatecall to maintain context
                (bool success, ) = contractAddress.delegatecall(
                    abi.encodeWithSignature(
                        "_executeBatchOrderWithId(PoolKey,int24,bool,uint256,uint256)",
                        key,
                        currentTick,
                        order.zeroForOne,
                        order.amount,
                        order.batchOrderId
                    )
                );
                
                if (success) {
                    emit OrderExecutedFromQueue(
                        order.batchOrderId,
                        order.originalTick,
                        currentTick,
                        order.amount,
                        block.timestamp >= order.maxWaitTime
                    );
                }
                
                // Remove from queue
                queue[currentIndex] = queue[queue.length - 1];
                queue.pop();
            } else {
                currentIndex++;
            }
            
            // Prevent infinite loops
            if (gasleft() < 50000) break;
        }
        
        queueIndex[poolId] = currentIndex;
    }

    /**
     * @notice Queue order for best price execution
     * @param key Pool key
     * @param currentTick Current tick
     * @param zeroForOne Swap direction
     * @param amount Amount to queue
     * @param timeoutSeconds Timeout in seconds (0 = no timeout)
     * @param batchOrderId Associated batch order ID
     * @param bestPriceQueue Storage reference to the queue
     * @param pendingBatchOrders Storage reference to pending orders
     * @param BEST_EXECUTION_TICKS Constant for tick calculation
     */
    function queueForBestExecution(
        PoolKey calldata key,
        int24 currentTick,
        bool zeroForOne,
        uint256 amount,
        uint256 timeoutSeconds,
        uint256 batchOrderId,
        mapping(PoolId => QueuedOrder[]) storage bestPriceQueue,
        mapping(PoolId => mapping(int24 => mapping(bool => uint256))) storage pendingBatchOrders,
        int24 BEST_EXECUTION_TICKS
    ) external {
        PoolId poolId = key.toId();
        
        // Calculate target tick for better price
        int24 targetTick;
        if (zeroForOne) {
            // For selling token0, wait for higher tick (better price)
            targetTick = currentTick + (BEST_EXECUTION_TICKS * key.tickSpacing);
        } else {
            // For selling token1, wait for lower tick (better price)
            targetTick = currentTick - (BEST_EXECUTION_TICKS * key.tickSpacing);
        }
        
        // Remove from pending orders at original tick (move to queue)
        pendingBatchOrders[poolId][currentTick][zeroForOne] -= amount;
        
        // Calculate maxWaitTime: if timeoutSeconds is 0, disable timeout (set to max)
        uint256 maxWaitTime = timeoutSeconds == 0 
            ? type(uint256).max 
            : block.timestamp + timeoutSeconds;
        
        // Add to queue
        bestPriceQueue[poolId].push(QueuedOrder({
            batchOrderId: batchOrderId,
            originalTick: currentTick,
            targetTick: targetTick,
            amount: amount,
            queueTime: block.timestamp,
            maxWaitTime: maxWaitTime,
            zeroForOne: zeroForOne
        }));
        
        emit OrderQueuedForBestExecution(batchOrderId, currentTick, targetTick, amount);
    }

    /**
     * @notice Calculate slippage protected price
     * @param tick Target tick
     * @param zeroForOne Swap direction
     * @param maxSlippageBps Maximum slippage in basis points
     * @return slippageProtectedPrice Price limit with slippage protection
     */
    function calculateSlippageProtectedPrice(
        int24 tick,
        bool zeroForOne,
        uint256 maxSlippageBps
    ) external pure returns (uint160 slippageProtectedPrice) {
        uint160 targetPrice = TickMath.getSqrtPriceAtTick(tick);
        
        if (maxSlippageBps == 0) {
            // No slippage protection - use min/max limits
            return zeroForOne 
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1;
        }
        
        // Calculate slippage adjustment
        uint256 slippageAdjustment = (uint256(targetPrice) * maxSlippageBps) / 10000;
        
        if (zeroForOne) {
            // For zeroForOne swaps, protect against price going too low
            slippageProtectedPrice = uint160(uint256(targetPrice) - slippageAdjustment);
            if (slippageProtectedPrice <= TickMath.MIN_SQRT_PRICE) {
                slippageProtectedPrice = TickMath.MIN_SQRT_PRICE + 1;
            }
        } else {
            // For oneForZero swaps, protect against price going too high
            slippageProtectedPrice = uint160(uint256(targetPrice) + slippageAdjustment);
            if (slippageProtectedPrice >= TickMath.MAX_SQRT_PRICE) {
                slippageProtectedPrice = TickMath.MAX_SQRT_PRICE - 1;
            }
        }
    }
}
