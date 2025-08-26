// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LimitOrderBatch} from "../src/LimitOrderBatch.sol";

/**
 * @title InitializePool  
 * @notice Initialize pool with deployed hook contract
 */
contract InitializePool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    
    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPrivateKey);
        
        IPoolManager poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        
        // Get deployed contract addresses (these should be set from environment or passed in)
        address limitOrderBatchAddress;
        try vm.envAddress("LIMIT_ORDER_BATCH_ADDRESS") returns (address hookAddr) {
            limitOrderBatchAddress = hookAddr;
        } catch {
            revert("LIMIT_ORDER_BATCH_ADDRESS not set. Run DeployHookContract first.");
        }
        
        address usdcAddress;
        try vm.envAddress("USDC_ADDRESS") returns (address addr) {
            usdcAddress = addr;
        } catch {
            revert("USDC_ADDRESS not set. Run SetupAnvilWallets first.");
        }
        
        address wethAddress;
        try vm.envAddress("WETH_ADDRESS") returns (address addr) {
            wethAddress = addr;
        } catch {
            revert("WETH_ADDRESS not set. Run SetupAnvilWallets first.");
        }
        
        console2.log("=== Initializing Pool with Hook ===");
        console2.log("Deployer:", deployer);
        console2.log("Pool Manager:", address(poolManager));
        console2.log("Hook Contract:", limitOrderBatchAddress);
        console2.log("USDC:", usdcAddress);
        console2.log("WETH:", wethAddress);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Create pool key with hook
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(usdcAddress < wethAddress ? usdcAddress : wethAddress),
            currency1: Currency.wrap(usdcAddress < wethAddress ? wethAddress : usdcAddress),
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(limitOrderBatchAddress)
        });
        
        // Check if pool already exists
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(poolManager, poolId);
        
        if (sqrtPriceX96 != 0) {
            console2.log("Pool already initialized!");
            console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
            vm.stopBroadcast();
            return;
        }
        
        // Initialize pool at 1:1 price ratio (approximately)
        uint160 startingPrice = TickMath.getSqrtPriceAtTick(0); // 1:1 ratio
        
        console2.log("Initializing pool...");
        console2.log("Starting price (sqrtPriceX96):", startingPrice);
        
        poolManager.initialize(poolKey, startingPrice);
        
        // Verify initialization
        (sqrtPriceX96, tick, protocolFee, lpFee) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtPriceX96 != 0, "Pool initialization failed");
        
        vm.stopBroadcast();
        
        console2.log(unicode"✅ Pool initialized successfully!");
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console2.log("Current price (sqrtPriceX96):", sqrtPriceX96);
        console2.log("");
        console2.log("POOL_ID=", vm.toString(PoolId.unwrap(poolId)));
    }
}
