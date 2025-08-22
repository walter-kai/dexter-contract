// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import "../src/testing/LimitOrderBatchDev.sol";
import "./mocks/MockContracts.sol";

contract DynamicFeesTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;

    // Event declarations - must match the ones in LimitOrderBatch.sol
    event GasPriceTracked(uint128 gasPrice, uint128 averageGasPrice, uint104 count);

    LimitOrderBatchDev hook;
    MockPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId poolId;
    
    address feeRecipient = address(0x999);
    address user = address(0x123);

    // Test gas prices
    uint128 constant LOW_GAS_PRICE = 10 gwei;
    uint128 constant NORMAL_GAS_PRICE = 30 gwei;
    uint128 constant HIGH_GAS_PRICE = 100 gwei;

    function setUp() public {
        // Deploy mock contracts
        poolManager = new MockPoolManager();
        token0 = new MockERC20("Token0", "TKN0");
        token1 = new MockERC20("Token1", "TKN1");

        // Deploy the hook to an address with the correct flags for dynamic fees
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(LimitOrderBatchDev).creationCode,
            abi.encode(address(poolManager), feeRecipient)
        );
        
        hook = new LimitOrderBatchDev{salt: salt}(IPoolManager(address(poolManager)), feeRecipient);
        require(address(hook) == hookAddress, "DynamicFeesTest: hook address mismatch");

        // Create the pool key with dynamic fees
        key = PoolKey(
            Currency.wrap(address(token0)), 
            Currency.wrap(address(token1)), 
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Use dynamic fee flag
            60, 
            IHooks(hook)
        );
        poolId = key.toId();

        // Give test accounts some tokens
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.mint(user, 1000 ether);
        token1.mint(user, 1000 ether);
        
        // Approve the hook to spend our tokens
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        
        vm.prank(user);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(user);
        token1.approve(address(hook), type(uint256).max);
    }

    function testDynamicFeeBaseline() public {
        // Test the base fee when there's no gas price history
        uint24 baseFee = hook.BASE_FEE();
        
        // Should return the base fee (3000 = 0.3%)
        assertEq(baseFee, 3000, "Base fee should be 3000 (0.3%)");
        
        console.log("Base dynamic fee:", baseFee);
    }

    function testDynamicFeeWithNormalGasPrice() public {
        // Set normal gas price and trigger fee calculation
        vm.txGasPrice(NORMAL_GAS_PRICE);
        
        // Place an order to trigger gas price tracking
        int24 tick = 120;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        uint256 batchOrderId = hook.createBatchOrder(key, tick, amount, zeroForOne);
        assertTrue(batchOrderId > 0, "Batch order should be created");

        // Check the dynamic fee after gas price tracking
        uint24 normalGasFee = hook.BASE_FEE();
        
        // Should still be base fee since it's the first transaction
        assertEq(normalGasFee, 3000, "Fee should be base fee for first transaction");
        
        console.log("Normal gas fee:", normalGasFee);
        console.log("Count:", count);
    }

    function testDynamicFeeWithHighGasPrice() public {
        // First establish a baseline with normal gas price
        vm.txGasPrice(NORMAL_GAS_PRICE);
        
        // Create first order to establish baseline
        hook.createBatchOrder(key, 120, 5e18, true);
        
        // Now use high gas price
        vm.txGasPrice(HIGH_GAS_PRICE);
        
        // Create another order to trigger high gas fee calculation
        hook.createBatchOrder(key, 180, 5e18, true);
        
        // Check the dynamic fee - should be lower when gas price is high
        uint24 highGasFee = hook.BASE_FEE();
        
        // When gas price > 1.1 * average, fee should be halved (1500 = 0.15%)
        assertEq(highGasFee, 1500, "Fee should be halved for high gas price");
        
        // Check gas price stats
        (uint128 currentGasPrice, uint128 averageGasPrice, uint104 count) = hook.getGasPriceStats();
        assertEq(currentGasPrice, HIGH_GAS_PRICE, "Current gas price should be high");
        assertEq(count, 2, "Count should be 2");
        
        // Average should be between normal and high
        assertTrue(averageGasPrice > NORMAL_GAS_PRICE, "Average should be higher than normal");
        assertTrue(averageGasPrice < HIGH_GAS_PRICE, "Average should be lower than current high");
        
        console.log("High gas fee:", highGasFee);
        console.log("Current gas price:", currentGasPrice);
        console.log("Average gas price:", averageGasPrice);
        console.log("Count:", count);
    }

    function testDynamicFeeWithLowGasPrice() public {
        // First establish a baseline with normal gas price
        vm.txGasPrice(NORMAL_GAS_PRICE);
        
        // Create first order to establish baseline
        hook.createBatchOrder(key, 120, 5e18, true);
        
        // Now use low gas price
        vm.txGasPrice(LOW_GAS_PRICE);
        
        // Create another order to trigger low gas fee calculation
        hook.createBatchOrder(key, 240, 5e18, true);
        
        // Check the dynamic fee - should be higher when gas price is low
        uint24 lowGasFee = hook.BASE_FEE();
        
        // When gas price < 0.9 * average, fee should be doubled (6000 = 0.6%)
        assertEq(lowGasFee, 6000, "Fee should be doubled for low gas price");
        
        // Check gas price stats
        (uint128 currentGasPrice, uint128 averageGasPrice, uint104 count) = hook.getGasPriceStats();
        assertEq(currentGasPrice, LOW_GAS_PRICE, "Current gas price should be low");
        assertEq(count, 2, "Count should be 2");
        
        console.log("Low gas fee:", lowGasFee);
        console.log("Current gas price:", currentGasPrice);
        console.log("Average gas price:", averageGasPrice);
        console.log("Count:", count);
    }

    function testDynamicFeeProgression() public {
        uint24[] memory fees = new uint24[](5);
        uint128[] memory gasPrices = new uint128[](5);
        
        // Test progression from low to high gas prices
        uint128[] memory testGasPrices = new uint128[](5);
        testGasPrices[0] = 5 gwei;   // Very low
        testGasPrices[1] = 15 gwei;  // Low
        testGasPrices[2] = 30 gwei;  // Normal
        testGasPrices[3] = 60 gwei;  // High
        testGasPrices[4] = 120 gwei; // Very high
        
        for (uint256 i = 0; i < 5; i++) {
            vm.txGasPrice(testGasPrices[i]);
            
            // Create order to update gas price tracking
            hook.createBatchOrder(key, int24(120 + int24(int256(i * 60))), 1e18, true);
            
            fees[i] = hook.BASE_FEE();
            gasPrices[i] = testGasPrices[i];
            
            console.log("Gas Price:", gasPrices[i]);
            console.log("Fee:", fees[i]);
        }
        
        // Verify fee behavior
        // The exact values depend on the moving average, but we can verify general trends
        assertTrue(fees[4] <= fees[2], "Very high gas should result in lower or equal fee than normal");
        assertTrue(fees[0] >= fees[2], "Very low gas should result in higher or equal fee than normal");
        
        // Final gas price stats
        (uint128 currentGasPrice, uint128 averageGasPrice, uint104 count) = hook.getGasPriceStats();
        assertEq(count, 5, "Should have tracked 5 transactions");
        
        console.log("Final current gas price:", currentGasPrice);
        console.log("Final average gas price:", averageGasPrice);
        console.log("Final count:", count);
    }

    function testBeforeSwapDynamicFeeCalculation() public {
        // First, establish a baseline with normal gas price
        vm.txGasPrice(NORMAL_GAS_PRICE);
        hook.createBatchOrder(key, 120, 5e18, true);
        
        // Now set high gas price for the beforeSwap call
        vm.txGasPrice(HIGH_GAS_PRICE);
        
        // Test beforeSwap hook which should calculate dynamic fee based on current vs average gas price
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        // Mock a beforeSwap call
        // This would typically be called by the pool manager
        (bytes4 selector, , uint24 feeOverride) = hook.testBeforeSwap(
            address(this),
            key,
            params,
            ""
        );
        
        // Verify the selector is correct
        assertEq(selector, hook.beforeSwap.selector, "Should return correct selector");
        
        // Verify the fee override includes the flag
        assertTrue(feeOverride & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "Fee should include override flag");
        
        // Extract the actual fee (remove the flag)
        uint24 actualFee = feeOverride & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        
        // Should be the halved fee for high gas price (HIGH_GAS_PRICE > NORMAL_GAS_PRICE * 1.1)
        // 100 gwei > 30 gwei * 1.1 = 100 > 33, which is true
        assertEq(actualFee, 1500, "BeforeSwap should return halved fee for high gas price");
        
        console.log("BeforeSwap fee override:", feeOverride);
        console.log("Actual fee (without flag):", actualFee);
    }

    function testAfterSwapGasPriceTracking() public {
        uint128 initialGasPrice = 25 gwei;
        vm.txGasPrice(initialGasPrice);
        
        // Get initial gas price stats
        (uint128 currentBefore, uint128 averageBefore, uint104 countBefore) = hook.getGasPriceStats();
        
        // Mock an afterSwap call to trigger gas price tracking
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        // Call afterSwap to trigger gas price update
        (bytes4 selector, int128 hookDelta) = hook.testAfterSwap(
            address(this),
            key,
            params,
            BalanceDelta.wrap(0),
            ""
        );
        
        // Verify the selector is correct
        assertEq(selector, hook.afterSwap.selector, "Should return correct selector");
        assertEq(hookDelta, 0, "Hook delta should be 0");
        
        // Check that gas price was tracked
        (uint128 currentAfter, uint128 averageAfter, uint104 countAfter) = hook.getGasPriceStats();
        
        assertEq(currentAfter, initialGasPrice, "Current gas price should be updated");
        assertEq(countAfter, countBefore + 1, "Count should increment");
        
        if (countBefore == 0) {
            assertEq(averageAfter, initialGasPrice, "Average should equal current for first transaction");
        } else {
            // Average should be updated
            assertTrue(averageAfter > 0, "Average should be positive");
        }
        
        console.log("After swap gas tracking - Current:", currentAfter);
        console.log("Average:", averageAfter);
        console.log("Count:", countAfter);
    }

    function testGasPriceMovingAverage() public {
        // Test the moving average calculation with known values
        uint128[] memory testPrices = new uint128[](4);
        testPrices[0] = 20 gwei;
        testPrices[1] = 30 gwei;
        testPrices[2] = 40 gwei;
        testPrices[3] = 50 gwei;
        
        for (uint256 i = 0; i < 4; i++) {
            vm.txGasPrice(testPrices[i]);
            
            // Create order to trigger gas price tracking
            hook.createBatchOrder(key, int24(120 + int24(int256(i * 60))), 1e18, true);
            
            (uint128 current, uint128 average, uint104 count) = hook.getGasPriceStats();
            
            console.log("Transaction", i + 1);
            console.log("Gas:", current);
            console.log("Average:", average);
            console.log("Count:", count);
            
            // Verify current gas price is correct
            assertEq(current, testPrices[i], "Current gas price should match set price");
            
            // Verify count increments
            assertEq(count, i + 1, "Count should match transaction number");
            
            // For the moving average calculation:
            // newAverage = ((oldAverage * count) + currentPrice) / (count + 1)
            if (i == 0) {
                assertEq(average, testPrices[i], "First average should equal first price");
            } else {
                // The average should be reasonable given the input prices
                assertTrue(average > 0, "Average should be positive");
                assertTrue(average <= 50 gwei, "Average should be reasonable");
            }
        }
        
        // Final average should be between min and max of our test prices
        (, uint128 finalAverage,) = hook.getGasPriceStats();
        assertTrue(finalAverage >= 20 gwei, "Final average should be at least minimum");
        assertTrue(finalAverage <= 50 gwei, "Final average should be at most maximum");
        
        console.log("Final moving average:", finalAverage);
    }

    function testFeeEventsEmission() public {
        // Set up event watching
        vm.recordLogs();
        
        // Set high gas price to trigger fee change
        vm.txGasPrice(HIGH_GAS_PRICE);
        
        // First establish baseline
        hook.createBatchOrder(key, 120, 1e18, true);
        
        // Get logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Look for GasPriceTracked events
        bool foundGasPriceEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            // GasPriceTracked(uint128 gasPrice, uint128 newAverage, uint104 count)
            if (logs[i].topics[0] == keccak256("GasPriceTracked(uint128,uint128,uint104)")) {
                foundGasPriceEvent = true;
                
                // Decode event data
                (uint128 gasPrice, uint128 newAverage, uint104 count) = abi.decode(
                    logs[i].data,
                    (uint128, uint128, uint104)
                );
                
                assertEq(gasPrice, HIGH_GAS_PRICE, "Event should log correct gas price");
                assertEq(newAverage, HIGH_GAS_PRICE, "Event should log correct average for first tx");
                assertEq(count, 1, "Event should log correct count");
                
                console.log("GasPriceTracked event - Gas:", gasPrice);
                console.log("Average:", newAverage);
                console.log("Count:", count);
                break;
            }
        }
        
        assertTrue(foundGasPriceEvent, "Should emit GasPriceTracked event");
    }

    function testDynamicFeeEdgeCases() public {
        // Test with zero gas price (should handle gracefully)
        vm.txGasPrice(0);
        hook.createBatchOrder(key, 120, 1e18, true);
        
        uint24 zeroGasFee = hook.BASE_FEE();
        assertEq(zeroGasFee, 3000, "Should return base fee for zero gas price");
        
        // Test with extremely high gas price
        vm.txGasPrice(1000 gwei);
        hook.createBatchOrder(key, 180, 1e18, true);
        
        uint24 extremeGasFee = hook.BASE_FEE();
        assertEq(extremeGasFee, 1500, "Should return halved fee for extreme gas price");
        
        // Test after many transactions to check moving average stability
        for (uint256 i = 0; i < 10; i++) {
            vm.txGasPrice(30 gwei + uint128(i * 5 gwei)); // Gradually increasing gas prices
            hook.createBatchOrder(key, int24(240 + int24(int256(i * 60))), 1e18, true);
        }
        
        (uint128 finalCurrent, uint128 finalAverage, uint104 finalCount) = hook.getGasPriceStats();
        assertEq(finalCount, 12, "Should have tracked all transactions"); // 2 initial + 10 in loop
        assertTrue(finalAverage > 0, "Final average should be positive");
        
        console.log("After many transactions - Current:", finalCurrent);
        console.log("Average:", finalAverage);
        console.log("Count:", finalCount);
    }

    function testDynamicFeeConsistency() public {
        // Test that the same gas price conditions produce the same fees
        uint128 testGasPrice = 50 gwei;
        
        // Set gas price and create baseline
        vm.txGasPrice(30 gwei);
        hook.createBatchOrder(key, 120, 1e18, true);
        
        // Now test with our target gas price
        vm.txGasPrice(testGasPrice);
        hook.createBatchOrder(key, 180, 1e18, true);
        uint24 fee1 = hook.BASE_FEE();
        
        // Reset to same conditions and test again
        vm.txGasPrice(testGasPrice);
        hook.createBatchOrder(key, 240, 1e18, true);
        uint24 fee2 = hook.BASE_FEE();
        
        // Fees should be consistent for similar gas price conditions
        // (They might not be exactly equal due to moving average, but should be close)
        uint24 feeDiff = fee1 > fee2 ? fee1 - fee2 : fee2 - fee1;
        assertTrue(feeDiff <= 500, "Fees should be relatively consistent for similar conditions");
        
        console.log("Consistency test - Fee1:", fee1);
        console.log("Fee2:", fee2);
        console.log("Difference:", feeDiff);
    }
}
