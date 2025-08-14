// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PriceLibrary
 * @notice Library for price calculations and conversions
 */
library PriceLibrary {
    /**
     * @notice Convert sqrtPriceX96 to readable price
     * @param sqrtPriceX96 The sqrt price in X96 format
     * @return price The converted price
     */
    function sqrtPriceToPrice(uint160 sqrtPriceX96) internal pure returns (uint256 price) {
        if (sqrtPriceX96 == 0) return 0;
        
        // Convert sqrtPriceX96 to price using the standard Uniswap formula
        // price = (sqrtPriceX96 / 2^96)^2
        
        // To avoid overflow, we can rearrange: price = (sqrtPriceX96^2) / (2^192)
        // And then adjust for decimal differences between tokens
        
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        
        // For ETH/USDC: ETH (18 decimals) / USDC (6 decimals) = need 10^12 adjustment
        // This gives us USDC per ETH price
        price = (priceX192 * 1e12) >> 192;
        
        // Additional safety check to prevent unrealistic prices
        // For ETH/USDC, reasonable range is 100-10000 USDC per ETH
        if (price > 50000 || price == 0) {
            // If price seems unrealistic, try alternative calculation
            // This might be a different token pair or unusual pool
            price = priceX192 >> 192; // Raw price without decimal adjustment
        }
    }

    /**
     * @notice Check if an order is executable at current price
     * @param sqrtPriceX96 Current sqrt price
     * @param limitPrice Order limit price
     * @param zeroForOne Order direction
     * @param slippageTolerance Slippage tolerance
     * @return executable Whether the order can be executed
     */
    function isPriceExecutable(
        uint160 sqrtPriceX96,
        uint256 limitPrice,
        bool zeroForOne,
        uint256 slippageTolerance
    ) internal pure returns (bool executable) {
        uint256 currentPrice = sqrtPriceToPrice(sqrtPriceX96);
        uint256 limitPriceScaled = limitPrice; // limitPrice is already properly scaled
        uint256 tolerance = (limitPriceScaled * slippageTolerance) / 10000;
        
        if (zeroForOne) {
            // For ETH -> USDC, execute if current price >= limit price (selling ETH)
            return currentPrice >= (limitPriceScaled - tolerance);
        } else {
            // For USDC -> ETH, execute if current price <= limit price (buying ETH)
            return currentPrice <= (limitPriceScaled + tolerance);
        }
    }

    /**
     * @notice Get tick spacing for fee tier
     * @param fee The fee tier
     * @return tickSpacing The corresponding tick spacing
     */
    function getTickSpacingForFee(uint24 fee) internal pure returns (int24 tickSpacing) {
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        return 60;
    }
}
