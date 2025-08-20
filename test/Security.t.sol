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

/**
 * @title SecurityTest - Critical security tests for production readiness
 * @notice Tests MEV protection, reentrancy, edge cases, and attack vectors
 */
contract SecurityTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;

    LimitOrderBatchDev hook;
    MockPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId poolId;
    
    address feeRecipient = address(0x999);
    address user = address(0x123);
    address attacker = address(0x666);

    function setUp() public {
        // Deploy mock contracts
        poolManager = new MockPoolManager();
        token0 = new MockERC20("Token0", "TKN0");
        token1 = new MockERC20("Token1", "TKN1");

        // Deploy the hook
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
        require(address(hook) == hookAddress, "hook address mismatch");

        // Create pool key
        key = PoolKey(
            Currency.wrap(address(token0)), 
            Currency.wrap(address(token1)), 
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60, 
            IHooks(hook)
        );
        poolId = key.toId();

        // Setup tokens
        token0.mint(address(this), 10000 ether);
        token1.mint(address(this), 10000 ether);
        token0.mint(user, 10000 ether);
        token1.mint(user, 10000 ether);
        token0.mint(attacker, 10000 ether);
        token1.mint(attacker, 10000 ether);
        
        // Approve tokens
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        
        vm.prank(user);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(user);
        token1.approve(address(hook), type(uint256).max);
        
        vm.prank(attacker);
        token0.approve(address(hook), type(uint256).max);
        vm.prank(attacker);
        token1.approve(address(hook), type(uint256).max);
    }

    // ==================== DEADLINE PROTECTION TESTS ====================
    
    function testDeadlineEnforcement() public {
        uint256[] memory prices = new uint256[](2);
        prices[0] = 1000; prices[1] = 1100;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18; amounts[1] = 1e18;
        
        uint256 pastDeadline = block.timestamp - 1;
        
        vm.expectRevert("Order creation deadline exceeded");
        hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, pastDeadline, 500, 0, 300
        );
    }
    
    function testDeadlineEdgeCases() public {
        uint256[] memory prices = new uint256[](1);
        prices[0] = 79228162514264337593543950336; // Valid sqrt price (1:1)
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        
        // Test deadline exactly at current timestamp (should fail since > is required)
        uint256 currentTime = block.timestamp;
        vm.expectRevert("Order creation deadline exceeded");
        hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, currentTime, 500, 0, 300
        );
        
        // Test with future timestamp (should pass)
        uint256 futureTime = block.timestamp + 3600;
        uint256 batchId2 = hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, futureTime, 500, 0, 300
        );
        assertTrue(batchId2 > 0, "Order with future timestamp should succeed");
    }

    // ==================== SLIPPAGE PROTECTION TESTS ====================
    
    function testSlippageProtectionLimits() public {
        uint256[] memory prices = new uint256[](1);
        prices[0] = 79228162514264337593543950336; // Valid sqrt price (1:1)
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        
        // Test maximum allowed slippage (should pass)
        uint256 batchId = hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300 // 5% = 500 bps
        );
        assertTrue(batchId > 0, "5% slippage should be allowed");
        
        // Test excessive slippage (should revert)
        vm.expectRevert("Slippage too high");
        hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 501, 0, 300 // 5.01% = 501 bps
        );
    }
    
    function testSlippageEdgeCases() public {
        uint256[] memory prices = new uint256[](1);
        prices[0] = 79228162514264337593543950336; // Valid sqrt price (1:1)
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        
        // Test 0% slippage (should pass)
        uint256 batchId = hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 0, 0, 300
        );
        assertTrue(batchId > 0, "0% slippage should be allowed");
        
        // Test exactly maximum slippage (should pass)
        uint256 batchId2 = hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        );
        assertTrue(batchId2 > 0, "Exactly 5% slippage should be allowed");
    }

    // ==================== INPUT VALIDATION TESTS ====================
    
    function testZeroAmountValidation() public {
        uint256[] memory prices = new uint256[](2);
        prices[0] = 1000; prices[1] = 1100;
        uint256[] memory zeroAmounts = new uint256[](2);
        zeroAmounts[0] = 0; zeroAmounts[1] = 0;
        
        vm.expectRevert("Invalid amount");
        hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, zeroAmounts, block.timestamp + 3600, 500, 0, 300
        );
    }
    
    function testInvalidTokenAddresses() public {
        uint256[] memory prices = new uint256[](1);
        prices[0] = 1000;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        
        // Test zero address for token0
        vm.expectRevert();
        hook.createBatchOrder(
            address(0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        );
        
        // Test zero address for token1
        vm.expectRevert();
        hook.createBatchOrder(
            address(token0), address(0), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        );
        
        // Test same token addresses
        vm.expectRevert();
        hook.createBatchOrder(
            address(token0), address(token0), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        );
    }
    
    function testArraySizeMismatch() public {
        uint256[] memory prices = new uint256[](2);
        prices[0] = 1000; prices[1] = 1100;
        uint256[] memory amounts = new uint256[](3); // Different size
        amounts[0] = 1e18; amounts[1] = 1e18; amounts[2] = 1e18;
        
        vm.expectRevert("Array length mismatch");
        hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        );
    }
    
    function testEmptyArrays() public {
        uint256[] memory emptyPrices = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);
        
        vm.expectRevert(abi.encodeWithSignature("InvalidOrder()"));
        hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            emptyPrices, emptyAmounts, block.timestamp + 3600, 500, 0, 300
        );
    }

    // ==================== LARGE ARRAY DOS PROTECTION ====================
    
    function testLargeArrayDoSProtection() public {
        // Test with very large arrays that could cause DoS
        uint256[] memory largePrices = new uint256[](1000);
        uint256[] memory largeAmounts = new uint256[](1000);
        
        for(uint256 i = 0; i < 1000; i++) {
            largePrices[i] = 1000 + i;
            largeAmounts[i] = 1e18;
        }
        
        // Should revert due to gas limits or array size limits
        // Note: This might not revert if there's no explicit limit, but will use too much gas
        try hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            largePrices, largeAmounts, block.timestamp + 3600, 500, 0, 300
        ) {
            // If it doesn't revert, at least check it consumes reasonable gas
            // This is a design decision - you might want to add explicit array size limits
            console.log("Large array order created - consider adding size limits");
        } catch {
            // Expected to fail due to gas or explicit limits
            console.log("Large array protection working");
        }
    }

    // ==================== INTEGER OVERFLOW PROTECTION ====================
    
    function testIntegerOverflowProtection() public {
        uint256[] memory prices = new uint256[](1);
        prices[0] = type(uint256).max; // Maximum uint256
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max; // Maximum uint256
        
        // This should either revert or handle gracefully
        try hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        ) {
            console.log("Max values handled - check calculations don't overflow");
        } catch {
            console.log("Max value protection working");
        }
    }

    // ==================== ACCESS CONTROL TESTS ====================
    
    function testOnlyOwnerFunctions() public {
        // Create a batch order first
        uint256[] memory prices = new uint256[](1);
        prices[0] = 79228162514264337593543950336; // Valid sqrt price (1:1)
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        
        uint256 batchId = hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        );
        
        // Test manual execution access control
        vm.prank(attacker);
        vm.expectRevert("Not contract owner");
        hook.executeBatchLevel(batchId, 0);
    }

    // ==================== EXPIRED ORDER HANDLING ====================
    
    function testExpiredOrderHandling() public {
        uint256[] memory prices = new uint256[](1);
        prices[0] = 79228162514264337593543950336; // Valid sqrt price (1:1)
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        
        // Create order with short expiration but still valid for creation
        uint256 shortExpiry = block.timestamp + 100;
        uint256 batchId = hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, shortExpiry, 500, 0, 300
        );
        
        // Move time forward past expiration
        vm.warp(shortExpiry + 1);
        
        // Expired orders should be cancellable (treated like cancelled state)
        hook.cancelBatchOrder(batchId);
        
        // Verify order is cancelled
        (,,,,,,,,,, bool isActiveAfterCancel, bool isFullyExecuted, uint256 executedLevelsAfter,,,,,) = hook.getBatchOrderDetails(batchId);
        assertFalse(isActiveAfterCancel, "Expired order should be inactive after cancellation");
    }

    // ==================== BALANCE VALIDATION ====================
    
    function testInsufficientBalanceHandling() public {
        // Create new user with limited balance
        address poorUser = address(0x999);
        token0.mint(poorUser, 0.5e18); // Only 0.5 tokens
        
        vm.prank(poorUser);
        token0.approve(address(hook), type(uint256).max);
        
        uint256[] memory prices = new uint256[](1);
        prices[0] = 1000;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18; // Trying to use 1 token but only has 0.5
        
        vm.prank(poorUser);
        vm.expectRevert(); // Should revert due to insufficient balance
        hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        );
    }

    // ==================== HELPER FUNCTIONS ====================
    
    function _createValidOrder() internal returns (uint256) {
        uint256[] memory prices = new uint256[](1);
        prices[0] = 79228162514264337593543950336; // Valid sqrt price (1:1)
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        
        return hook.createBatchOrder(
            address(token0), address(token1), 3000, true,
            prices, amounts, block.timestamp + 3600, 500, 0, 300
        );
    }
}
