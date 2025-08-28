// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {ILimitOrder} from "../interfaces/ILimitOrder.sol";
import {PriceLibrary} from "../libraries/PriceLibrary.sol";

/**
 * @title PoolManagerBase
 * @notice Abstract base contract for pool management functionality
 */
abstract contract PoolManagerBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    /// @notice The pool manager instance
    IPoolManager public immutable poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    /**
     * @notice Get current price for a currency pair
     * @param currency0 First currency
     * @param currency1 Second currency
     * @param fee Fee tier
     * @param tickSpacing Tick spacing
     * @return price Current price
     */
    function getCurrentPrice(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing
    ) external view returns (uint256 price) {
        // Try pool without hook first (most common case)
        PoolKey memory keyWithoutHook = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, keyWithoutHook.toId());
        
        if (sqrtPriceX96 > 0) {
            return PriceLibrary.sqrtPriceToPrice(sqrtPriceX96);
        }
        
        // Try pool with hook
        PoolKey memory keyWithHook = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: _getHookAddress()
        });
        
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, keyWithHook.toId());
        
        if (sqrtPriceX96 > 0) {
            return PriceLibrary.sqrtPriceToPrice(sqrtPriceX96);
        }
        
        return 0;
    }

    /**
     * @notice Check if a pool exists
     * @param currency0 First currency
     * @param currency1 Second currency
     * @param fee Fee tier
     * @return exists Whether the pool exists
     * @return poolId The pool ID
     */
    function checkPool(
        address currency0,
        address currency1,
        uint24 fee
    ) external view returns (bool exists, bytes32 poolId) {
        // Try pool without hook first (most common case)
        PoolKey memory keyWithoutHook = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: PriceLibrary.getTickSpacingForFee(fee),
            hooks: IHooks(address(0))
        });
        
        PoolId id = keyWithoutHook.toId();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, id);
        
        if (sqrtPriceX96 > 0) {
            return (true, PoolId.unwrap(id));
        }
        
        // Try pool with hook
        PoolKey memory keyWithHook = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: PriceLibrary.getTickSpacingForFee(fee),
            hooks: _getHookAddress()
        });
        
        id = keyWithHook.toId();
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, id);
        
        return (sqrtPriceX96 > 0, PoolId.unwrap(id));
    }

    /**
     * @notice Get pool information
     * @param currency0 First currency
     * @param currency1 Second currency
     * @param fee Fee tier
     * @return sqrtPriceX96 Current sqrt price
     * @return tick Current tick
     * @return liquidity Current liquidity
     */
    function getPoolInfo(
        address currency0,
        address currency1,
        uint24 fee
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity) {
        // Try pool without hook first (most common case)
        PoolKey memory keyWithoutHook = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: PriceLibrary.getTickSpacingForFee(fee),
            hooks: IHooks(address(0))
        });
        
        (uint160 sqrtPrice, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, keyWithoutHook.toId());
        if (sqrtPrice > 0) {
            liquidity = poolManager.getLiquidity(keyWithoutHook.toId());
            return (sqrtPrice, currentTick, liquidity);
        }
        
        // Try pool with hook
        PoolKey memory keyWithHook = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: PriceLibrary.getTickSpacingForFee(fee),
            hooks: _getHookAddress()
        });
        
        (sqrtPrice, currentTick,,) = StateLibrary.getSlot0(poolManager, keyWithHook.toId());
        liquidity = poolManager.getLiquidity(keyWithHook.toId());
        
        return (sqrtPrice, currentTick, liquidity);
    }

    /**
     * @notice Check if order is executable based on pool and price
     * @param order The order to check
     * @return executable Whether the order is executable
     */
    function _checkPoolAndPrice(ILimitOrder.Order storage order) internal view returns (bool executable) {
        // Try both with and without hook to find the actual pool
        PoolKey memory keyWithHook = PoolKey({
            currency0: Currency.wrap(order.currency0),
            currency1: Currency.wrap(order.currency1),
            fee: order.fee,
            tickSpacing: order.tickSpacing,
            hooks: IHooks(order.hook)
        });
        
        PoolKey memory keyWithoutHook = PoolKey({
            currency0: Currency.wrap(order.currency0),
            currency1: Currency.wrap(order.currency1),
            fee: order.fee,
            tickSpacing: order.tickSpacing,
            hooks: IHooks(address(0))
        });
        
        // Check pool with hook first
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, keyWithHook.toId());
        if (sqrtPriceX96 > 0) {
            return PriceLibrary.isPriceExecutable(sqrtPriceX96, order.limitPrice, order.zeroForOne, order.slippageTolerance);
        }
        
        // Check pool without hook (most common case for existing pools)
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, keyWithoutHook.toId());
        if (sqrtPriceX96 > 0) {
            return PriceLibrary.isPriceExecutable(sqrtPriceX96, order.limitPrice, order.zeroForOne, order.slippageTolerance);
        }
        
        return false;
    }

    /**
     * @notice Get the hook address (to be implemented by derived contracts)
     * @return The hook address
     */
    function _getHookAddress() internal view virtual returns (IHooks);
}
