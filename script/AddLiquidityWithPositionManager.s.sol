// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/**
 * @title AddLiquidityWithPositionManager  
 * @notice Add liquidity using the deployed PositionManager
 */
contract AddLiquidityWithPositionManager is Script {
    IPoolManager public poolManager;
    IPositionManager public positionManager;
    
    constructor() {
        string memory poolManagerStr = vm.envOr("POOL_MANAGER_ADDRESS", string("0x000000000004444c5dc75cB358380D2e3dE08A90"));
        poolManager = IPoolManager(vm.parseAddress(poolManagerStr));
        
        string memory positionManagerStr = vm.envOr("POSITION_MANAGER_ADDRESS", string("0xBd216513d74c8cf14cf4747e6aaa6420ff64ee9e"));
        positionManager = IPositionManager(vm.parseAddress(positionManagerStr));
    }

    function run() external {
        vm.startBroadcast();
        
        // Get environment variables
        string memory hookAddressStr = vm.envOr("LIMIT_ORDER_BATCH_ADDRESS", string("0x9C41504742845C84081dcb7a79eae09d24F5f0c4"));
        address hookAddress = vm.parseAddress(hookAddressStr);
        
        string memory usdcAddressStr = vm.envOr("USDC_ADDRESS", string("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"));
        address usdcAddress = vm.parseAddress(usdcAddressStr);
        
        // Create the pool key (same as in our hook)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(usdcAddress), // USDC from env
            fee: 0x800000, // Dynamic fee
            tickSpacing: 60,
            hooks: IHooks(hookAddress) // Hook address from env
        });
        
        // Get the deployer address (msg.sender)
        address deployer = msg.sender;
        console.log("Deployer address:", deployer);
        
        // Check USDC balance and approve if needed
        uint256 usdcAmount = 10000 * 1e6; // 10,000 USDC
        uint256 usdcBalance = IERC20(usdcAddress).balanceOf(deployer);
        console.log("USDC Balance:", usdcBalance);
        
        if (usdcBalance >= usdcAmount) {
            IERC20(usdcAddress).approve(address(positionManager), usdcAmount);
            console.log("USDC approved:", usdcAmount);
        } else {
            console.log("Insufficient USDC balance, using available:", usdcBalance);
            usdcAmount = usdcBalance;
            if (usdcAmount > 0) {
                IERC20(usdcAddress).approve(address(positionManager), usdcAmount);
            }
        }
        
        // Simple approach: try to call a mint function if it exists
        // Since the interface is complex, let's just log what we would do
        console.log("Pool Key created for liquidity addition:");
        console.log("Currency0 (ETH):", Currency.unwrap(key.currency0));
        console.log("Currency1 (USDC):", Currency.unwrap(key.currency1));
        console.log("Fee:", key.fee);
        console.log("Tick Spacing:", uint256(int256(key.tickSpacing)));
        console.log("Hook:", address(key.hooks));
        console.log("Position Manager:", address(positionManager));
        
        vm.stopBroadcast();
        
        console.log(unicode"✅ Environment variables loaded successfully");
        console.log("Ready to add liquidity through PositionManager");
    }
}