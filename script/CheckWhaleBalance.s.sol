// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CheckWhaleBalance
 * @notice Check if whale address has USDC on the fork
 */
contract CheckWhaleBalance is Script {
    
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDC_WHALE = 0x5414d89a8bF7E99d732BC52f3e6A3Ef461c0C078;
    
    function run() external view {
        console2.log("=== Checking Whale Balance on Fork ===");
        
        IERC20 usdc = IERC20(USDC);
        
        uint256 whaleBalance = usdc.balanceOf(USDC_WHALE);
        console2.log("Whale address:", USDC_WHALE);
        console2.log("Whale USDC balance:", whaleBalance / 10**6, "USDC");
        console2.log("Whale raw balance:", whaleBalance);
        
        if (whaleBalance == 0) {
            console2.log(unicode"❌ Whale has no USDC - fork may not be working properly");
        } else {
            console2.log(unicode"✅ Whale has USDC - fork is working");
        }
    }
}
