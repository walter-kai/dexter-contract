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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import "../src/testing/LimitOrderBatchDev.sol";
import "./mocks/MockContracts.sol";

contract PoolInitializationTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;

    // Event declarations - must match the ones in LimitOrderBatch.sol
    event PoolInitializedWithHook(
        PoolId indexed poolId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        uint256 blockNumber
    );

    LimitOrderBatchDev hook;
    MockPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    
    address feeRecipient = address(0x999);
    address user = address(0x123);

    // Test fee tiers
    uint24 constant FEE_LOW = 100;      // 0.01%
    uint24 constant FEE_MID = 500;      // 0.05%
    uint24 constant FEE_HIGH = 3000;    // 0.3%
    uint24 constant FEE_VERY_HIGH = 10000; // 1%

    function setUp() public {
        // Deploy mock contracts
        poolManager = new MockPoolManager();
        token0 = new MockERC20("Token0", "TKN0");
        token1 = new MockERC20("Token1", "TKN1");
        token2 = new MockERC20("Token2", "TKN2");

        // Deploy the hook to an address with the correct flags for pool initialization
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
        require(address(hook) == hookAddress, "PoolInitializationTest: hook address mismatch");

        // Give test accounts some tokens
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token2.mint(address(this), 1000 ether);
        token0.mint(user, 1000 ether);
        token1.mint(user, 1000 ether);
        token2.mint(user, 1000 ether);

        // Approve hook to spend tokens
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token2.approve(address(hook), type(uint256).max);
        
        vm.startPrank(user);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token2.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function testBasicPoolInitialization() public {
        // Test manual pool initialization
        address currency0 = address(token0);
        address currency1 = address(token1);
        uint24 fee = FEE_MID;

        // Pool should not exist initially
        bool exists = hook.isPoolInitialized(currency0, currency1, fee);
        assertFalse(exists, "Pool should not exist initially");

        // Expect the PoolInitializedWithHook event to be emitted
        vm.expectEmit(true, true, true, true);
        
        // Calculate expected pool ID for the event
        PoolKey memory expectedKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000, // Dynamic fee flag
            tickSpacing: 10, // For 0.05% fee
            hooks: IHooks(address(hook))
        });
        PoolId expectedPoolId = expectedKey.toId();
        
        emit PoolInitializedWithHook(
            expectedPoolId,
            currency0,
            currency1,
            fee,
            10, // tick spacing
            block.number
        );

        // Initialize pool manually
        PoolKey memory key = hook.initializePoolWithHook(currency0, currency1, fee);

        // Verify pool was initialized
        exists = hook.isPoolInitialized(currency0, currency1, fee);
        assertTrue(exists, "Pool should exist after initialization");

        // Verify pool key has correct properties
        assertEq(Currency.unwrap(key.currency0), currency0, "Currency0 should match");
        assertEq(Currency.unwrap(key.currency1), currency1, "Currency1 should match");
        assertEq(key.fee, fee | 0x800000, "Fee should have dynamic flag");
        assertEq(key.tickSpacing, 10, "Tick spacing should be 10 for 0.05% fee");
        assertEq(address(key.hooks), address(hook), "Hook should be our contract");

        // Verify pool tracking state
        PoolId poolId = key.toId();
        assertTrue(hook.poolInitialized(poolId), "Pool should be marked as initialized");
        assertEq(hook.poolInitializationBlock(poolId), block.number, "Initialization block should be current block");

        console.log("Pool initialized successfully:");
        console.log("  Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("  Currency0:", currency0);
        console.log("  Currency1:", currency1);
        console.log("  Fee:", key.fee);
        console.log("  Tick Spacing:", uint256(int256(key.tickSpacing)));
    }

    function testAutoPoolInitializationDuringOrderCreation() public {
        // Test automatic pool initialization when creating batch order
        address currency0 = address(token0);
        address currency1 = address(token1);
        uint24 fee = FEE_HIGH;

        // Pool should not exist initially
        bool exists = hook.isPoolInitialized(currency0, currency1, fee);
        assertFalse(exists, "Pool should not exist initially");

        // Expect the PoolInitializedWithHook event to be emitted during order creation
        vm.expectEmit(true, true, true, true);
        
        // Calculate expected pool ID for the event
        PoolKey memory expectedKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000, // Dynamic fee flag
            tickSpacing: 60, // For 0.3% fee
            hooks: IHooks(address(hook))
        });
        PoolId expectedPoolId = expectedKey.toId();
        
        emit PoolInitializedWithHook(
            expectedPoolId,
            currency0,
            currency1,
            fee,
            60, // tick spacing
            block.number
        );

        // Create batch order (should auto-initialize pool)
        int24 tick = 120;
        uint256 amount = 5e18;
        bool zeroForOne = true;

        uint256 batchOrderId = hook.createBatchOrder(
            expectedKey,
            tick,
            amount,
            zeroForOne
        );

        // Verify order was created
        assertTrue(batchOrderId > 0, "Batch order should be created");

        // Verify pool was auto-initialized
        exists = hook.isPoolInitialized(currency0, currency1, fee);
        assertTrue(exists, "Pool should exist after order creation");

        // Verify pool tracking state
        PoolId poolId = expectedKey.toId();
        assertTrue(hook.poolInitialized(poolId), "Pool should be marked as initialized");
        assertEq(hook.poolInitializationBlock(poolId), block.number, "Initialization block should be current block");

        console.log("Pool auto-initialized during order creation:");
        console.log("  Batch Order ID:", batchOrderId);
        console.log("  Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("  Currency0:", currency0);
        console.log("  Currency1:", currency1);
        console.log("  Fee:", expectedKey.fee);
    }

    function testMultiplePoolInitialization() public {
        // Test initializing multiple pools with different parameters
        address currency0 = address(token0);
        address currency1 = address(token1);
        address currency2 = address(token2);

        uint24[] memory fees = new uint24[](4);
        fees[0] = FEE_LOW;
        fees[1] = FEE_MID;
        fees[2] = FEE_HIGH;
        fees[3] = FEE_VERY_HIGH;

        // Initialize pools for token0/token1 with different fees
        for (uint256 i = 0; i < fees.length; i++) {
            bool existsBefore = hook.isPoolInitialized(currency0, currency1, fees[i]);
            assertFalse(existsBefore, "Pool should not exist before initialization");

            hook.initializePoolWithHook(currency0, currency1, fees[i]);

            bool existsAfter = hook.isPoolInitialized(currency0, currency1, fees[i]);
            assertTrue(existsAfter, "Pool should exist after initialization");
        }

        // Initialize pools for token0/token2
        hook.initializePoolWithHook(currency0, currency2, FEE_MID);
        assertTrue(hook.isPoolInitialized(currency0, currency2, FEE_MID), "Token0/Token2 pool should exist");

        // Initialize pools for token1/token2
        hook.initializePoolWithHook(currency1, currency2, FEE_HIGH);
        assertTrue(hook.isPoolInitialized(currency1, currency2, FEE_HIGH), "Token1/Token2 pool should exist");

        console.log("Successfully initialized multiple pools:");
        console.log("  Token0/Token1 pools:", fees.length);
        console.log("  Token0/Token2 pools: 1");
        console.log("  Token1/Token2 pools: 1");
        console.log("  Total pools: 6");
    }

    function testDuplicatePoolInitialization() public {
        // Test that initializing the same pool twice doesn't cause issues
        address currency0 = address(token0);
        address currency1 = address(token1);
        uint24 fee = FEE_MID;

        // Initialize pool first time
        PoolKey memory key1 = hook.initializePoolWithHook(currency0, currency1, fee);
        PoolId poolId1 = key1.toId();
        uint256 initBlock1 = hook.poolInitializationBlock(poolId1);

        // Initialize same pool second time
        PoolKey memory key2 = hook.initializePoolWithHook(currency0, currency1, fee);
        PoolId poolId2 = key2.toId();
        uint256 initBlock2 = hook.poolInitializationBlock(poolId2);

        // Verify they're the same pool
        assertEq(PoolId.unwrap(poolId1), PoolId.unwrap(poolId2), "Pool IDs should be the same");
        assertEq(initBlock1, initBlock2, "Initialization block should not change");

        // Verify pool properties are the same
        assertEq(Currency.unwrap(key1.currency0), Currency.unwrap(key2.currency0), "Currency0 should match");
        assertEq(Currency.unwrap(key1.currency1), Currency.unwrap(key2.currency1), "Currency1 should match");
        assertEq(key1.fee, key2.fee, "Fees should match");
        assertEq(key1.tickSpacing, key2.tickSpacing, "Tick spacing should match");

        console.log("Duplicate initialization handled correctly:");
        console.log("  Both calls returned same pool ID");
        console.log("  Initialization block unchanged");
    }

    function testDynamicFeeEnforcement() public {
        // Test that all initialized pools have dynamic fee flag
        address currency0 = address(token0);
        address currency1 = address(token1);

        uint24[] memory baseFees = new uint24[](4);
        baseFees[0] = FEE_LOW;      // 100
        baseFees[1] = FEE_MID;      // 500  
        baseFees[2] = FEE_HIGH;     // 3000
        baseFees[3] = FEE_VERY_HIGH; // 10000

        for (uint256 i = 0; i < baseFees.length; i++) {
            PoolKey memory key = hook.initializePoolWithHook(currency0, currency1, baseFees[i]);
            
            console.log("Fee tier", baseFees[i], "-> Dynamic fee:", key.fee);
            
            // Verify dynamic fee flag is set (using bit mask check)
            assertEq(key.fee & 0x800000, 0x800000, "Dynamic fee flag should be set");
            assertEq(key.fee & 0x7FFFFF, baseFees[i], "Base fee should be preserved");
        }
    }

    function testTickSpacingMapping() public {
        // Test that tick spacing is correctly mapped for each fee tier
        address currency0 = address(token0);
        address currency1 = address(token1);

        // Test data for fee tiers and expected tick spacing
        uint24[4] memory fees = [FEE_LOW, FEE_MID, FEE_HIGH, FEE_VERY_HIGH];
        int24[4] memory expectedTickSpacing = [int24(1), int24(10), int24(60), int24(200)];

        for (uint256 i = 0; i < fees.length; i++) {
            PoolKey memory key = hook.initializePoolWithHook(currency0, currency1, fees[i]);
            
            assertEq(key.tickSpacing, expectedTickSpacing[i], "Tick spacing should match expected value");
            
            console.log("Fee", fees[i], "-> Tick spacing:", uint256(int256(key.tickSpacing)));
        }
    }

    function testPoolInitializationWithOrders() public {
        // Test that pool initialization works correctly with subsequent order operations
        address currency0 = address(token0);
        address currency1 = address(token1);
        uint24 fee = FEE_MID;

        // Initialize pool
        PoolKey memory key = hook.initializePoolWithHook(currency0, currency1, fee);
        PoolId poolId = key.toId();

        // Create multiple batch orders on the initialized pool
        int24[] memory ticks = new int24[](3);
        ticks[0] = 60;   // Multiple of tick spacing (10)
        ticks[1] = 120;  // Multiple of tick spacing (10)
        ticks[2] = 180;  // Multiple of tick spacing (10)

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        amounts[2] = 3e18;

        uint256[] memory batchIds = new uint256[](3);

        for (uint256 i = 0; i < ticks.length; i++) {
            batchIds[i] = hook.createBatchOrder(key, ticks[i], amounts[i], true);
            assertTrue(batchIds[i] > 0, "Batch order should be created");
            
            // Verify pending orders are tracked
            uint256 pendingAmount = hook.pendingBatchOrders(poolId, ticks[i], true);
            assertEq(pendingAmount, amounts[i], "Pending amount should match order amount");
        }

        console.log("Created orders on initialized pool:");
        for (uint256 i = 0; i < batchIds.length; i++) {
            console.log("Order ID:", batchIds[i]);
            console.log("Amount:", amounts[i]);
            console.log("Tick:", uint256(int256(ticks[i])));
        }
    }

    function testPoolInitializationBlockTracking() public {
        // Test that pool initialization blocks are tracked correctly
        address currency0 = address(token0);
        address currency1 = address(token1);

        // Initialize pools in different blocks
        PoolKey memory key1 = hook.initializePoolWithHook(currency0, currency1, FEE_MID);
        PoolId poolId1 = key1.toId();
        uint256 block1 = hook.poolInitializationBlock(poolId1);
        
        // Advance block
        vm.roll(block.number + 5);
        
        PoolKey memory key2 = hook.initializePoolWithHook(currency0, currency1, FEE_HIGH);
        PoolId poolId2 = key2.toId();
        uint256 block2 = hook.poolInitializationBlock(poolId2);
        
        // Verify different initialization blocks
        assertEq(block1, block.number - 5, "First pool should be initialized in earlier block");
        assertEq(block2, block.number, "Second pool should be initialized in current block");
        assertTrue(block2 > block1, "Second pool should be initialized after first pool");

        console.log("Pool initialization blocks tracked:");
        console.log("  Pool 1 (Fee 500) - Block:", block1);
        console.log("  Pool 2 (Fee 3000) - Block:", block2);
        console.log("  Block difference:", block2 - block1);
    }
}
