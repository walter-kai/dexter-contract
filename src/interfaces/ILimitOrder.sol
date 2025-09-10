// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILimitOrder
 * @notice Interface for the LimitOrder system
 */
interface ILimitOrder {
    // Order status enum
    enum OrderStatus {
        Active,
        PartiallyFilled,
        Filled,
        Canceled,
        Expired
    }

    // Struct to store order details
    struct Order {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        bool zeroForOne;
        uint256 amount;
        uint256 limitPrice;
        bool isMaker;
        uint32 n;
        address recipient;
        address hook;
        address owner;
        bool active;
        uint256 filledAmount;
        OrderStatus status;
        uint256 expirationTime;
        uint256 slippageTolerance;
    }

    // Events
    event LimitOrderPlaced(
        uint256 indexed orderId,
        address indexed token0,
        address indexed token1,
        uint256 amount,
        uint256 limitPrice
    );

    event LimitOrderCancelled(uint256 indexed orderId, address indexed owner);
    
    event LimitOrderExecuted(
        uint256 indexed orderId,
        address indexed executor,
        uint256 amountIn,
        uint256 amountOut,
        uint256 filledAmount
    );
    
    event LimitOrderPartiallyFilled(
        uint256 indexed orderId,
        uint256 filledAmount,
        uint256 remainingAmount
    );
    
    event LimitOrderExpired(uint256 indexed orderId);
    
    event LimitOrderUpdated(
        uint256 indexed orderId,
        uint256 oldLimitPrice,
        uint256 newLimitPrice
    );

    // Write functions
    function placeLimitOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256 amount,
        uint256 limitPrice,
        address recipient,
        uint256 expirationTime,
        uint256 slippageTolerance
    ) external payable returns (uint256 orderId);

    function cancelLimitOrder(uint256 orderId) external;
    
    function updateLimitPrice(uint256 orderId, uint256 newLimitPrice) external;
    
    function executeLimitOrder(uint256 orderId, uint256 amountToFill) external;
    
    function batchExecuteLimitOrders(uint256[] calldata orderIds, uint256[] calldata amountsToFill) external;
    
    function expireOrders(uint256[] calldata orderIds) external;

    // Read functions
    function getOrder(uint256 orderId) external view returns (Order memory);
    
    function getUserOrders(address user) external view returns (uint256[] memory);
    
    function getActiveOrders() external view returns (uint256[] memory);
    
    function getActiveOrdersForPair(address currency0, address currency1) 
        external view returns (uint256[] memory orderIds, Order[] memory orderDetails);
        
    function getOrdersWithStatus(address user) external view returns (
        uint256[] memory orderIds,
        OrderStatus[] memory statuses,
        uint256[] memory filledAmounts,
        uint256[] memory totalAmounts
    );
    
    function isOrderExecutable(uint256 orderId) external view returns (bool executable);
    
    function getStatistics() external view returns (
        uint256 totalOrders,
        uint256 activeOrderCount,
        uint256 filledOrderCount,
        uint256 cancelledOrderCount
    );

    // Pool functions
    function getCurrentPrice(address currency0, address currency1, uint24 fee, int24 tickSpacing) 
        external view returns (uint256 price);
        
    function checkPool(address currency0, address currency1, uint24 fee) 
        external view returns (bool exists, bytes32 poolId);
        
    function getPoolInfo(address currency0, address currency1, uint24 fee) 
        external view returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity);
}
