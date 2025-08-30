// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/**
 * @title InitializePool
 * @notice Initialize the pool with a reasonable price
 */
contract InitializePool is Script {
    IPoolManager public poolManager;
    
    constructor() {
        string memory poolManagerStr = vm.envOr("POOL_MANAGER_ADDRESS", string("0x000000000004444c5dc75cB358380D2e3dE08A90"));
        poolManager = IPoolManager(vm.parseAddress(poolManagerStr));
    }

    function run() external {
        vm.startBroadcast();
        
        // Get environment variables
        string memory hookAddressStr = vm.envOr("LIMIT_ORDER_BATCH_ADDRESS", string("0x9C41504742845C84081dcb7a79eae09d24F5f0c4"));
        address hookAddress = vm.parseAddress(hookAddressStr);
        
        // Create the pool key (same as in our hook)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            fee: 0x800000, // Dynamic fee
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        
        // Initialize pool at around $2000 per ETH
        // sqrt(2000 * 10^6) * 2^96 = ~3.55e21
        // Using TickMath to get proper sqrtPriceX96 for ~$2000/ETH
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(201120); // Approximately $2000 per ETH
        
        // Initialize the pool
        poolManager.initialize(key, sqrtPriceX96);
        
        vm.stopBroadcast();
        
        console.log(unicode"✅ Pool initialized with price around $2000/ETH");
        console.log("sqrtPriceX96:", sqrtPriceX96);
    }
}
