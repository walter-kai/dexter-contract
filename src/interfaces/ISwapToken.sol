// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";

/**
 * @title ISwapToken
 * @notice Interface for SwapToken contract - Updated for SwapToken compatibility
 */
interface ISwapToken {
    function swap(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external payable returns (BalanceDelta);
}
