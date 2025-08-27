// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CheckAccountBalance is Script {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant ANVIL_ACCOUNT1 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    
    function run() external view {
        console2.log("=== Checking Anvil Account Balance ===");
        console2.log("Account:", ANVIL_ACCOUNT1);
        console2.log("USDC Contract:", USDC);
        
        IERC20 usdc = IERC20(USDC);
        uint256 balance = usdc.balanceOf(ANVIL_ACCOUNT1);
        
        console2.log("Raw balance:", balance);
        console2.log("USDC balance:", balance / 10**6, "USDC");
        
        if (balance > 0) {
            console2.log(unicode"✅ Account has USDC!");
        } else {
            console2.log(unicode"❌ Account has no USDC");
        }
    }
}
