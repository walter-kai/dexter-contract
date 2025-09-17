// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title IDexterHook
 * @notice Interface for a DCA (Dollar Cost Averaging) bot supporting perpetual orders,
 *         customizable pool and DCA parameters, and batch execution with advanced controls.
 */
interface IDexterHook {
    // Order execution status
    enum OrderStatus {
        ACTIVE, // Order is running normally
        COMPLETED, // Order finished successfully (take profit hit)
        CANCELLED, // Order was manually cancelled
        STALLED // Order is stalled due to insufficient gas

    }

    struct PoolParams {
        address currency0;
        address currency1;
        uint24 fee;
    }

    struct DCAParams {
        bool zeroForOne;
        uint32 takeProfitPercent;
        uint8 maxSwapOrders;
        uint32 priceDeviationPercent;
        uint32 priceDeviationMultiplier;
        uint256 swapOrderAmount;
        uint32 swapOrderMultiplier;
    }

    // Create a new perpetual DCA order
    function createDCAStrategy(
        PoolParams calldata pool,
        DCAParams calldata dca,
        uint32 slippage,
        uint256 expirationTime
    ) external payable returns (uint256 dcaId);

    // Immediate manual sell (market sell accumulated output and restart)
    function sellNow(uint256 dcaId) external;

    // Cancel
    function cancelDCAStrategy(uint256 dcaId) external;

    // Views for DCA orders
    function getDCAInfo(uint256 dcaId)
        external
        view
        returns (
            address user,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256 claimableAmount,
            IDexterHook.OrderStatus status,
            bool isFullyExecuted,
            uint256 expirationTime,
            bool zeroForOne,
            uint256 totalBatches,
            uint24 currentFee
        );

    function getDCAInfoExtended(uint256 dcaId)
        external
        view
        returns (
            address user,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256 claimableAmount,
            IDexterHook.OrderStatus status,
            bool isFullyExecuted,
            uint256 expirationTime,
            bool zeroForOne,
            uint256 totalBatches,
            uint24 currentFee,
            uint256 gasAllocated,
            uint256 gasUsed
        );

    function getDCAOrder(uint256 dcaId)
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
            IDexterHook.OrderStatus status,
            bool isFullyExecuted
        );

    // Pool helpers
    function getPoolCurrentTick(PoolId poolId) external view returns (int24);
    function getAllPools()
        external
        view
        returns (PoolId[] memory poolIds, PoolKey[] memory poolKeys, int24[] memory ticks);
    function getPoolCount() external view returns (uint256);
}
