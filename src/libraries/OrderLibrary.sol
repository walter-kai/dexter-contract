// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title OrderLibrary
 * @notice Library for order management utilities
 */
library OrderLibrary {
    /**
     * @notice Add order to active orders array
     * @param activeOrders Array of active order IDs
     * @param activeOrderIndex Mapping of order ID to index
     * @param orderId Order ID to add
     */
    function addToActiveOrders(
        uint256[] storage activeOrders,
        mapping(uint256 => uint256) storage activeOrderIndex,
        uint256 orderId
    ) internal {
        activeOrderIndex[orderId] = activeOrders.length;
        activeOrders.push(orderId);
    }

    /**
     * @notice Remove order from active orders array
     * @param activeOrders Array of active order IDs
     * @param activeOrderIndex Mapping of order ID to index
     * @param orderId Order ID to remove
     */
    function removeFromActiveOrders(
        uint256[] storage activeOrders,
        mapping(uint256 => uint256) storage activeOrderIndex,
        uint256 orderId
    ) internal {
        uint256 index = activeOrderIndex[orderId];
        require(index < activeOrders.length, "Invalid order index");

        uint256 lastOrderId = activeOrders[activeOrders.length - 1];
        activeOrders[index] = lastOrderId;
        activeOrderIndex[lastOrderId] = index;

        activeOrders.pop();
        delete activeOrderIndex[orderId];
    }

    /**
     * @notice Calculate required output amount based on limit price
     * @param amountIn Input amount
     * @param limitPrice Limit price
     * @param zeroForOne Order direction
     * @param currency0 First currency address
     * @param currency1 Second currency address
     * @return requiredOutput Required output amount
     */
    function calculateRequiredOutput(
        uint256 amountIn,
        uint256 limitPrice,
        bool zeroForOne,
        address currency0,
        address currency1
    ) internal pure returns (uint256 requiredOutput) {
        if (zeroForOne && currency1 != address(0)) {
            // ETH->USDC order: amountIn is in ETH (18 decimals), limitPrice is USDC per ETH (6 decimals)
            // For 1 ETH at 4000 USDC/ETH: (1e18 * 4000e6) / 1e18 = 4000e6 = 4000 USDC
            requiredOutput = (amountIn * limitPrice) / 1e18;
        } else if (!zeroForOne && currency0 != address(0)) {
            // USDC->ETH order: amountIn is in USDC (6 decimals), limitPrice is USDC per ETH (6 decimals)
            requiredOutput = (amountIn * 1e18) / limitPrice;
        } else {
            requiredOutput = amountIn; // Fallback
        }
    }
}
