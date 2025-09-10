// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/interfaces/IPositionManager.sol";
import {LimitOrderBatch} from "../src/LimitOrderBatch.sol";
import "./mocks/MockContracts.sol";

/**
 * @title SimpleTest
 * @notice Simplified tests that work with mock contracts
 */
contract SimpleTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LimitOrderBatch hook;
    MockPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;
    address feeRecipient = address(0x999);
    address user = address(0x123);

    function setUp() public {
        // Deploy mock contracts
        poolManager = new MockPoolManager();
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        
        // Mock PositionManager for testing
        IPositionManager mockPositionManager = IPositionManager(address(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e));
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(LimitOrderBatch).creationCode,
            abi.encode(address(poolManager), feeRecipient, address(this))
        );
        
        hook = new LimitOrderBatch{salt: salt}(
            IPoolManager(address(poolManager)),
            feeRecipient,
            address(this)
        );
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000 | 0x800000, // Dynamic fee flag
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // Setup user balances and approvals  
        token0.mint(user, 10000 ether);
        token1.mint(user, 10000 ether);
        vm.deal(user, 10 ether);
        
        vm.startPrank(user);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_CanDeployHook() public view {
        assertTrue(address(hook) != address(0));
        assertEq(hook.owner(), address(this));
    }

    function test_HookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.afterSwapReturnDelta);
    }

    function test_CanCreateBasicOrder() public {
        vm.startPrank(user);
        
        uint256[] memory targetPrices = new uint256[](1);
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(-1000));
        
        uint256[] memory targetAmounts = new uint256[](1);
        targetAmounts[0] = 1000 ether;

        uint256 batchId = hook.createBatchOrder{value: 0.01 ether}(
            address(token0),
            address(token1),
            3000,
            true, // zeroForOne
            targetPrices,
            targetAmounts,
            block.timestamp + 3600,
            false // provideLiquidity
        );

        // Verify order creation
        (
            address batchUser,
            ,
            ,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256 claimableAmount,
            bool isActive,
            bool isFullyExecuted,
            ,
            bool zeroForOne,
            ,
        ) = hook.getBatchInfo(batchId);

        assertEq(batchUser, user);
        assertEq(totalAmount, 1000 ether);
        assertEq(executedAmount, 0);
        assertEq(claimableAmount, 0);
        assertTrue(isActive);
        assertFalse(isFullyExecuted);
        assertTrue(zeroForOne);
        
        vm.stopPrank();
    }

    function test_CanCreateMultiLevelOrder() public {
        vm.startPrank(user);
        
        uint256[] memory targetPrices = new uint256[](3);
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(-1000));
        targetPrices[1] = uint256(TickMath.getSqrtPriceAtTick(-2000));
        targetPrices[2] = uint256(TickMath.getSqrtPriceAtTick(-3000));
        
        uint256[] memory targetAmounts = new uint256[](3);
        targetAmounts[0] = 1000 ether;
        targetAmounts[1] = 1500 ether;
        targetAmounts[2] = 2000 ether;

        uint256 batchId = hook.createBatchOrder{value: 0.01 ether}(
            address(token0), address(token1), 3000, true,
            targetPrices, targetAmounts, block.timestamp + 3600, false
        );

        // Verify total amount
        (, , , uint256 totalAmount, , , , , , , , ) = hook.getBatchInfo(batchId);
        assertEq(totalAmount, 4500 ether);
        
        vm.stopPrank();
    }

    function test_CanCancelOrder() public {
        // Create order
        vm.startPrank(user);
        uint256[] memory targetPrices = new uint256[](1);
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(-1000));
        uint256[] memory targetAmounts = new uint256[](1);
        targetAmounts[0] = 1000 ether;

        uint256 batchId = hook.createBatchOrder{value: 0.01 ether}(
            address(token0), address(token1), 3000, true,
            targetPrices, targetAmounts, block.timestamp + 3600, false
        );

        // Settle order
        hook.settleOrder(batchId);

        // Verify cancellation
        (, , , , , , bool isActive, , , , , ) = hook.getBatchInfo(batchId);
        assertFalse(isActive);
        
        vm.stopPrank();
    }

    function test_GasFeeCollection() public {
        // Set a realistic gas price for testing (20 gwei)
        vm.txGasPrice(20 gwei);
        
        uint256 userBalanceBefore = user.balance;
        
        vm.startPrank(user);
        uint256[] memory targetPrices = new uint256[](1);
        targetPrices[0] = uint256(TickMath.getSqrtPriceAtTick(-1000));
        uint256[] memory targetAmounts = new uint256[](1);
        targetAmounts[0] = 1000 ether;

        // Calculate expected gas fee: 150,000 gas * 20 gwei * 120% = 3.6e15 wei
        uint256 expectedGasFee = 150000 * 20 gwei * 120 / 100;
        
        // Send enough ETH to cover gas fee
        uint256 sentValue = 0.1 ether;
        uint256 batchId = hook.createBatchOrder{value: sentValue}(
            address(token0), address(token1), 3000, true,
            targetPrices, targetAmounts, block.timestamp + 3600, false
        );

        uint256 userBalanceAfter = user.balance;
        
        // Verify gas fee was pre-collected
        (uint256 preCollected, , , ) = hook.getGasRefundInfo(batchId);
        assertGt(preCollected, 0, "Pre-collected gas fee should be greater than 0");
        assertEq(preCollected, expectedGasFee, "Pre-collected amount should match expected calculation");
        
        // Verify balance change reflects gas fee collection
        // Note: Only the gas fee is deducted from user balance; the sent value goes to the contract
        uint256 totalDeduction = userBalanceBefore - userBalanceAfter;
        assertEq(totalDeduction, expectedGasFee, "Only gas fee should be deducted from user balance");
        
        vm.stopPrank();
    }

    function test_InvalidInputs() public {
        vm.startPrank(user);
        
        // Test empty arrays
        vm.expectRevert("Invalid arrays");
        hook.createBatchOrder{value: 0.01 ether}(
            address(token0), address(token1), 3000, true,
            new uint256[](0), new uint256[](0),
            block.timestamp + 3600, false
        );

        // Test mismatched array lengths
        vm.expectRevert("Invalid arrays");
        hook.createBatchOrder{value: 0.01 ether}(
            address(token0), address(token1), 3000, true,
            new uint256[](1), new uint256[](2),
            block.timestamp + 3600, false
        );

        vm.stopPrank();
    }

    function test_MaxLevelsOrder() public {
        vm.startPrank(user);
        
        // Test maximum 10 levels
        uint256[] memory targetPrices = new uint256[](10);
        uint256[] memory targetAmounts = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            targetPrices[i] = uint256(TickMath.getSqrtPriceAtTick(int24(-600 * int256(i))));
            targetAmounts[i] = 100 ether;
        }
        
        uint256 batchId = hook.createBatchOrder{value: 0.01 ether}(
            address(token0), address(token1), 3000, true,
            targetPrices, targetAmounts,
            block.timestamp + 3600, false
        );
        
        (, , , uint256 totalAmount, , , , , , , , ) = hook.getBatchInfo(batchId);
        assertEq(totalAmount, 1000 ether);

        // Test too many levels (should fail)
        uint256[] memory tooManyPrices = new uint256[](11);
        uint256[] memory tooManyAmounts = new uint256[](11);
        for (uint256 i = 0; i < 11; i++) {
            tooManyPrices[i] = uint256(TickMath.getSqrtPriceAtTick(int24(-600 * int256(i))));
            tooManyAmounts[i] = 100 ether;
        }
        
        vm.expectRevert("Invalid arrays");
        hook.createBatchOrder{value: 0.01 ether}(
            address(token0), address(token1), 3000, true,
            tooManyPrices, tooManyAmounts,
            block.timestamp + 3600, false
        );

        vm.stopPrank();
    }
}
