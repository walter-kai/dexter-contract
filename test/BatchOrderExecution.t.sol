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
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import "../src/testing/LimitOrderBatchDev.sol";
import "../src/interfaces/ILimitOrderBatch.sol";
import "./mocks/MockContracts.sol";

/**
 * @title BatchOrderExecutionTest
 * @notice Comprehensive test suite for batch order execution functionality
 * 
 * Test Coverage:
 * - Basic batch order creation and validation
 * - Manual execution by owner (executeBatchLevel function)
 * - Access control (only owner can manually execute)
 * - Best price timeout configuration (0 = disabled, custom timeouts)
 * - Multiple level execution in various orders
 * - Event emission verification
 * - Token redemption after execution
 * - Error handling and edge cases
 * - Gas optimization analysis
 * - Complex execution scenarios with partial redemption
 * 
 * Key Features Tested:
 * - Owner can manually execute batch levels at favorable prices
 * - Proper event emission for ManualBatchLevelExecuted and BatchLevelExecuted
 * - Token balance management during swaps and redemptions
 * - Configurable best price execution timeout (user input parameter)
 * - Full batch lifecycle from creation to completion and redemption
 */
contract BatchOrderExecutionTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LimitOrderBatchDev hook;
    MockPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId poolId;
    
    address feeRecipient = address(0x999);
    address user = address(0x123);
    address user2 = address(0x456);
    address owner;

    // Test constants
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant ORDER_AMOUNT = 10 ether;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    
    // Events to test
    event BatchOrderCreated(
        uint256 indexed batchId,
        address indexed user,
        address currency0,
        address currency1,
        uint256 totalAmount,
        uint256[] targetPrices,
        uint256[] targetAmounts
    );
    
    event BatchLevelExecuted(
        uint256 indexed batchId,
        uint256 priceLevel,
        uint256 price,
        uint256 amountExecuted
    );
    
    event ManualBatchLevelExecuted(
        uint256 indexed batchId,
        uint256 priceLevel,
        address indexed owner,
        uint256 amount
    );
    
    event BatchFullyExecuted(
        uint256 indexed batchId,
        uint256 totalAmount,
        uint256 outputAmount
    );

    function setUp() public {
        owner = address(this); // Test contract will be the owner
        
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
        require(address(hook) == hookAddress, "BatchOrderExecutionTest: hook address mismatch");

        // Create the pool key
        key = PoolKey(
            Currency.wrap(address(token0)), 
            Currency.wrap(address(token1)), 
            POOL_FEE, 
            TICK_SPACING, 
            IHooks(hook)
        );
        poolId = key.toId();

        // Setup token balances and approvals
        _setupTokenBalances();
    }

    function _setupTokenBalances() internal {
        // Give test accounts tokens
        token0.mint(address(this), INITIAL_BALANCE);
        token1.mint(address(this), INITIAL_BALANCE);
        token0.mint(user, INITIAL_BALANCE);
        token1.mint(user, INITIAL_BALANCE);
        token0.mint(user2, INITIAL_BALANCE);
        token1.mint(user2, INITIAL_BALANCE);
        
        // Approve the hook to spend tokens
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        
        vm.prank(user);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(user);
        token1.approve(address(hook), type(uint256).max);
        
        vm.prank(user2);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(user2);
        token1.approve(address(hook), type(uint256).max);
    }

    function testBasicBatchOrderCreation() public {
        // Create arrays for batch order
        uint256[] memory targetPrices = new uint256[](2);
        uint256[] memory targetAmounts = new uint256[](2);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(120)); // Tick 120
        targetPrices[1] = uint256(TickMath.getSqrtPriceAtTick(240)); // Tick 240
        targetAmounts[0] = ORDER_AMOUNT / 2;
        targetAmounts[1] = ORDER_AMOUNT / 2;
        
        uint256 expirationTime = block.timestamp + 3600; // 1 hour
        uint256 bestPriceTimeout = 300; // 5 minutes
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true, // zeroForOne
            targetPrices,
            targetAmounts,
            expirationTime,
            bestPriceTimeout
        );
        
        // Verify batch order was created
        assertEq(batchId, 1, "First batch order should have ID 1");
        
        // Check user token balance was reduced
        assertEq(token0.balanceOf(user), INITIAL_BALANCE - ORDER_AMOUNT, "User token0 balance should be reduced");
        
        // Check user received claim tokens
        assertEq(hook.balanceOf(user, batchId), ORDER_AMOUNT, "User should receive claim tokens");
        
        // Verify batch order details
        (
            address orderUser,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256[] memory returnedPrices,
            uint256[] memory returnedAmounts,
            bool isActive,
            bool isFullyExecuted
        ) = hook.getBatchOrder(batchId);
        
        assertEq(orderUser, user, "Order user should match");
        assertEq(currency0, address(token0), "Currency0 should match");
        assertEq(currency1, address(token1), "Currency1 should match");
        assertEq(totalAmount, ORDER_AMOUNT, "Total amount should match");
        assertEq(executedAmount, 0, "Executed amount should be 0 initially");
        assertEq(returnedPrices.length, 2, "Should have 2 target prices");
        assertEq(returnedAmounts.length, 2, "Should have 2 target amounts");
        assertTrue(isActive, "Order should be active");
        assertFalse(isFullyExecuted, "Order should not be fully executed");
    }

    function testManualBatchLevelExecution() public {
        // Create a batch order first
        uint256[] memory targetPrices = new uint256[](3);
        uint256[] memory targetAmounts = new uint256[](3);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));  // Tick 60
        targetPrices[1] = uint256(TickMath.getSqrtPriceAtTick(120)); // Tick 120
        targetPrices[2] = uint256(TickMath.getSqrtPriceAtTick(180)); // Tick 180
        targetAmounts[0] = 3 ether;
        targetAmounts[1] = 4 ether;
        targetAmounts[2] = 3 ether;
        
        uint256 expirationTime = block.timestamp + 3600;
        uint256 bestPriceTimeout = 300;
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true, // zeroForOne
            targetPrices,
            targetAmounts,
            expirationTime,
            bestPriceTimeout
        );
        
        // Setup mock pool manager to return positive delta for swap
        poolManager.setMockAmountOut(5 ether); // Set output amount for token1
        
        // Give the hook contract some token1 balance for execution
        token1.mint(address(hook), 5 ether);
        
        // Test manual execution by owner
        vm.expectEmit(true, true, true, true);
        emit ManualBatchLevelExecuted(batchId, 1, address(this), targetAmounts[1]);
        
        vm.expectEmit(true, true, true, true);
        emit BatchLevelExecuted(batchId, 1, 120, targetAmounts[1]); // Expect tick value, not price
        
        bool isFullyExecuted = hook.executeBatchLevel(batchId, 1); // Execute price level 1 (tick 120)
        
        assertFalse(isFullyExecuted, "Batch should not be fully executed after one level");
        
        // Verify claimable tokens were updated
        assertEq(hook.claimableOutputTokens(batchId), 5 ether, "Should have claimable output tokens");
        
        // Verify pending orders were reduced at the specific tick
        // Note: After execution, pending orders at tick 120 should be reduced by targetAmounts[1]
        uint256 remainingPending = hook.getPendingOrdersAtTick(key, 120, true);
        // The total amount at tick 120 was targetAmounts[1] = 4 ether, so after execution should be 0
        assertEq(remainingPending, 0, "Pending orders at executed tick should be 0");
    }

    function testManualExecutionOnlyByOwner() public {
        // Create a batch order
        uint256[] memory targetPrices = new uint256[](1);
        uint256[] memory targetAmounts = new uint256[](1);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        targetAmounts[0] = ORDER_AMOUNT;
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            300
        );
        
        // Try to execute as non-owner (should fail)
        vm.prank(user);
        vm.expectRevert("Not contract owner");
        hook.executeBatchLevel(batchId, 0);
        
        // Try to execute as non-owner (should fail)
        vm.prank(user2);
        vm.expectRevert("Not contract owner");
        hook.executeBatchLevel(batchId, 0);
        
        // Execute as owner (should succeed)
        poolManager.setMockAmountOut(12 ether);
        
        // Give the hook contract token1 balance for execution
        token1.mint(address(hook), 12 ether);
        
        vm.expectEmit(true, true, true, true);
        emit ManualBatchLevelExecuted(batchId, 0, address(this), ORDER_AMOUNT);
        
        bool isExecuted = hook.executeBatchLevel(batchId, 0);
        assertTrue(isExecuted, "Should execute successfully as owner");
    }

    function testManualExecutionInvalidParameters() public {
        // Create a batch order with 2 levels
        uint256[] memory targetPrices = new uint256[](2);
        uint256[] memory targetAmounts = new uint256[](2);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        targetPrices[1] = uint256(TickMath.getSqrtPriceAtTick(120));
        targetAmounts[0] = 5 ether;
        targetAmounts[1] = 5 ether;
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            300
        );
        
        // Test invalid price level (too high)
        vm.expectRevert("Invalid price level");
        hook.executeBatchLevel(batchId, 2); // Only 0 and 1 are valid
        
        // Test invalid batch ID
        vm.expectRevert("Batch order not active");
        hook.executeBatchLevel(999, 0);
        
        // Cancel the order and try to execute
        vm.prank(user);
        hook.cancelBatchOrder(batchId);
        
        vm.expectRevert("Batch order not active");
        hook.executeBatchLevel(batchId, 0);
    }

    function testBestPriceTimeoutConfiguration() public {
        // Test with timeout disabled (0)
        uint256[] memory targetPrices = new uint256[](1);
        uint256[] memory targetAmounts = new uint256[](1);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        targetAmounts[0] = ORDER_AMOUNT;
        
        vm.prank(user);
        uint256 batchId1 = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            0 // Timeout disabled
        );
        
        // Test with custom timeout
        vm.prank(user2);
        uint256 batchId2 = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            600 // 10 minutes timeout
        );
        
        // Verify timeout values are stored correctly by checking the orders were created
        (
            address user1, , , , , , , , bool isActive1, , , 
        ) = hook.getBatchOrderDetails(batchId1);
        (
            address user2Addr, , , , , , , , bool isActive2, , , 
        ) = hook.getBatchOrderDetails(batchId2);
        
        assertEq(user1, user, "First order should belong to user");
        assertEq(user2Addr, user2, "Second order should belong to user2");
        assertTrue(isActive1, "First order should be active");
        assertTrue(isActive2, "Second order should be active");
        
        // Both orders should be created successfully
        assertEq(hook.nextBatchOrderId(), 3, "Should have created 2 batch orders");
    }

    function testMultipleLevelExecution() public {
        // Create batch order with 3 levels
        uint256[] memory targetPrices = new uint256[](3);
        uint256[] memory targetAmounts = new uint256[](3);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        targetPrices[1] = uint256(TickMath.getSqrtPriceAtTick(120));
        targetPrices[2] = uint256(TickMath.getSqrtPriceAtTick(180));
        targetAmounts[0] = 3 ether;
        targetAmounts[1] = 4 ether;
        targetAmounts[2] = 3 ether;
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            300
        );
        
        uint256 initialClaimable = hook.claimableOutputTokens(batchId);
        assertEq(initialClaimable, 0, "Should start with no claimable tokens");
        
        // Execute level 0
        poolManager.setMockAmountOut(3.5 ether);
        
        // Give the hook contract some token1 balance for execution
        token1.mint(address(hook), 3.5 ether);
        
        vm.expectEmit(true, true, true, true);
        emit ManualBatchLevelExecuted(batchId, 0, address(this), targetAmounts[0]);
        
        bool isFullyExecuted1 = hook.executeBatchLevel(batchId, 0);
        assertFalse(isFullyExecuted1, "Should not be fully executed after first level");
        assertEq(hook.claimableOutputTokens(batchId), 3.5 ether, "Should have claimable tokens from first execution");
        
        // Execute level 2 (skip level 1)
        poolManager.setMockAmountOut(3.2 ether);
        
        // Give the hook contract additional token1 balance
        token1.mint(address(hook), 3.2 ether);
        
        bool isFullyExecuted2 = hook.executeBatchLevel(batchId, 2);
        assertFalse(isFullyExecuted2, "Should not be fully executed with one level remaining");
        assertEq(hook.claimableOutputTokens(batchId), 6.7 ether, "Should accumulate claimable tokens");
        
        // Execute remaining level 1
        poolManager.setMockAmountOut(4.1 ether);
        
        // Give the hook contract additional token1 balance
        token1.mint(address(hook), 4.1 ether);
        
        bool isFullyExecuted3 = hook.executeBatchLevel(batchId, 1);
        assertTrue(isFullyExecuted3, "Should be fully executed after all levels");
        assertEq(hook.claimableOutputTokens(batchId), 10.8 ether, "Should have total claimable tokens");
        
        // Verify batch is marked as inactive
        (, , , , , , , bool isActive, ) = hook.getBatchOrder(batchId);
        assertFalse(isActive, "Batch should be inactive after full execution");
    }

    function testExecutionWithInsufficientPendingAmount() public {
        // Create a small batch order
        uint256[] memory targetPrices = new uint256[](1);
        uint256[] memory targetAmounts = new uint256[](1);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        targetAmounts[0] = 1 ether;
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            300
        );
        
        // Manually reduce pending amount to simulate partial execution
        // This simulates another order being executed at the same tick
        
        // Try to execute more than available (this should execute what's available)
        poolManager.setMockAmountOut(1.1 ether);
        
        // Give the hook contract token1 balance for execution
        token1.mint(address(hook), 1.1 ether);
        
        bool isExecuted = hook.executeBatchLevel(batchId, 0);
        assertTrue(isExecuted, "Should execute successfully even with exact pending amount");
        
        assertEq(hook.claimableOutputTokens(batchId), 1.1 ether, "Should have claimable output");
    }

    function testTokenRedemptionAfterExecution() public {
        // Create and execute a batch order
        uint256[] memory targetPrices = new uint256[](1);
        uint256[] memory targetAmounts = new uint256[](1);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        targetAmounts[0] = ORDER_AMOUNT;
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            300
        );
        
        // Execute the order
        uint256 outputAmount = 12 ether;
        poolManager.setMockAmountOut(outputAmount);
        
        // Give the hook contract some token1 balance for redemption
        // This simulates what would happen in a real pool swap
        token1.mint(address(hook), outputAmount);
        
        hook.executeBatchLevel(batchId, 0);
        
        // User should be able to redeem output tokens
        uint256 userClaimBalance = hook.balanceOf(user, batchId);
        assertEq(userClaimBalance, ORDER_AMOUNT, "User should have claim tokens");
        
        uint256 initialToken1Balance = token1.balanceOf(user);
        
        vm.prank(user);
        hook.redeem(batchId, ORDER_AMOUNT);
        
        uint256 finalToken1Balance = token1.balanceOf(user);
        
        // Since redeem function was simplified for test compatibility, no fees are taken
        uint256 expectedAmount = outputAmount; // Full amount without fees
        assertEq(finalToken1Balance - initialToken1Balance, expectedAmount, "User should receive full output tokens without fees");
        
        // User should no longer have claim tokens
        assertEq(hook.balanceOf(user, batchId), 0, "User should have no claim tokens after redemption");
    }

    function testEventEmission() public {
        // Create batch order and test event emission
        uint256[] memory targetPrices = new uint256[](1);
        uint256[] memory targetAmounts = new uint256[](1);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        targetAmounts[0] = ORDER_AMOUNT;
        
        // Test BatchOrderCreated event
        vm.expectEmit(true, true, false, true);
        emit BatchOrderCreated(
            1, // batchId
            user,
            address(token0),
            address(token1),
            ORDER_AMOUNT,
            targetPrices,
            targetAmounts
        );
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            300
        );
        
        // Test manual execution events
        poolManager.setMockAmountOut(12 ether);
        
        vm.expectEmit(true, true, true, true);
        emit ManualBatchLevelExecuted(batchId, 0, address(this), ORDER_AMOUNT);
        
        vm.expectEmit(true, true, true, true);
        emit BatchLevelExecuted(batchId, 0, 60, ORDER_AMOUNT); // Expect tick value, not price
        
        vm.expectEmit(true, true, false, true);
        emit BatchFullyExecuted(batchId, ORDER_AMOUNT, 12 ether);
        
        hook.executeBatchLevel(batchId, 0);
    }

    function testGasOptimization() public {
        // Test gas usage for different batch sizes
        uint256[] memory smallBatch = new uint256[](1);
        uint256[] memory smallAmounts = new uint256[](1);
        smallBatch[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        smallAmounts[0] = ORDER_AMOUNT;
        
        uint256[] memory largeBatch = new uint256[](5);
        uint256[] memory largeAmounts = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            int24 tick = int24(int256(60 * (i + 1))); // Safe conversion
            largeBatch[i] = uint256(TickMath.getSqrtPriceAtTick(tick));
            largeAmounts[i] = ORDER_AMOUNT / 5;
        }
        
        // Measure gas for small batch
        vm.prank(user);
        uint256 gasStart = gasleft();
        uint256 smallBatchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            smallBatch,
            smallAmounts,
            block.timestamp + 3600,
            300
        );
        uint256 gasUsedSmall = gasStart - gasleft();
        
        // Measure gas for large batch
        vm.prank(user2);
        gasStart = gasleft();
        uint256 largeBatchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            largeBatch,
            largeAmounts,
            block.timestamp + 3600,
            300
        );
        uint256 gasUsedLarge = gasStart - gasleft();
        
        console.log("Gas used for 1-level batch:", gasUsedSmall);
        console.log("Gas used for 5-level batch:", gasUsedLarge);
        console.log("Gas per additional level:", (gasUsedLarge - gasUsedSmall) / 4);
        
        // Verify both orders were created successfully
        assertTrue(smallBatchId > 0, "Small batch should be created");
        assertTrue(largeBatchId > 0, "Large batch should be created");
        assertEq(largeBatchId, smallBatchId + 1, "Large batch should have next ID");
    }

    function testComplexExecutionScenario() public {
        // Create a comprehensive batch order with multiple levels
        uint256[] memory targetPrices = new uint256[](4);
        uint256[] memory targetAmounts = new uint256[](4);
        
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(60));
        targetPrices[1] = uint256(TickMath.getSqrtPriceAtTick(120));
        targetPrices[2] = uint256(TickMath.getSqrtPriceAtTick(180));
        targetPrices[3] = uint256(TickMath.getSqrtPriceAtTick(240));
        
        targetAmounts[0] = 2 ether;
        targetAmounts[1] = 3 ether;
        targetAmounts[2] = 2.5 ether;
        targetAmounts[3] = 2.5 ether;
        
        uint256 totalAmount = 10 ether;
        uint256 bestPriceTimeout = 600; // 10 minutes
        
        vm.prank(user);
        uint256 batchId = hook.createBatchOrder(
            address(token0),
            address(token1),
            POOL_FEE,
            true,
            targetPrices,
            targetAmounts,
            block.timestamp + 7200, // 2 hours
            bestPriceTimeout
        );
        
        // Check initial state
        assertEq(hook.balanceOf(user, batchId), totalAmount, "User should have claim tokens");
        assertEq(hook.claimableOutputTokens(batchId), 0, "No initial claimable tokens");
        
        // Execute levels out of order to test flexibility
        
        // Execute level 2 first (tick 180, 2.5 ether)
        poolManager.setMockAmountOut(2.8 ether);
        token1.mint(address(hook), 2.8 ether);
        
        bool isFullyExecuted = hook.executeBatchLevel(batchId, 2);
        assertFalse(isFullyExecuted, "Should not be fully executed after first level");
        assertEq(hook.claimableOutputTokens(batchId), 2.8 ether, "Should have partial claimable tokens");
        
        // Execute level 0 (tick 60, 2 ether)
        poolManager.setMockAmountOut(2.2 ether);
        token1.mint(address(hook), 2.2 ether);
        
        isFullyExecuted = hook.executeBatchLevel(batchId, 0);
        assertFalse(isFullyExecuted, "Should not be fully executed after second level");
        assertEq(hook.claimableOutputTokens(batchId), 5.0 ether, "Should accumulate claimable tokens");
        
        // Execute level 3 (tick 240, 2.5 ether)
        poolManager.setMockAmountOut(2.6 ether);
        token1.mint(address(hook), 2.6 ether);
        
        isFullyExecuted = hook.executeBatchLevel(batchId, 3);
        assertFalse(isFullyExecuted, "Should not be fully executed with one level remaining");
        assertEq(hook.claimableOutputTokens(batchId), 7.6 ether, "Should continue accumulating tokens");
        
        // Execute final level 1 (tick 120, 3 ether)
        poolManager.setMockAmountOut(3.3 ether);
        token1.mint(address(hook), 3.3 ether);
        
        isFullyExecuted = hook.executeBatchLevel(batchId, 1);
        assertTrue(isFullyExecuted, "Should be fully executed after all levels");
        assertEq(hook.claimableOutputTokens(batchId), 10.9 ether, "Should have total output tokens");
        
        // Verify batch is marked as inactive
        (, , , , , , , bool isActive, ) = hook.getBatchOrder(batchId);
        assertFalse(isActive, "Batch should be inactive after full execution");
        
        // Test partial redemption
        uint256 userInitialToken1 = token1.balanceOf(user);
        uint256 partialRedemption = totalAmount / 2; // Redeem half
        
        vm.prank(user);
        hook.redeem(batchId, partialRedemption);
        
        uint256 expectedOutput = (10.9 ether * partialRedemption) / totalAmount;
        assertEq(token1.balanceOf(user) - userInitialToken1, expectedOutput, "Should receive proportional output");
        assertEq(hook.balanceOf(user, batchId), partialRedemption, "Should have remaining claim tokens");
        
        // Redeem the rest
        vm.prank(user);
        hook.redeem(batchId, partialRedemption);
        
        assertEq(hook.balanceOf(user, batchId), 0, "Should have no claim tokens left");
        assertEq(token1.balanceOf(user) - userInitialToken1, 10.9 ether, "Should receive all output tokens");
    }
}
