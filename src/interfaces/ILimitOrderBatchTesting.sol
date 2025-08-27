// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/types/BeforeSwapDelta.sol";

/**
 * @title ILimitOrderBatchTesting
 * @notice Interface for testing functions in LimitOrderBatch
 * @dev Defines the testing interface to keep testing code separate from production code
 */
interface ILimitOrderBatchTesting {
    // Debug events for testing
    event DebugTryExecuting(int24 currentTick, int24 lastTick, bool zeroForOne);
    event DebugQueueCheck(int24 currentTick, bool zeroForOne, uint256 inputAmount);

    /**
     * @notice Test function to simulate beforeSwap for testing purposes
     */
    function testBeforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external view returns (bytes4, BeforeSwapDelta, uint24);

    /**
     * @notice Test function to simulate afterSwap for testing purposes
     */
    function testAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);

    /**
     * @notice Test function to set lastTick for testing purposes
     */
    function testSetLastTick(PoolKey calldata key, int24 tick) external;

    /**
     * @notice Test function to manually execute a batch level (for testing only)
     */
    function testExecuteBatchLevel(uint256 batchId, uint256 priceLevel) 
        external 
        returns (bool success);

    /**
     * @notice Check if testing is enabled
     */
    function isTestingEnabled() external view returns (bool);
}
