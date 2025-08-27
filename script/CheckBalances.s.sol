// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CheckBalances
 * @notice Check USDC/WETH balances for Anvil accounts
 */
contract CheckBalances is Script {
    
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    address constant ACCOUNT1 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    
    function run() external view {
        console2.log("=== Checking Account Balances ===");
        
        IERC20 usdc = IERC20(USDC);
        IERC20 weth = IERC20(WETH);
        
        console2.log("Account:", ACCOUNT1);
        console2.log("ETH balance:", ACCOUNT1.balance / 10**18, "ETH");
        console2.log("USDC balance:", usdc.balanceOf(ACCOUNT1) / 10**6, "USDC");
        console2.log("WETH balance:", weth.balanceOf(ACCOUNT1) / 10**18, "WETH");
        
        console2.log("");
        console2.log("Raw values:");
        console2.log("USDC raw:", usdc.balanceOf(ACCOUNT1));
        console2.log("WETH raw:", weth.balanceOf(ACCOUNT1));
    }
}
