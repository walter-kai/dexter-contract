// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/**
 * @title SetupAnvilComplete
 * @notice Complete setup script for Anvil fork - funds USDC and initializes pools
 */
contract SetupAnvilComplete is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    
    // Known USDC whale addresses with large balances
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
        console2.log("=== Complete Anvil Setup ===");
        console2.log("USDC Address:", USDC);
        console2.log("WETH Address:", WETH);
        console2.log("PoolManager Address:", POOL_MANAGER);
        console2.log("USDC Whale:", USDC_WHALE);
        console2.log("");

        // Step 1: Fund all accounts with USDC
        fundUSDCAccounts();
        
        // Step 2: Initialize ETH/USDC pools
        initializePools();
        
        // Step 3: Verify everything
        verifySetup();
        
        console2.log("");
        console2.log(unicode"✅ Complete Anvil setup finished!");
        console2.log(unicode"💡 Your accounts now have USDC and pools are initialized for trading");
    }

    function fundUSDCAccounts() internal {
        console2.log("=== Step 1: Funding USDC ===");
        
        IERC20 usdc = IERC20(USDC);
        uint256 fundAmount = 1_000_000 * 10**6; // 1M USDC per account
        
        // Check whale balance
        uint256 whaleBalance = usdc.balanceOf(USDC_WHALE);
        console2.log("Whale USDC balance:");
        console2.log(whaleBalance / 10**6);
        
        uint256 totalNeeded = fundAmount * anvilAccounts.length;
        require(whaleBalance >= totalNeeded, "Insufficient whale balance");
        
        // Start whale impersonation and fund accounts
        vm.startPrank(USDC_WHALE);
        
        for (uint256 i = 0; i < anvilAccounts.length; i++) {
            address account = anvilAccounts[i];
            
            bool success = usdc.transfer(account, fundAmount);
            require(success, string(abi.encodePacked("Transfer failed for account ", vm.toString(i))));
            
            uint256 balance = usdc.balanceOf(account);
            console2.log("Funded account", i + 1);
            console2.log("Balance:");
            console2.log(balance / 10**6);
        }
        
        vm.stopPrank();
        
        console2.log(unicode"✅ All accounts funded with 1M USDC each");
        console2.log("");
    }

    function initializePools() internal {
        console2.log("=== Step 2: Initializing Pools ===");
        
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);
        
        // ETH/USDC pool parameters
        uint24 fee = 3000; // 0.3% fee tier
        int24 tickSpacing = 60; // Standard for 0.3% pools
        
        // Create pool key (ETH < USDC in address order)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),     // WETH is currency0 (lower address)
            currency1: Currency.wrap(USDC),    // USDC is currency1 (higher address)
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0)) // No hooks for basic pool
        });
        
        console2.log("Pool Key:");
        console2.log("  Currency0 (WETH):", Currency.unwrap(key.currency0));
        console2.log("  Currency1 (USDC):", Currency.unwrap(key.currency1));
        console2.log("  Fee:", key.fee);
        console2.log("  Tick Spacing:");
        console2.log(uint256(int256(key.tickSpacing)));
        
        // Check if pool already exists
        PoolId poolId = key.toId();
        (uint160 existingSqrtPrice,,,) = poolManager.getSlot0(poolId);
        
        if (existingSqrtPrice > 0) {
            console2.log(unicode"ℹ️  Pool already initialized");
            console2.log("  Existing sqrt price:");
            console2.log(existingSqrtPrice);
        } else {
            console2.log("Initializing new pool...");
            
            // Calculate initial price: ~1 ETH = 3000 USDC
            // sqrtPriceX96 = sqrt(price) * 2^96
            // For ETH/USDC: sqrt(3000) ≈ 54.77
            // sqrtPriceX96 ≈ 54.77 * 2^96 ≈ 4.34e21
            uint160 sqrtPriceX96 = 4340810979423247851260694721; // ~3000 USDC per ETH
            
            try poolManager.initialize(key, sqrtPriceX96) {
                console2.log(unicode"✅ Pool initialized successfully");
                console2.log("  Initial sqrt price:");
                console2.log(sqrtPriceX96);
            } catch Error(string memory reason) {
                console2.log("Pool initialization failed:");
                console2.log(reason);
            } catch {
                console2.log("Pool initialization failed with unknown error");
            }
        }
        
        console2.log("");
    }

    function verifySetup() internal view {
        console2.log("=== Step 3: Verification ===");
        
        IERC20 usdc = IERC20(USDC);
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);
        
        // Verify USDC balances
        console2.log("USDC Balances:");
        for (uint256 i = 0; i < 3; i++) { // Check first 3 accounts
            address account = anvilAccounts[i];
            uint256 balance = usdc.balanceOf(account);
            console2.log("  Account");
            console2.log(i + 1);
            console2.log("Balance:");
            console2.log(balance / 10**6);
        }
        
        // Verify pool
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        PoolId poolId = key.toId();
        (uint160 sqrtPrice, int24 tick,,) = poolManager.getSlot0(poolId);
        
        console2.log("Pool Status:");
        console2.log("  Pool ID:");
        console2.log(vm.toString(PoolId.unwrap(poolId)));
        console2.log("  Sqrt Price:");
        console2.log(sqrtPrice);
        console2.log("  Current Tick:");
        console2.log(vm.toString(int256(tick)));
        console2.log("  Pool Initialized:");
        console2.log(sqrtPrice > 0 ? "Yes" : "No");
        
        if (sqrtPrice > 0) {
            // Calculate approximate ETH price in USDC
            // price = (sqrtPrice / 2^96)^2 * 10^(decimals1 - decimals0)
            // For WETH(18)/USDC(6): price = (sqrtPrice / 2^96)^2 * 10^(6-18) = (sqrtPrice / 2^96)^2 / 10^12
            console2.log("  Pool is ready for trading!");
        } else {
            console2.log("  Pool needs initialization!");
        }
    }
}
