// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract GasPriceFeesHook is BaseHook {
    using LPFeeLibrary for uint24;

    // Events
    event GasPriceTracked(uint128 gasPrice, uint128 averageGasPrice, uint104 count);

    // Keeping track of the moving average gas price
    uint128 public movingAverageGasPrice;
    // How many times has the moving average been updated?
    // Needed as the denominator to update it the next time based on the moving average formula
    uint104 public movingAverageGasPriceCount;

    // The default base fees we will charge
    uint24 public constant BASE_FEE = 5000; // denominated in pips (one-hundredth bps) 0.5%

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        // Don't call updateMovingAverage() in constructor to keep initial count at 0
    }

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `LPFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = getFee();
        // If we wanted to generally update LP fee for a longer-term than per-swap
        // poolManager.updateDynamicLPFee(key, fee);
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeWithFlag
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);

        // If no transactions have been tracked yet, return base fee
        if (movingAverageGasPriceCount == 0) {
            return BASE_FEE;
        }

        // if gasPrice > movingAverageGasPrice * 1.1, then half the fees
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEE / 2;
        }

        // if gasPrice < movingAverageGasPrice * 0.9, then double the fees
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEE * 2;
        }

        return BASE_FEE;
    }

    // Update our moving average gas price
    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);

        // New Average = ((Old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) /
            (movingAverageGasPriceCount + 1);

        movingAverageGasPriceCount++;
        
        // Emit event for tracking
        emit GasPriceTracked(gasPrice, movingAverageGasPrice, movingAverageGasPriceCount);
    }

    // Public getter functions for testing
    function getGasPriceStats() external view returns (uint128 currentGasPrice, uint128 averageGasPrice, uint104 count) {
        return (uint128(tx.gasprice), movingAverageGasPrice, movingAverageGasPriceCount);
    }

    function getBaseFee() external pure returns (uint24) {
        return BASE_FEE;
    }

    // Test helper functions to expose internal functionality
    function testBeforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external view returns (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) {
        return _beforeSwap(sender, key, params, hookData);
    }

    function testAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4 selector, int128 hookDelta) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    // Helper function to get current fee without affecting state
    function getCurrentFee() external view returns (uint24) {
        return getFee();
    }
}
