// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SetupAnvilWallets
 * @notice Fund Anvil accounts with USDC from whale address
 */
contract SetupAnvilWallets is Script {
    
    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDC_WHALE = 0x5414d89a8bF7E99d732BC52f3e6A3Ef461c0C078; // ~48M USDC
    
    // Default Anvil accounts
    address[10] anvilAccounts = [
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
        0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
        0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
        0x90F79bf6EB2c4f870365E785982E1f101E93b906,
        0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,
        0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,
        0x976EA74026E726554dB657fA54763abd0C3a0aa9,
        0x14dC79964da2C08b23698B3D3cc7Ca32193d9955,
        0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f,
        0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
    ];

    function run() external {
        console2.log("=== Setting up Anvil Wallets with USDC ===");
        
        IERC20 usdc = IERC20(USDC);
        uint256 fundAmount = 1_000_000 * 10**6; // 1M USDC per account
        
        // Check whale balance
        uint256 whaleBalance = usdc.balanceOf(USDC_WHALE);
        console2.log("USDC Whale balance:", whaleBalance / 10**6, "USDC");
        
        uint256 totalNeeded = fundAmount * anvilAccounts.length;
        require(whaleBalance >= totalNeeded, "Insufficient whale balance");
        
        // Start whale impersonation and fund accounts
        vm.startPrank(USDC_WHALE);
        
        for (uint256 i = 0; i < anvilAccounts.length; i++) {
            address account = anvilAccounts[i];
            
            bool success = usdc.transfer(account, fundAmount);
            require(success, string(abi.encodePacked("Transfer failed for account ", vm.toString(i))));
            
            uint256 balance = usdc.balanceOf(account);
            console2.log("Account funded with USDC balance:", balance / 10**6);
        }
        
        vm.stopPrank();
        
        console2.log(unicode"✅ All 10 Anvil accounts funded with 1M USDC each");
    }
}