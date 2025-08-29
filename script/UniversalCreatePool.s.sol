// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract UniversalCreatePool is Script {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    
    function run() external {
        vm.startBroadcast();
        
        // Read environment variables for pool parameters
        address token0 = vm.envAddress("POOL_TOKEN0");
        address token1 = vm.envAddress("POOL_TOKEN1");
        uint24 fee = uint24(vm.envUint("POOL_FEE"));
        string memory token0Name = vm.envString("POOL_TOKEN0_NAME");
        string memory token1Name = vm.envString("POOL_TOKEN1_NAME");
        
        // Read hook address if available, default to zero address
        address hookAddress;
        try vm.envAddress("LIMIT_ORDER_BATCH_ADDRESS") returns (address hook) {
            hookAddress = hook;
            console2.log("Using hook address:", hookAddress);
        } catch {
            hookAddress = address(0);
            console2.log("No hook address provided, using zero address");
        }
        
        console2.log("=== Creating Universal Pool ===");
        console2.log("Token 0:", token0Name, "->", token0);
        console2.log("Token 1:", token1Name, "->", token1);
        console2.log("Fee:", fee);
        
        // Ensure proper ordering (lower address first)
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
            console2.log("Tokens reordered for proper address ordering");
        }
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        
        // Calculate initial price (1:1 ratio at tick 0)
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // sqrt(1) * 2^96
        
        try POOL_MANAGER.initialize(key, sqrtPriceX96) {
            PoolId poolId = key.toId();
            console2.log("Pool created successfully!");
            console2.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
            console2.log("Final Token 0:", token0);
            console2.log("Final Token 1:", token1);
        } catch Error(string memory reason) {
            console2.log("Pool creation failed:", reason);
            // Don't revert - pool might already exist
            if (keccak256(bytes(reason)) == keccak256(bytes("PoolAlreadyInitialized()"))) {
                console2.log("Pool already exists - this is expected");
            }
        } catch (bytes memory) {
            console2.log("Pool creation failed with low-level error - pool might already exist");
        }
        
        vm.stopBroadcast();
    }
}
