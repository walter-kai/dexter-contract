// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LimitOrderBatch} from "../LimitOrderBatch.sol";
import {ILimitOrderBatchTesting} from "../interfaces/ILimitOrderBatchTesting.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

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
    using FixedPointMathLib for uint256;

    constructor(IPoolManager _poolManager, address _feeRecipient) 
        LimitOrderBatch(_poolManager, _feeRecipient, msg.sender) // Use msg.sender as owner
    {
        // Testing version constructor
    }

    /**
     * @notice Backwards-compatible createBatchOrder for testing
     * @dev 7-parameter version for test compatibility 
     */
    function createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint256 expirationTime
    ) external payable override returns (uint256 batchId) {
        // Call the parent with simplified parameters
        return _createBatchOrderInternal(
            currency0, currency1, fee, zeroForOne,
            targetPrices, targetAmounts, expirationTime
        );
    }

    /**
     * @notice Backwards-compatible createBatchOrder for testing
     * @dev 8-parameter version for test compatibility
     */
    function createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint256 expirationTime,
        uint256 /* bestPriceTimeout */
    ) external payable returns (uint256 batchId) {
        // Call the parent with simplified parameters
        return _createBatchOrderInternal(
            currency0, currency1, fee, zeroForOne,
            targetPrices, targetAmounts, expirationTime
        );
    }

    /**
     * @notice Backwards-compatible createBatchOrder for testing (PoolKey variant)
     * @dev 4-parameter version for test compatibility
     */
    function createBatchOrder(PoolKey calldata key, int24 tick, uint256 amount, bool zeroForOne) external payable returns (uint256 batchId) {
        // Convert single tick to arrays
        uint256[] memory prices = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        prices[0] = uint256(TickMath.getSqrtPriceAtTick(tick));
        amounts[0] = amount;
        
        return _createBatchOrderInternal(
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            zeroForOne,
            prices,
            amounts,
            block.timestamp + 3600
        );
    }

    /**
     * @notice Get pending orders at a specific tick (testing compatibility)
     */
    function getPendingOrdersAtTick(PoolKey calldata key, int24 tick, bool zeroForOne) external view returns (uint256) {
        return pendingBatchOrders[key.toId()][tick][zeroForOne];
    }

    /**
     * @notice Redeem tokens (testing compatibility wrapper)
     */
    function redeem(uint256 batchOrderId, uint256 inputAmountToClaimFor) external {
        // Forward the call with the original sender
        require(balanceOf[msg.sender][batchOrderId] >= inputAmountToClaimFor, "Insufficient balance");
        require(claimableOutputTokens[batchOrderId] > 0, "Nothing to claim");

        // Calculate proportional output
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            claimableOutputTokens[batchOrderId],
            claimTokensSupply[batchOrderId]
        );

        // Update state
        claimableOutputTokens[batchOrderId] -= outputAmount;
        claimTokensSupply[batchOrderId] -= inputAmountToClaimFor;
        _burn(msg.sender, address(uint160(batchOrderId)), inputAmountToClaimFor);

        // Transfer tokens without fee for test compatibility
        BatchInfo storage batch = batchOrders[batchOrderId];
        Currency outputToken = batch.zeroForOne ? batch.poolKey.currency1 : batch.poolKey.currency0;
        outputToken.transfer(msg.sender, outputAmount);

        emit Debug("Dev tokens redeemed", outputAmount);
    }    /**
     * @notice Get fee information (testing compatibility)
     */
    function getFeeInfo() external view returns (address feeRecipientAddr, uint256 feeBasisPoints, uint256 basisPointsDenominator, uint24 baseFee, uint24 currentDynamicFee, uint128 currentGasPrice, uint128 averageGasPrice) {
        return (
            FEE_RECIPIENT,
            FEE_BASIS_POINTS, // Use backward compatibility constant
            BASIS_POINTS_DENOMINATOR,
            BASE_FEE,
            BASE_FEE, // Simplified - no dynamic fees in core
            uint128(tx.gasprice),
            0 // Gas tracking moved to tools contract
        );
    }

    /**
     * @notice Check if pool is initialized (testing compatibility)
     */
    function isPoolInitialized(address currency0, address currency1, uint24 fee) external view returns (bool) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(this))
        });
        
        // Check if we have a last tick recorded (indicates initialization)
        return lastTicks[key.toId()] != 0;
    }

    /**
     * @notice Initialize pool with hook (testing compatibility)
     */
    function initializePoolWithHook(address currency0, address currency1, uint24 fee) external returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000, // Force dynamic fee
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(this))
        });
        
        // Initialize with a default tick (this is simplified for testing)
        lastTicks[key.toId()] = 0;
        
        return key;
    }

    /**
     * @notice Check if pool is initialized by PoolId (testing compatibility)
     */
    function poolInitializedById(PoolId poolId) external view returns (bool) {
        return poolInitialized[poolId];
    }

    /**
     * @notice Get pool initialization block (testing compatibility)
     */
    function poolInitializationBlock(PoolId /* poolId */) external pure returns (uint256) {
        // For testing, return a constant value (simplified implementation)
        return 1;
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
    ) external pure returns (bytes4, BeforeSwapDelta, uint24) {
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
        BatchInfo storage info = batchOrders[batchId];
        require(info.isActive, "Batch order not active");
        require(priceLevel < info.ticksLength, "Invalid price level");
        
        // Check if this level has already been executed
        int24 targetTick = batchTargetTicks[batchId][priceLevel];
        PoolId poolId = info.poolKey.toId();
        uint256 pendingAmount = pendingBatchOrders[poolId][targetTick][info.zeroForOne];
        
        if (pendingAmount == 0) {
            return false; // Already executed or no pending orders at this tick
        }
        
        // Calculate execution amount for this level
        uint256 levelAmount = batchTargetAmounts[batchId][priceLevel];
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
        
        emit BatchLevelExecuted(batchId, priceLevel, uint256(int256(targetTick)), executeAmount);
        
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
        // Use key directly
        PoolId poolId = key.toId();
        
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

        // Following TakeProfitsHook logic for tick range execution
        if (currentTick > lastTick) {
            // Tick increased - execute orders selling token0
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[poolId][tick][zeroForOne];
                if (inputAmount > 0) {
                    _executeLimitOrderAtTick(key, tick, zeroForOne, inputAmount, inputAmount);
                    return (true, currentTick);
                }
            }
        } else if (currentTick < lastTick) {
            // Tick decreased - execute orders selling token1
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[poolId][tick][zeroForOne];
                if (inputAmount > 0) {
                    _executeLimitOrderAtTick(key, tick, zeroForOne, inputAmount, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            // currentTick == lastTick - queue for best execution
            uint256 inputAmount = pendingBatchOrders[poolId][currentTick][zeroForOne];
            emit DebugQueueCheck(currentTick, zeroForOne, inputAmount);
            if (inputAmount > 0) {
                // Simplified - execute immediately instead of queueing
                _executeLimitOrderAtTick(key, currentTick, zeroForOne, inputAmount, inputAmount);
                return (true, currentTick);
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
        // Use key directly
        PoolId poolId = key.toId();
        return pendingBatchOrders[poolId][tick][zeroForOne];
    }

    // Override the main batch order execution function to use internal key conversion
    function tryExecutingBatchOrders(
        PoolKey calldata key,
        bool /* zeroForOne */
    ) internal returns (bool tryMore, int24 newTick) {
        // Use key directly
        PoolId poolId = key.toId();
        
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // Following TakeProfitsHook logic for tick range execution
        if (currentTick > lastTick) {
            // Tick increased - execute orders selling token0 (triggered by zeroForOne=false swaps)
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[poolId][tick][true]; // Always check sell token0 orders
                if (inputAmount > 0) {
                    _executeLimitOrderAtTick(key, tick, true, inputAmount, inputAmount);
                    return (true, currentTick);
                }
            }
        } else if (currentTick < lastTick) {
            // Tick decreased - execute orders selling token1 (triggered by zeroForOne=true swaps)
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[poolId][tick][false]; // Always check sell token1 orders
                if (inputAmount > 0) {
                    _executeLimitOrderAtTick(key, tick, false, inputAmount, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            // currentTick == lastTick - queue for best execution
            // Check both directions for orders at the current tick
            uint256 inputAmountToken0 = pendingBatchOrders[poolId][currentTick][true]; // Sell token0 orders
            uint256 inputAmountToken1 = pendingBatchOrders[poolId][currentTick][false]; // Sell token1 orders
            
            if (inputAmountToken0 > 0) {
                _executeLimitOrderAtTick(key, currentTick, true, inputAmountToken0, inputAmountToken0);
                return (true, currentTick);
            }
            if (inputAmountToken1 > 0) {
                _executeLimitOrderAtTick(key, currentTick, false, inputAmountToken1, inputAmountToken1);
                return (true, currentTick);
            }
        }

        return (false, currentTick);
    }

    // Override queue functions to use internal key conversion for testing compatibility
    function getQueueStatus(PoolKey calldata /* key */) external pure returns (
        uint256 queueLength,
        uint256 currentIndex,
        uint256[] memory queuedOrders
    ) {
        // Simplified - no queues in optimized version
        return (0, 0, new uint256[](0));
    }

    // Additional function for tools integration tests
    function getQueueDetails(PoolKey calldata /* key */) external pure returns (
        uint256[] memory queuedOrders,
        uint256 currentIndex,
        uint64 lastProcessedTimestamp
    ) {
        // Simplified - no queues in optimized version
        return (new uint256[](0), 0, 0);
    }

    // View functions for testing tools functionality
    function getPoolTracker(PoolId /* poolId */) external pure returns (
        uint160 initialSqrtPriceX96,
        uint64 initializationTimestamp,
        uint32 totalOrdersProcessed,
        uint64 firstOrderTimestamp,
        int24 initialTick,
        bool isInitialized
    ) {
        // Simplified - no advanced tracking in optimized version
        return (0, 0, 0, 0, 0, true);
    }

    function getPriceAnalytics(PoolId /* poolId */) external pure returns (
        int24[] memory recentTicks,
        uint256[] memory recentTimestamps,
        uint64 lastAnalysisTimestamp,
        uint32 volatilityScore,
        uint32 averageTickMovement,
        int24 trendDirection
    ) {
        // Simplified - no price analytics in optimized version
        return (
            new int24[](0),
            new uint256[](0),
            0,
            0,
            0,
            0
        );
    }

    function getAdvancedMetrics(uint256 /* orderId */) external pure returns (
        uint64 creationTimestamp,
        uint64 expectedExecutionTime,
        uint64 actualExecutionTime,
        uint32 creationGasPrice,
        uint32 bestPriceAchieved,
        uint32 slippageRealized,
        uint32 gasSavingsRealized,
        bool usedBestExecution
    ) {
        // Simplified - no advanced metrics in optimized version
        return (0, 0, 0, 0, 0, 0, 0, false);
    }

    // Test helper functions to expose internal calculations
    function testCalculateGasSavings(uint256 /* orderId */, uint256 gasUsed) external pure returns (uint256) {
        return gasUsed > 100000 ? gasUsed - 100000 : 0;
    }

    function testCalculatePriceImprovement(uint256 /* orderId */, uint256 /* executionTick */) external pure returns (uint256) {
        return 0; // Simplified implementation
    }

    // ========== TOOLS INTEGRATION FUNCTIONS ==========
    
    /**
     * @notice Queue for best execution (simplified implementation for testing)
     */
    function queueForBestExecution(
        uint256 orderId, 
        PoolKey calldata /* key */, 
        int24 /* targetTick */, 
        uint256 timeoutSeconds
    ) external {
        require(timeoutSeconds > 0 && timeoutSeconds <= 300, "Invalid timeout");
        require(orderId > 0, "Invalid order ID");
        
        // Simplified - just emit event for testing
        emit Debug("Order queued for best execution", orderId);
    }

    /**
     * @notice Process best execution queue (simplified implementation)
     */
    function processQueue(PoolKey calldata /* key */) external pure returns (uint256 processed) {
        // Simplified - return 0 processed orders
        return 0;
    }

    /**
     * @notice Process best execution queue with better tick (simplified implementation)
     */
    function processBestExecutionQueue(PoolKey calldata /* key */, int24 /* betterTick */) external pure returns (uint256[] memory processed) {
        // Simplified - return empty array
        return new uint256[](0);
    }

    /**
     * @notice Track gas price (simplified implementation)
     */
    function trackGasPrice(uint128 gasPrice) external {
        // Simplified - just emit event
        emit GasPriceTrackedOptimized(gasPrice, gasPrice, 1);
    }

    /**
     * @notice Track pool initialization (simplified implementation)
     */
    function trackPoolInitialization(PoolKey calldata key, int24 tick) external {
        PoolId poolId = key.toId();
        lastTicks[poolId] = tick;
        poolInitialized[poolId] = true;
        emit PoolInitializationTracked(poolId, tick, block.timestamp);
    }

    // Override batch order execution to use internal key for pending orders
    function _executeBatchOrderAtTick(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount,
        bool updatePendingOrders
    ) internal {
        // Execute swap following TakeProfitsHook pattern
        // Use the available unlock callback mechanism
        bytes memory result = poolManager.unlock(abi.encode(key, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount), // Exact input
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        })));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        // Remove from pending orders only if requested
        if (updatePendingOrders) {
            PoolId poolId = key.toId();
            pendingBatchOrders[poolId][tick][zeroForOne] -= inputAmount;
        }
        
        // Calculate output amount
        uint256 outputAmount = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));

        // Find corresponding batch order ID using simplified lookup
        uint256[] storage batchIds = tickToBatchIds[key.toId()][tick][zeroForOne];
        uint256 batchOrderId = batchIds.length > 0 ? batchIds[0] : 1;
        if (batchOrderId != 0) {
            claimableOutputTokens[batchOrderId] += outputAmount;
            emit BatchLevelExecuted(batchOrderId, uint256(uint24(tick)), uint256(int256(tick)), inputAmount);
        }
    }
}
