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
 * @title DirectLiquidityAdd
 * @notice Directly add liquidity to pool without hook complications
 */
contract DirectLiquidityAdd is Script, IUnlockCallback {
    IPoolManager public poolManager;
    
    constructor() {
        poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    }

    function run() external {
        vm.startBroadcast();
        
        // Create the pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // USDC
            fee: 0x800000, // Dynamic fee
            tickSpacing: 60,
            hooks: IHooks(0xE995F426a0694a368dE6d6e6fFdc0FcD960Ff0c4) // New hook
        });
        
        // Add liquidity in a wide range around current price
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600, // Wide range below current price
            tickUpper: 600,  // Wide range above current price
            liquidityDelta: 1000000000000000000, // 1 ETH worth of liquidity
            salt: bytes32(0)
        });
        
        console.log("Adding liquidity directly to PoolManager...");
        
        // Add liquidity through unlock callback
        poolManager.unlock(abi.encode(key, params));
        
        vm.stopBroadcast();
        
        console.log(unicode"✅ Liquidity added directly");
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");
        
        (PoolKey memory key, ModifyLiquidityParams memory params) = abi.decode(data, (PoolKey, ModifyLiquidityParams));
        
        console.log("In direct unlock callback");
        
        // Add liquidity
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
        
        console.log("Delta amount0:", uint256(int256(delta.amount0())));
        console.log("Delta amount1:", uint256(int256(delta.amount1())));
        
        // Settle deltas
        if (delta.amount0() > 0) {
            console.log("Settling ETH amount:", uint256(int256(delta.amount0())));
            poolManager.settle{value: uint256(int256(delta.amount0()))}();
        }
        if (delta.amount1() > 0) {
            console.log("Settling USDC amount:", uint256(int256(delta.amount1())));
            IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint256(int256(delta.amount1())));
            poolManager.settle();
        }
        
        return abi.encode(delta);
    }
    
    receive() external payable {}
}
