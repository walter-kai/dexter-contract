// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        // Mint 1 billion USDC (6 decimals) to the deployer
        _mint(msg.sender, 1_000_000_000 * 10**6);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DeployMockUSDC is Script {
    function run() external {
        vm.startBroadcast();
        
        MockUSDC mockUSDC = new MockUSDC();
        
        console.log("Mock USDC deployed at:", address(mockUSDC));
        console.log("Total supply:", mockUSDC.totalSupply());
        console.log("Deployer balance:", mockUSDC.balanceOf(msg.sender));
        
        vm.stopBroadcast();
    }
}