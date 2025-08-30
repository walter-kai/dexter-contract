// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title AddBasicLiquidity
 * @notice Add basic liquidity to the pool for testing
 */
contract AddBasicLiquidity is Script, IUnlockCallback {
    IPoolManager public poolManager;
    
    constructor() {
        string memory poolManagerStr = vm.envOr("POOL_MANAGER_ADDRESS", string("0x000000000004444c5dc75cB358380D2e3dE08A90"));
        poolManager = IPoolManager(vm.parseAddress(poolManagerStr));
    }

    function run() external {
        vm.startBroadcast();
        
        // Get environment variables
        string memory hookAddressStr = vm.envOr("LIMIT_ORDER_BATCH_ADDRESS", string("0x2E4817F631b1607e3E8857d4BE3a4318deAd30C4"));
        address hookAddress = vm.parseAddress(hookAddressStr);
        
        // Create the pool key (same as in our hook)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            fee: 0x800000, // Dynamic fee
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        
        // Add liquidity in a wide range around current price
        // If pool isn't initialized, this will initialize it at the middle of our range
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: 200000, // Around $1000 ETH
            tickUpper: 210000, // Around $8000 ETH  
            liquidityDelta: 1000000000000000000, // 1 ETH worth of liquidity
            salt: bytes32(0)
        });
        
        // Add liquidity through unlock callback
        poolManager.unlock(abi.encode(key, params));
        
        vm.stopBroadcast();
        
        console.log(unicode"✅ Basic liquidity added to pool");
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory key, ModifyLiquidityParams memory params) = abi.decode(data, (PoolKey, ModifyLiquidityParams));
        
        // Add liquidity
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
        
        console.log("Delta amount0:", uint256(int256(delta.amount0())));
        console.log("Delta amount1:", uint256(int256(delta.amount1())));
        
        // Settle deltas by sending tokens to pool manager
        if (delta.amount0() > 0) {
            // Send ETH to pool manager
            poolManager.settle{value: uint256(int256(delta.amount0()))}();
        }
        if (delta.amount1() > 0) {
            // Send USDC to pool manager
            IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint256(int256(delta.amount1())));
            poolManager.settle();
        }
        
        return abi.encode(delta);
    }
    
    // Receive ETH
    receive() external payable {}
}
