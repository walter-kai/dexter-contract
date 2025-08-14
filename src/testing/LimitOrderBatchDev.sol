// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LimitOrderBatch} from "../LimitOrderBatch.sol";
import {ILimitOrderBatchTesting} from "../interfaces/ILimitOrderBatchTesting.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Interface for MockPoolManager (testing only)
interface IMockPoolManager {
    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint16, uint8);
}

/**
 * @title LimitOrderBatchTesting - Testing Version
 * @notice Testing version of LimitOrderBatch with additional test functions
 * @dev This contract should ONLY be used for testing/development, never in production
 */
contract LimitOrderBatchDev is LimitOrderBatch, ILimitOrderBatchTesting {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    constructor(IPoolManager _poolManager, address _feeRecipient) 
        LimitOrderBatch(_poolManager, _feeRecipient) 
    {
        // Testing version constructor
    }

    /**
     * @notice Test function to simulate afterSwap for testing purposes
     * @dev Only available in testing version
     */
    function testAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    /**
     * @notice Test function to simulate beforeSwap for testing purposes
     * @dev Only available in testing version
     */
    function testBeforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external view returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, hookData);
    }

    /**
     * @notice Test function to set lastTick for testing purposes
     * @dev Only available in testing version
     */
    function testSetLastTick(PoolKey calldata key, int24 tick) external override {
        lastTicks[key.toId()] = tick;
    }

    /**
     * @notice Test function to manually execute a batch level (for testing only)
     * @param batchId The batch order ID
     * @param priceLevel The price level index to execute (0-based)
     * @return success Whether the execution was successful
     */
    function testExecuteBatchLevel(uint256 batchId, uint256 priceLevel) 
        external 
        override
        returns (bool success) {
        BatchOrderInfo storage info = batchOrdersInfo[batchId];
        require(info.isActive, "Batch order not active");
        require(priceLevel < info.targetTicks.length, "Invalid price level");
        
        // Check if this level has already been executed
        int24 targetTick = info.targetTicks[priceLevel];
        PoolId poolId = info.poolKey.toId();
        uint256 pendingAmount = pendingBatchOrders[poolId][targetTick][info.zeroForOne];
        
        if (pendingAmount == 0) {
            return false; // Already executed or no pending orders at this tick
        }
        
        // Calculate execution amount for this level
        uint256 levelAmount = info.targetAmounts[priceLevel];
        uint256 executeAmount = pendingAmount < levelAmount ? pendingAmount : levelAmount;
        
        // Remove from pending orders
        pendingBatchOrders[poolId][targetTick][info.zeroForOne] -= executeAmount;
        
        // For testing, simulate successful execution without actual swap
        // In production, this would be done through actual swaps in the hook
        uint256 mockOutputAmount = executeAmount * 2400; // Mock 1 ETH = 2400 USDC
        claimableOutputTokens[batchId] += mockOutputAmount;
        
        // Update claim supply to reflect execution
        uint256 remainingClaims = claimTokensSupply[batchId];
        if (remainingClaims >= executeAmount) {
            claimTokensSupply[batchId] = remainingClaims - executeAmount;
        }
        
        emit BatchLevelExecuted(batchId, uint256(uint24(targetTick)), uint256(int256(targetTick)), executeAmount);
        emit BatchOrderExecuted(batchId, targetTick, executeAmount, mockOutputAmount);
        
        return true;
    }

    /**
     * @notice Check if testing is enabled (always true for testing version)
     */
    function isTestingEnabled() external pure override returns (bool) {
        return true;
    }

    /**
     * @notice Override tryExecutingBatchOrders to support mock pool manager and debug events
     */
    function tryExecutingBatchOrdersTest(
        PoolKey calldata key,
        bool zeroForOne
    ) external returns (bool tryMore, int24 newTick) {
        // Convert to internal key for accessing storage
        PoolKey memory internalKey = _toInternalKey(key);
        PoolId poolId = internalKey.toId();
        
        int24 currentTick;
        // In testing mode, try mock first then fallback to StateLibrary
        try IMockPoolManager(address(poolManager)).getSlot0(PoolId.unwrap(key.toId())) returns (
            uint160, int24 tick, uint16, uint8
        ) {
            currentTick = tick;
        } catch {
            // Fallback to StateLibrary if cast fails
            (, currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        }
        
        int24 lastTick = lastTicks[key.toId()];

        // Debug output for testing
        emit DebugTryExecuting(currentTick, lastTick, zeroForOne);

        // First, check queued orders for best execution
        _processQueuedOrders(key, currentTick);

        // Following TakeProfitsHook logic for tick range execution
        if (currentTick > lastTick) {
            // Tick increased - execute orders selling token0
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[poolId][tick][zeroForOne];
                if (inputAmount > 0) {
                    executeBatchOrderAtTick(key, tick, zeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        } else if (currentTick < lastTick) {
            // Tick decreased - execute orders selling token1
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[poolId][tick][zeroForOne];
                if (inputAmount > 0) {
                    executeBatchOrderAtTick(key, tick, zeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            // currentTick == lastTick - queue for best execution
            uint256 inputAmount = pendingBatchOrders[poolId][currentTick][zeroForOne];
            emit DebugQueueCheck(currentTick, zeroForOne, inputAmount);
            if (inputAmount > 0) {
                // For dev mode, we need to call our version that handles key conversion
                _queueForBestPriceWithInternalKey(key, internalKey, currentTick, zeroForOne, inputAmount);
                return (false, currentTick); // Don't execute immediately
            }
        }

        return (false, currentTick);
    }

    /**
     * @notice Test helper to get current tick with mock support
     */
    function getCurrentTickTest(PoolKey calldata key) external view returns (int24 currentTick) {
        // Try mock manager first
        try IMockPoolManager(address(poolManager)).getSlot0(PoolId.unwrap(key.toId())) returns (
            uint160, int24 tick, uint16, uint8
        ) {
            return tick;
        } catch {
            // Fallback to StateLibrary
            (, currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
            return currentTick;
        }
    }

    /**
     * @notice Test helper to emit debug events
     */
    function emitDebugTryExecuting(int24 currentTick, int24 lastTick, bool zeroForOne) external {
        emit DebugTryExecuting(currentTick, lastTick, zeroForOne);
    }

    /**
     * @notice Test helper to emit debug queue events
     */
    function emitDebugQueueCheck(int24 currentTick, bool zeroForOne, uint256 inputAmount) external {
        emit DebugQueueCheck(currentTick, zeroForOne, inputAmount);
    }

    /**
     * @notice Debug function to check pending batch orders
     */
    function debugPendingBatchOrders(PoolKey calldata key, int24 tick, bool zeroForOne) external view returns (uint256) {
        return pendingBatchOrders[key.toId()][tick][zeroForOne];
    }

    /**
     * @notice Check pending orders using PoolKey (allows key conversion)
     */
    function getPendingBatchOrdersWithKey(PoolKey calldata key, int24 tick, bool zeroForOne) external view returns (uint256) {
        // Convert to internal key for accessing pending orders
        PoolKey memory internalKey = _toInternalKey(key);
        PoolId poolId = internalKey.toId();
        return pendingBatchOrders[poolId][tick][zeroForOne];
    }

    /**
     * @notice Queue for best execution with explicit key handling for testing
     */
    function _queueForBestPriceWithInternalKey(
        PoolKey calldata userKey,
        PoolKey memory internalKey,
        int24 currentTick,
        bool zeroForOne,
        uint256 amount
    ) internal {
        PoolId poolId = internalKey.toId();
        
        // Calculate target tick for better price
        int24 targetTick;
        if (zeroForOne) {
            // For selling token0, wait for higher tick (better price)
            targetTick = currentTick + (BEST_EXECUTION_TICKS * userKey.tickSpacing);
        } else {
            // For selling token1, wait for lower tick (better price)
            targetTick = currentTick - (BEST_EXECUTION_TICKS * userKey.tickSpacing);
        }
        
        // Find the batch order ID for this tick using internal key
        uint256 batchOrderId = _getBatchIdForTick(poolId, currentTick, zeroForOne);
        
        // Remove from pending orders at original tick (use internal key storage)
        pendingBatchOrders[poolId][currentTick][zeroForOne] -= amount;
        
        // Add to queue (use internal key storage)
        bestPriceQueue[poolId].push(QueuedOrder({
            batchOrderId: batchOrderId,
            originalTick: currentTick,
            targetTick: targetTick,
            amount: amount,
            queueTime: _getBlockTimestamp(),
            maxWaitTime: _getBlockTimestamp() + 300, // 5 minute default for testing
            zeroForOne: zeroForOne
        }));
        
        emit OrderQueuedForBestExecution(batchOrderId, currentTick, targetTick, amount);
    }

    // Override the main batch order execution function to use internal key conversion
    function tryExecutingBatchOrders(
        PoolKey calldata key,
        bool zeroForOne
    ) internal override returns (bool tryMore, int24 newTick) {
        // Convert to internal key for accessing storage
        PoolKey memory internalKey = _toInternalKey(key);
        PoolId poolId = internalKey.toId();
        
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // First, check queued orders for best execution
        _processQueuedOrders(key, currentTick);

        // Following TakeProfitsHook logic for tick range execution
        if (currentTick > lastTick) {
            // Tick increased - execute orders selling token0 (triggered by zeroForOne=false swaps)
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[poolId][tick][true]; // Always check sell token0 orders
                if (inputAmount > 0) {
                    executeBatchOrderAtTick(key, tick, true, inputAmount);
                    return (true, currentTick);
                }
            }
        } else if (currentTick < lastTick) {
            // Tick decreased - execute orders selling token1 (triggered by zeroForOne=true swaps)
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[poolId][tick][false]; // Always check sell token1 orders
                if (inputAmount > 0) {
                    executeBatchOrderAtTick(key, tick, false, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            // currentTick == lastTick - queue for best execution
            // Check both directions for orders at the current tick
            uint256 inputAmountToken0 = pendingBatchOrders[poolId][currentTick][true]; // Sell token0 orders
            uint256 inputAmountToken1 = pendingBatchOrders[poolId][currentTick][false]; // Sell token1 orders
            
            if (inputAmountToken0 > 0) {
                _queueForBestPriceWithInternalKey(key, internalKey, currentTick, true, inputAmountToken0);
                return (false, currentTick); // Don't execute immediately
            }
            if (inputAmountToken1 > 0) {
                _queueForBestPriceWithInternalKey(key, internalKey, currentTick, false, inputAmountToken1);
                return (false, currentTick); // Don't execute immediately
            }
        }

        return (false, currentTick);
    }

    // Override queue functions to use internal key conversion for testing compatibility
    function getQueueStatus(PoolKey calldata key) external view override returns (
        uint256 queueLength,
        uint256 currentIndex,
        QueuedOrder[] memory orders
    ) {
        // Convert to internal key for accessing queue
        PoolKey memory internalKey = _toInternalKey(key);
        PoolId poolId = internalKey.toId();
        
        return (
            bestPriceQueue[poolId].length,
            queueIndex[poolId],
            bestPriceQueue[poolId]
        );
    }

    function clearExpiredQueuedOrders(PoolKey calldata key) external override {
        // Convert to internal key for accessing queue - we need to use the internal key directly
        PoolKey memory internalKey = _toInternalKey(key);
        PoolId poolId = internalKey.toId();
        QueuedOrder[] storage queue = bestPriceQueue[poolId];
        
        uint256 i = 0;
        while (i < queue.length) {
            if (_getBlockTimestamp() >= queue[i].maxWaitTime) {
                // Execute expired order at original tick using the original key (not internal key)
                QueuedOrder storage order = queue[i];
                _executeBatchOrderWithId(key, order.originalTick, order.zeroForOne, order.amount, order.batchOrderId);
                
                // Remove from queue
                queue[i] = queue[queue.length - 1];
                queue.pop();
            } else {
                i++;
            }
        }
    }

    // Override queue processing to use internal key conversion
    function _processQueuedOrders(PoolKey calldata key, int24 currentTick) internal override {
        // Convert to internal key for accessing queue
        PoolKey memory internalKey = _toInternalKey(key);
        PoolId poolId = internalKey.toId();
        
        QueuedOrder[] storage queue = bestPriceQueue[poolId];
        uint256 currentIndex = queueIndex[poolId];
        
        // Process orders in queue
        while (currentIndex < queue.length) {
            QueuedOrder storage order = queue[currentIndex];
            bool shouldExecute = false;
            bool shouldRemove = false;
            
            // Check if best execution achieved
            if (order.zeroForOne && currentTick >= order.targetTick) {
                shouldExecute = true; // Better sell price for token0
            } else if (!order.zeroForOne && currentTick <= order.targetTick) {
                shouldExecute = true; // Better sell price for token1
            } else if (_getBlockTimestamp() >= order.maxWaitTime) {
                shouldExecute = true; // Timeout - execute at current price
            }
            
            if (shouldExecute) {
                // Execute the order using user key (for execution) but with internal tracking
                int24 executionTick = currentTick; // Use current tick, not original
                
                // Execute at current tick using known batch order ID
                _executeBatchOrderWithId(key, executionTick, order.zeroForOne, order.amount, order.batchOrderId);
                
                emit OrderExecutedFromQueue(
                    order.batchOrderId, 
                    order.originalTick, 
                    executionTick, 
                    order.amount,
                    _getBlockTimestamp() >= order.maxWaitTime // Was timeout?
                );
                
                shouldRemove = true;
            }
            
            if (shouldRemove) {
                // Remove from queue by swapping with last element
                queue[currentIndex] = queue[queue.length - 1];
                queue.pop();
                // Don't increment currentIndex since we swapped
            } else {
                currentIndex++;
            }
            
            // Prevent infinite loops
            if (gasleft() < 50000) break;
        }
        
        queueIndex[poolId] = currentIndex;
    }

    // Override batch order execution to use internal key for pending orders
    function _executeBatchOrderAtTick(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount,
        bool updatePendingOrders
    ) internal override {
        // Execute swap following TakeProfitsHook pattern
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount), // Exact input
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Remove from pending orders only if requested (use internal key for storage)
        if (updatePendingOrders) {
            PoolKey memory internalKey = _toInternalKey(key);
            PoolId poolId = internalKey.toId();
            pendingBatchOrders[poolId][tick][zeroForOne] -= inputAmount;
        }
        
        // Calculate output amount
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        // Find corresponding batch order ID using internal key for lookup
        PoolKey memory lookupKey = _toInternalKey(key);
        uint256 batchOrderId = _getBatchIdForTick(lookupKey.toId(), tick, zeroForOne);
        if (batchOrderId != 0) {
            claimableOutputTokens[batchOrderId] += outputAmount;
            emit BatchLevelExecuted(batchOrderId, uint256(uint24(tick)), uint256(int256(tick)), inputAmount);
        }
    }
}
