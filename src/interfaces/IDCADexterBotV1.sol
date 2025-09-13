// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IDCADexterBotV1
 * @notice Interface for a DCA (Dollar Cost Averaging) bot supporting perpetual orders,
 *         customizable pool and DCA parameters, and batch execution with advanced controls.
 */
interface IDCADexterBotV1 {
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
    function createDCAOrder(
        PoolParams calldata pool,
        DCAParams calldata dca,
        uint32 slippage,
        uint256 expirationTime,
    uint256 gasTankAmount,
    uint32 gasTankPercent
    ) external payable returns (uint256 dcaId);

    // Cancel / redeem
    function cancelDCAOrder(uint256 dcaId) external;
    function redeemProfits(uint256 dcaId, uint256 inputAmountToClaimFor) external;

    // Views for DCA orders
    function getDCAInfo(uint256 dcaId) external view returns (
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

    function getDCAInfoExtended(uint256 dcaId) external view returns (
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
        uint24 currentFee,
        uint256 gasTankAmount,
        uint256 gasTankPercent,
        bool isStalled
    );

    function getDCAOrder(uint256 dcaId) external view returns (
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

    // Pool helpers
    function getPoolCurrentTick(PoolId poolId) external view returns (int24);
}
