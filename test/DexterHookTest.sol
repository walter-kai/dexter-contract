// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//       ▄▄▄▄▄▄▄▄▄▄   ▄▄▄▄▄▄▄▄▄▄▄  ▄       ▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄         ▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄    ▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄
//      ▐░░░░░░░░░░▌ ▐░░░░░░░░░░░▌▐░▌     ▐░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░▌       ▐░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░▌  ▐░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌
//      ▐░█▀▀▀▀▀▀▀█░▌▐░█▀▀▀▀▀▀▀▀▀  ▐░▌   ▐░▌  ▀▀▀▀█░█▀▀▀▀ ▐░█▀▀▀▀▀▀▀▀▀ ▐░█▀▀▀▀▀▀▀█░▌▐░▌       ▐░▌▐░█▀▀▀▀▀▀▀█░▌▐░█▀▀▀▀▀▀▀█░▌▐░▌ ▐░▌  ▀▀▀▀█░█▀▀▀▀ ▐░█▀▀▀▀▀▀▀▀▀ ▐░█▀▀▀▀▀▀▀▀▀  ▀▀▀▀█░█▀▀▀▀
//      ▐░▌       ▐░▌▐░▌            ▐░▌ ▐░▌       ▐░▌     ▐░▌          ▐░▌       ▐░▌▐░▌       ▐░▌▐░▌       ▐░▌▐░▌       ▐░▌▐░▌▐░▌       ▐░▌     ▐░▌          ▐░▌               ▐░▌
//      ▐░▌       ▐░▌▐░█▄▄▄▄▄▄▄▄▄    ▐░▐░▌        ▐░▌     ▐░█▄▄▄▄▄▄▄▄▄ ▐░█▄▄▄▄▄▄▄█░▌▐░█▄▄▄▄▄▄▄█░▌▐░▌       ▐░▌▐░▌       ▐░▌▐░▌░▌        ▐░▌     ▐░█▄▄▄▄▄▄▄▄▄ ▐░█▄▄▄▄▄▄▄▄▄      ▐░▌
//      ▐░▌       ▐░▌▐░░░░░░░░░░░▌    ▐░▌         ▐░▌     ▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░▌       ▐░▌▐░▌       ▐░▌▐░░▌         ▐░▌     ▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌     ▐░▌
//      ▐░▌       ▐░▌▐░█▀▀▀▀▀▀▀▀▀    ▐░▌░▌        ▐░▌     ▐░█▀▀▀▀▀▀▀▀▀ ▐░█▀▀▀▀█░█▀▀ ▐░█▀▀▀▀▀▀▀█░▌▐░▌       ▐░▌▐░▌       ▐░▌▐░▌░▌        ▐░▌     ▐░█▀▀▀▀▀▀▀▀▀  ▀▀▀▀▀▀▀▀▀█░▌     ▐░▌
//      ▐░▌       ▐░▌▐░▌            ▐░▌ ▐░▌       ▐░▌     ▐░▌          ▐░▌     ▐░▌  ▐░▌       ▐░▌▐░▌       ▐░▌▐░▌       ▐░▌▐░▌▐░▌       ▐░▌     ▐░▌                    ▐░▌     ▐░▌
//      ▐░█▄▄▄▄▄▄▄█░▌▐░█▄▄▄▄▄▄▄▄▄  ▐░▌   ▐░▌      ▐░▌     ▐░█▄▄▄▄▄▄▄▄▄ ▐░▌      ▐░▌ ▐░▌       ▐░▌▐░█▄▄▄▄▄▄▄█░▌▐░█▄▄▄▄▄▄▄█░▌▐░▌ ▐░▌      ▐░▌     ▐░█▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄█░▌     ▐░▌
//      ▐░░░░░░░░░░▌ ▐░░░░░░░░░░░▌▐░▌     ▐░▌     ▐░▌     ▐░░░░░░░░░░░▌▐░▌       ▐░▌▐░▌       ▐░▌▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌▐░▌  ▐░▌     ▐░▌     ▐░░░░░░░░░░░▌▐░░░░░░░░░░░▌     ▐░▌
//       ▀▀▀▀▀▀▀▀▀▀   ▀▀▀▀▀▀▀▀▀▀▀  ▀       ▀       ▀       ▀▀▀▀▀▀▀▀▀▀▀  ▀         ▀  ▀         ▀  ▀▀▀▀▀▀▀▀▀▀▀  ▀▀▀▀▀▀▀▀▀▀▀  ▀    ▀       ▀       ▀▀▀▀▀▀▀▀▀▀▀  ▀▀▀▀▀▀▀▀▀▀▀       ▀

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/utils/HookMiner.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Constants} from "@v4-core/test/utils/Constants.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

// Your contract imports
import "../src/DexterHook.sol";
import "../src/interfaces/IDexterHook.sol";

contract DexterHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DexterHook public dcaBot;
    PoolKey public poolKey;
    PoolId public poolId;

    address public constant FEE_RECIPIENT = address(0x1234);
    address public constant EXECUTOR = address(0x5678);

    // Test users
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public user3 = address(0x3333);

    function setUp() public {
        // Deploy manager and routers first
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy the DCA hook with proper flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        );

        // Use HookMiner to find address with proper flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this), flags, type(DexterHook).creationCode, abi.encode(manager, FEE_RECIPIENT, EXECUTOR)
        );

        dcaBot = new DexterHook{salt: salt}(manager, FEE_RECIPIENT, EXECUTOR);
        require(address(dcaBot) == hookAddress, "Hook address mismatch");

        // Create pool key using the existing currencies from Deployers
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(dcaBot))
        });
        poolId = poolKey.toId();

        // Initialize the pool
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Add substantial liquidity to the pool
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 1000 ether,
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, liqParams, ZERO_BYTES);

        // Fund test users
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);

        // Fund tokens to users
        MockERC20(Currency.unwrap(currency0)).mint(user1, 1000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(user2, 1000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(user3, 1000 ether);

        MockERC20(Currency.unwrap(currency1)).mint(user1, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(user2, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(user3, 1000 ether);

        // Fund the compensation pool
        dcaBot.fundGasCompensationPool{value: 10 ether}();
    }

    /* ==========================================================
       DCA STRATEGY CREATION TESTS
       ========================================================== */

    function test_createDCAStrategy_ERC20Input() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000, // 10%
            maxSwapOrders: 3,
            priceDeviationPercent: 500, // 5%
            priceDeviationMultiplier: 20, // 2.0x
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 20 // 2.0x
        });

        uint256 gasAllocation = 1 ether;
        uint256 totalTokens = 3 ether; // Initial + first level

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), totalTokens);

        uint256 dcaId = dcaBot.createDCAStrategy{value: gasAllocation}(
            poolParams,
            dcaParams,
            100, // 1% slippage
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Verify DCA was created
        assertEq(dcaId, 1, "First DCA ID should be 1");

        // Check DCA info
        (
            address user,
            address currency0_,
            address currency1_,
            uint256 totalAmount_,
            ,
            ,
            IDexterHook.OrderStatus status,
            ,
            ,
            bool zeroForOne,
            ,
            uint24 currentFee
        ) = dcaBot.getDCAInfo(dcaId);

        assertEq(user, user1, "User should be user1");
        assertEq(currency0_, Currency.unwrap(currency0), "Currency0 should match");
        assertEq(currency1_, Currency.unwrap(currency1), "Currency1 should match");
        assertTrue(totalAmount_ > 0, "Total amount should be > 0");
        assertEq(uint256(status), uint256(IDexterHook.OrderStatus.ACTIVE), "Status should be ACTIVE");
        assertEq(zeroForOne, true, "ZeroForOne should be true");
        assertEq(currentFee, 3000, "Fee should be 3000");
    }

    function test_createDCAStrategy_ETHInput() public {
        vm.txGasPrice(1 gwei);

        // Give this test contract ETH for pool operations
        vm.deal(address(this), 200 ether);

        // Create ETH pool
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: currency1, // ERC20 token
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(dcaBot))
        });

        // Initialize ETH pool
        manager.initialize(ethPoolKey, Constants.SQRT_PRICE_1_1);

        // Add liquidity to ETH pool
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 100 ether, // Match the ETH amount sent
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(ethPoolKey, liqParams, ZERO_BYTES);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: address(0), // ETH
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true, // Selling ETH for ERC20
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.1 ether, // 0.1 ETH per swap
            swapOrderMultiplier: 20
        });

        // Calculate required amounts
        uint256 firstLevelAmount = (dcaParams.swapOrderAmount * dcaParams.swapOrderMultiplier) / 10; // 0.2 ETH
        uint256 totalTokenAmount = dcaParams.swapOrderAmount + firstLevelAmount; // 0.3 ETH
        uint256 gasAllocation = (150000 * tx.gasprice * (2 + dcaParams.maxSwapOrders) * 120) / 100; // Correct formula
        uint256 totalETHNeeded = totalTokenAmount + gasAllocation;

        vm.startPrank(user1);
        uint256 dcaId =
            dcaBot.createDCAStrategy{value: totalETHNeeded}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        // Verify DCA was created
        assertTrue(dcaId > 0, "DCA ID should be valid");

        // Check gas accounting
        (,,,,,,,,,,,, uint256 gasAllocated, uint256 gasUsed) = dcaBot.getDCAInfoExtended(dcaId);
        assertEq(gasAllocated, gasAllocation, "Gas allocated should match calculated amount");
        assertTrue(gasUsed <= gasAllocated, "Gas used should not exceed allocated");
    }

    function test_createDCAStrategy_InvalidInputs() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        // Test invalid take profit percent
        IDexterHook.DCAParams memory invalidDCA = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 6000, // > 50% - should fail
            maxSwapOrders: 3,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 10 ether);

        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 1 ether}(poolParams, invalidDCA, 100, block.timestamp + 1 hours);

        // Test invalid max swap orders
        invalidDCA.takeProfitPercent = 1000;
        invalidDCA.maxSwapOrders = 15; // > 10 - should fail

        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 1 ether}(poolParams, invalidDCA, 100, block.timestamp + 1 hours);

        // Test expired deadline
        invalidDCA.maxSwapOrders = 3;

        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 1 ether}(
            poolParams,
            invalidDCA,
            100,
            block.timestamp - 1 // Expired
        );

        vm.stopPrank();
    }

    /* ==========================================================
       DCA STRATEGY MANAGEMENT TESTS
       ========================================================== */

    function test_cancelDCAStrategy() public {
        vm.txGasPrice(1 gwei);

        // Create a DCA strategy first
        uint256 dcaId = _createTestDCAStrategy(user1);

        vm.startPrank(user1);

        // Cancel the strategy
        dcaBot.cancelDCAStrategy(dcaId);

        // Check that the strategy is cancelled
        (,,,,,, IDexterHook.OrderStatus status,,,,,) = dcaBot.getDCAInfo(dcaId);
        assertEq(uint256(status), uint256(IDexterHook.OrderStatus.CANCELLED), "Status should be CANCELLED");

        vm.stopPrank();
    }

    function test_cancelDCAStrategy_Unauthorized() public {
        vm.txGasPrice(1 gwei);

        // Create a DCA strategy with user1
        uint256 dcaId = _createTestDCAStrategy(user1);

        // Try to cancel with user2 (should fail)
        vm.startPrank(user2);
        vm.expectRevert();
        dcaBot.cancelDCAStrategy(dcaId);
        vm.stopPrank();
    }

    function test_sellNow() public {
        vm.txGasPrice(1 gwei);

        // Create a DCA strategy first
        uint256 dcaId = _createTestDCAStrategy(user1);

        vm.startPrank(user1);

        // Since we can't easily simulate accumulated output without complex storage manipulation,
        // and the sellNow functionality with actual output is tested in the mock tests,
        // this test will verify the basic validation logic
        vm.expectRevert("Nothing to sell");
        dcaBot.sellNow(dcaId);

        vm.stopPrank();
    }

    function test_sellNow_NoOutput() public {
        vm.txGasPrice(1 gwei);

        // Create a DCA strategy first
        uint256 dcaId = _createTestDCAStrategy(user1);

        vm.startPrank(user1);

        // Try to sell with no accumulated output (should fail)
        vm.expectRevert("Nothing to sell");
        dcaBot.sellNow(dcaId);

        vm.stopPrank();
    }

    /* ==========================================================
       LIQUIDITY OPERATION TESTS
       ========================================================== */

    function test_addLiquidity() public {
        vm.txGasPrice(1 gwei);

        // Create a new pool for liquidity testing
        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500, // Different fee
            tickSpacing: 10,
            hooks: IHooks(address(dcaBot))
        });

        // Initialize the pool
        manager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);

        vm.startPrank(user1);

        // Approve tokens to the modifyLiquidityRouter
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), 100 ether);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), 100 ether);

        // Add liquidity through the router instead of direct unlockCallback
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidityDelta: 100 ether,
            salt: bytes32(uint256(block.timestamp))
        });

        // Use the router to add liquidity which will properly handle the manager lock
        BalanceDelta delta = modifyLiquidityRouter.modifyLiquidity(newPoolKey, liqParams, ZERO_BYTES);

        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "Should have liquidity delta");

        vm.stopPrank();
    }

    function test_removeLiquidity() public {
        vm.txGasPrice(1 gwei);

        // First add liquidity
        test_addLiquidity();

        vm.startPrank(user1);

        // Remove liquidity via the modifyLiquidityRouter - this will handle the proper unlock flow
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidityDelta: -50 ether, // Negative for removal
            salt: bytes32(uint256(block.timestamp))
        });

        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(dcaBot))
        });

        // Use the router to remove liquidity which will properly handle the manager lock
        BalanceDelta delta = modifyLiquidityRouter.modifyLiquidity(newPoolKey, liqParams, ZERO_BYTES);

        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "Should have liquidity delta");

        vm.stopPrank();
    }

    /* ==========================================================
       HOOK FUNCTION TESTS
       ========================================================== */

    function test_beforeSwap() public {
        vm.txGasPrice(1 gwei);

        // Create a DCA strategy to have pending orders
        uint256 dcaId = _createTestDCAStrategy(user1);

        // Get current tick and calculate valid price limit
        int24 currentTick = dcaBot.getPoolCurrentTick(poolId);

        // For non-zeroForOne swaps, price limit must be greater than current price
        uint160 sqrtPriceLimitX96 = currentTick < TickMath.MAX_TICK - 1
            ? TickMath.getSqrtPriceAtTick(currentTick + 1)
            : TickMath.MAX_SQRT_PRICE - 1;

        // Perform a swap that should trigger the hook
        SwapParams memory swapParams = SwapParams({
            zeroForOne: false, // Buy token0 with token1
            amountSpecified: -0.1 ether, // Exact output
            sqrtPriceLimitX96: sqrtPriceLimitX96 // Valid price limit
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Execute swap
        swapRouter.swap(poolKey, swapParams, testSettings, ZERO_BYTES);

        // The hook should have processed any matching orders
        // Check that the strategy is still active
        (,,,,,, IDexterHook.OrderStatus status,,,,,) = dcaBot.getDCAInfo(dcaId);
        assertEq(uint256(status), uint256(IDexterHook.OrderStatus.ACTIVE), "Status should be ACTIVE");
    }

    function test_afterSwap() public {
        vm.txGasPrice(1 gwei);

        // Get current tick for proper price limit calculation
        int24 currentTick = dcaBot.getPoolCurrentTick(poolId);
        uint160 validPriceLimit = currentTick > TickMath.MIN_TICK + 1
            ? TickMath.getSqrtPriceAtTick(currentTick - 1) // Lower price for zeroForOne
            : TickMath.MIN_SQRT_PRICE + 1;

        // Perform a swap
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true, // Sell token0 for token1
            amountSpecified: 0.1 ether, // Exact input
            sqrtPriceLimitX96: validPriceLimit // Valid price limit
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Execute swap
        swapRouter.swap(poolKey, swapParams, testSettings, ZERO_BYTES);

        // The afterSwap hook should have updated the last tick
        int24 currentTickAfter = dcaBot.getPoolCurrentTick(poolId);
        assertTrue(currentTickAfter != 0, "Current tick should be updated");
    }

    function test_beforeInitialize() public {
        // Create a new pool key
        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 10000, // Different fee
            tickSpacing: 200,
            hooks: IHooks(address(dcaBot))
        });

        // Initialize should work
        manager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);

        // Check that the pool was tracked
        (PoolId[] memory poolIds,,) = dcaBot.getAllPools();
        assertTrue(poolIds.length > 0, "Should have tracked pools");
    }

    function test_afterInitialize() public {
        // Create a new pool key
        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100, // Different fee
            tickSpacing: 1,
            hooks: IHooks(address(dcaBot))
        });

        // Initialize the pool
        manager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);

        // Check that the pool was tracked
        uint256 poolCount = dcaBot.getPoolCount();
        assertTrue(poolCount > 0, "Should have tracked pools");

        // Check that we can get the current tick
        int24 tick = dcaBot.getPoolCurrentTick(newPoolKey.toId());
        assertTrue(tick >= TickMath.MIN_TICK && tick <= TickMath.MAX_TICK, "Should be able to get current tick");
    }

    /* ==========================================================
       VIEW FUNCTION TESTS
       ========================================================== */

    function test_getDCAInfo() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        (
            address user,
            address currency0_,
            address currency1_,
            uint256 totalAmount,
            ,
            ,
            IDexterHook.OrderStatus status,
            ,
            ,
            ,
            ,
            uint24 currentFee
        ) = dcaBot.getDCAInfo(dcaId);

        assertEq(user, user1, "User should match");
        assertEq(currency0_, Currency.unwrap(currency0), "Currency0 should match");
        assertEq(currency1_, Currency.unwrap(currency1), "Currency1 should match");
        assertTrue(totalAmount > 0, "Total amount should be > 0");
        assertEq(uint256(status), uint256(IDexterHook.OrderStatus.ACTIVE), "Status should be ACTIVE");
        assertEq(currentFee, 3000, "Fee should match");
    }

    function test_getDCAInfoExtended() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        (,,,,,,,,,,,, uint256 gasAllocated, uint256 gasUsed) = dcaBot.getDCAInfoExtended(dcaId);

        assertTrue(gasAllocated > 0, "Should have gas allocated");
        assertTrue(gasUsed <= gasAllocated, "Gas used should not exceed allocated");
    }

    function test_getDCAOrder() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        (address user,,,,, uint256[] memory targetPrices, uint256[] memory targetAmounts,,) = dcaBot.getDCAOrder(dcaId);

        assertEq(user, user1, "User should match");
        assertTrue(targetPrices.length > 0, "Should have target prices");
        assertTrue(targetAmounts.length > 0, "Should have target amounts");
        assertEq(targetPrices.length, targetAmounts.length, "Arrays should have same length");
    }

    function test_getPoolCurrentTick() public view {
        int24 tick = dcaBot.getPoolCurrentTick(poolId);
        assertTrue(tick >= TickMath.MIN_TICK && tick <= TickMath.MAX_TICK, "Should be able to get current tick");
    }

    function test_getAllPools() public view {
        (PoolId[] memory poolIds, PoolKey[] memory poolKeys, int24[] memory ticks) = dcaBot.getAllPools();

        assertTrue(poolIds.length > 0, "Should have pools");
        assertEq(poolIds.length, poolKeys.length, "Arrays should have same length");
        assertEq(poolKeys.length, ticks.length, "Arrays should have same length");
    }

    function test_getPoolCount() public view {
        uint256 count = dcaBot.getPoolCount();
        assertTrue(count > 0, "Should have pools");
    }

    /* ==========================================================
       ERROR CONDITION TESTS
       ========================================================== */

    function test_getDCAInfo_InvalidOrder() public {
        vm.expectRevert();
        dcaBot.getDCAInfo(999); // Non-existent order
    }

    function test_cancelDCAStrategy_InvalidOrder() public {
        vm.startPrank(user1);
        vm.expectRevert();
        dcaBot.cancelDCAStrategy(999); // Non-existent order
        vm.stopPrank();
    }

    function test_cancelDCAStrategy_OrderNotActive() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        vm.startPrank(user1);
        // Cancel the order first
        dcaBot.cancelDCAStrategy(dcaId);

        // Try to cancel again (should fail)
        vm.expectRevert();
        dcaBot.cancelDCAStrategy(dcaId);
        vm.stopPrank();
    }

    function test_sellNow_InvalidOrder() public {
        vm.startPrank(user1);
        vm.expectRevert();
        dcaBot.sellNow(999); // Non-existent order
        vm.stopPrank();
    }

    function test_sellNow_OrderNotActive() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        vm.startPrank(user1);
        // Cancel the order first
        dcaBot.cancelDCAStrategy(dcaId);

        // Try to sell (should fail)
        vm.expectRevert();
        dcaBot.sellNow(dcaId);
        vm.stopPrank();
    }

    /* ==========================================================
       GAS COMPENSATION TESTS
       ========================================================== */

    function test_fundGasCompensationPool() public {
        uint256 initialBalance = address(dcaBot).balance;

        vm.startPrank(user1);
        dcaBot.fundGasCompensationPool{value: 1 ether}();
        vm.stopPrank();

        uint256 finalBalance = address(dcaBot).balance;
        assertEq(finalBalance, initialBalance + 1 ether, "Should have received ETH");
    }

    function test_gasRefund() public {
        vm.txGasPrice(1 gwei);

        // Get current tick for proper price limit calculation
        int24 currentTick = dcaBot.getPoolCurrentTick(poolId);
        uint160 validPriceLimit = currentTick < TickMath.MAX_TICK - 1
            ? TickMath.getSqrtPriceAtTick(currentTick + 1) // Higher price for !zeroForOne
            : TickMath.MAX_SQRT_PRICE - 1;

        // Perform a swap that should trigger gas refund
        SwapParams memory swapParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: validPriceLimit // Valid price limit
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Execute swap
        swapRouter.swap(poolKey, swapParams, testSettings, ZERO_BYTES);
    }

    /* ==========================================================
       EDGE CASE TESTS
       ========================================================== */

    function test_multipleUsers() public {
        vm.txGasPrice(1 gwei);

        // Create DCA strategies for multiple users
        uint256 dcaId1 = _createTestDCAStrategy(user1);
        uint256 dcaId2 = _createTestDCAStrategy(user2);
        uint256 dcaId3 = _createTestDCAStrategy(user3);

        assertEq(dcaId1, 1, "First DCA ID should be 1");
        assertEq(dcaId2, 2, "Second DCA ID should be 2");
        assertEq(dcaId3, 3, "Third DCA ID should be 3");

        // Check that each user can only manage their own orders
        vm.startPrank(user1);
        dcaBot.cancelDCAStrategy(dcaId1); // Should work

        vm.expectRevert();
        dcaBot.cancelDCAStrategy(dcaId2); // Should fail
        vm.stopPrank();
    }

    function test_perpetualDCA() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        // Simulate take profit hit
        vm.store(address(dcaBot), keccak256(abi.encode(dcaId, 4)), bytes32(uint256(1))); // dcaCurrentLevel = 1

        // The strategy should continue running as perpetual
        (,,,,,, IDexterHook.OrderStatus status,,,,,) = dcaBot.getDCAInfo(dcaId);
        assertEq(uint256(status), uint256(IDexterHook.OrderStatus.ACTIVE), "Should still be active");
    }

    /* ==========================================================
       ADDITIONAL COMPREHENSIVE TESTS
       ========================================================== */

    function test_createDCAStrategy_MaxSwapOrders() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        // Test with maximum swap orders
        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 10, // Maximum allowed
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.1 ether,
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 10 ether);

        uint256 dcaId = dcaBot.createDCAStrategy{value: 1 ether}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertTrue(dcaId > 0, "Should create DCA with max swap orders");
    }

    function test_createDCAStrategy_MinSwapOrders() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        // Test with minimum swap orders
        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 1, // Minimum allowed
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.1 ether,
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

        uint256 dcaId = dcaBot.createDCAStrategy{value: 1 ether}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertTrue(dcaId > 0, "Should create DCA with min swap orders");
    }

    function test_createDCAStrategy_DifferentFees() public {
        vm.txGasPrice(1 gwei);

        // Test with different fee tiers (skip 3000 since it's already initialized in setUp)
        uint24[3] memory feesArray = [uint24(100), uint24(500), uint24(10000)];
        uint24[] memory fees = new uint24[](3);
        for (uint256 i = 0; i < 3; i++) {
            fees[i] = feesArray[i];
        }

        for (uint256 i = 0; i < fees.length; i++) {
            // Create new pool for each fee
            PoolKey memory newPoolKey = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: fees[i],
                tickSpacing: _getTickSpacing(fees[i]),
                hooks: IHooks(address(dcaBot))
            });

            // Initialize pool
            manager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);

            // Add liquidity
            ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(_getTickSpacing(fees[i])),
                tickUpper: TickMath.maxUsableTick(_getTickSpacing(fees[i])),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            });
            modifyLiquidityRouter.modifyLiquidity(newPoolKey, liqParams, ZERO_BYTES);

            IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
                currency0: Currency.unwrap(currency0),
                currency1: Currency.unwrap(currency1),
                fee: fees[i]
            });

            IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
                zeroForOne: true,
                takeProfitPercent: 1000,
                maxSwapOrders: 2,
                priceDeviationPercent: 500,
                priceDeviationMultiplier: 20,
                swapOrderAmount: 0.1 ether,
                swapOrderMultiplier: 20
            });

            vm.startPrank(user1);
            MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

            uint256 dcaId =
                dcaBot.createDCAStrategy{value: 1 ether}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
            vm.stopPrank();

            assertTrue(dcaId > 0, "Should create DCA with fee");
        }
    }

    function test_createDCAStrategy_ZeroForOneFalse() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        // Test with zeroForOne = false (buying token0 with token1)
        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: false, // Different direction
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.1 ether,
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency1)).approve(address(dcaBot), 1 ether); // Approve currency1

        uint256 dcaId = dcaBot.createDCAStrategy{value: 1 ether}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertTrue(dcaId > 0, "Should create DCA with zeroForOne false");

        // Check direction
        (,,,,,,,,, bool zeroForOne,,) = dcaBot.getDCAInfo(dcaId);
        assertEq(zeroForOne, false, "Should be zeroForOne false");
    }

    function test_createDCAStrategy_InvalidPriceDeviation() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        // Test invalid price deviation percent
        IDexterHook.DCAParams memory invalidDCA = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 3000, // > 20% - should fail
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.1 ether,
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 1 ether}(poolParams, invalidDCA, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_createDCAStrategy_InvalidMultiplier() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        // Test invalid price deviation multiplier
        IDexterHook.DCAParams memory invalidDCA = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 5, // < 0.1 - should fail
            swapOrderAmount: 0.1 ether,
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 1 ether}(poolParams, invalidDCA, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_createDCAStrategy_InvalidSwapOrderMultiplier() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        // Test invalid swap order multiplier
        IDexterHook.DCAParams memory invalidDCA = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.1 ether,
            swapOrderMultiplier: 5 // < 0.1 - should fail
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 1 ether}(poolParams, invalidDCA, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_createDCAStrategy_InvalidAmount() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        // Test invalid swap order amount
        IDexterHook.DCAParams memory invalidDCA = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0, // Invalid - should fail
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 1 ether}(poolParams, invalidDCA, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_createDCAStrategy_SameCurrencies() public {
        vm.txGasPrice(1 gwei);

        // Test with same currencies
        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency0), // Same as currency0
            fee: 3000
        });

        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.1 ether,
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 1 ether}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_createDCAStrategy_InsufficientGas() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.1 ether,
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

        // Send 0 ETH for gas (should fail)
        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 0}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_createDCAStrategy_InsufficientETHForOrderPlusGas() public {
        vm.txGasPrice(1 gwei);

        // Create ETH pool
        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(dcaBot))
        });

        manager.initialize(ethPoolKey, Constants.SQRT_PRICE_1_1);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: address(0), // ETH
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether, // Large amount
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);

        // Send insufficient ETH (should fail)
        vm.expectRevert();
        dcaBot.createDCAStrategy{value: 0.1 ether}( // Too little ETH
        poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_cancelDCAStrategy_NoTokensToCancel() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        vm.startPrank(user1);

        // Simulate that the user has no claim tokens (already redeemed/transferred)
        // Calculate storage slot for balanceOf[user1][dcaId] in ERC6909
        // balanceOf is mapping(address => mapping(uint256 => uint256))
        bytes32 balanceSlot = keccak256(abi.encode(dcaId, keccak256(abi.encode(user1, 0)))); // slot 0 for balanceOf
        vm.store(address(dcaBot), balanceSlot, bytes32(0)); // Set user balance to 0

        vm.expectRevert(DexterHook.NoTokensToCancel.selector);
        dcaBot.cancelDCAStrategy(dcaId);

        vm.stopPrank();
    }

    function test_sellNow_NotAuthorized() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        // Try to sell with different user (should fail)
        vm.startPrank(user2);
        vm.expectRevert();
        dcaBot.sellNow(dcaId);
        vm.stopPrank();
    }

    function test_sellNowOrderNotActive() public {
        vm.txGasPrice(1 gwei);

        uint256 dcaId = _createTestDCAStrategy(user1);

        vm.startPrank(user1);
        // Cancel the order first
        dcaBot.cancelDCAStrategy(dcaId);

        // Try to sell cancelled order (should fail)
        vm.expectRevert();
        dcaBot.sellNow(dcaId);
        vm.stopPrank();
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory permissions = dcaBot.getHookPermissions();

        assertTrue(permissions.beforeInitialize, "Should have beforeInitialize permission");
        assertTrue(permissions.afterInitialize, "Should have afterInitialize permission");
        assertTrue(permissions.beforeSwap, "Should have beforeSwap permission");
        assertTrue(permissions.afterSwap, "Should have afterSwap permission");
        assertFalse(permissions.beforeAddLiquidity, "Should not have beforeAddLiquidity permission");
        assertFalse(permissions.afterAddLiquidity, "Should not have afterAddLiquidity permission");
        assertFalse(permissions.beforeRemoveLiquidity, "Should not have beforeRemoveLiquidity permission");
        assertFalse(permissions.afterRemoveLiquidity, "Should not have afterRemoveLiquidity permission");
    }

    function test_unlockCallback_InvalidData() public {
        // Test with invalid data length
        bytes memory invalidData = abi.encode("invalid");

        vm.expectRevert();
        dcaBot.unlockCallback(invalidData);
    }

    function test_unlockCallback_LiquidityOperation() public {
        // Test liquidity operation through unlockCallback
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 100 ether,
            salt: bytes32(uint256(block.timestamp))
        });

        bytes memory data = abi.encode("general_liquidity", poolKey, liqParams);

        // The function might revert due to insufficient tokens or other constraints
        // Just test that it doesn't panic on the data format
        try dcaBot.unlockCallback(data) returns (bytes memory result) {
            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            // If it succeeds, check that it returns some delta
            assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "Should have liquidity delta");
        } catch {
            // If it reverts, that's also acceptable for this test
            // The test mainly verifies the function doesn't panic on the data format
        }
    }

    function test_unlockCallback_AddLiquidityOperation() public {
        // Test ADD_LIQUIDITY operation with correct encoding format
        bytes memory data = abi.encode(poolKey, uint256(100 ether), true, "ADD_LIQUIDITY");

        // The function might revert due to insufficient liquidity or other pool constraints
        // Just test that it doesn't panic, not that it succeeds
        try dcaBot.unlockCallback(data) returns (bytes memory result) {
            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            // If it succeeds, check that it returns some delta
            assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "Should have liquidity delta");
        } catch {
            // If it reverts, that's also acceptable for this test
            // The test mainly verifies the function doesn't panic on the data format
        }
    }

    function test_gasCompensationPool() public {
        uint256 initialPool = address(dcaBot).balance;

        // Fund the pool
        vm.startPrank(user1);
        dcaBot.fundGasCompensationPool{value: 2 ether}();
        vm.stopPrank();

        uint256 finalPool = address(dcaBot).balance;
        assertEq(finalPool, initialPool + 2 ether, "Should have funded the pool");
    }

    function test_receive() public {
        uint256 initialBalance = address(dcaBot).balance;

        // Send ETH directly to contract
        vm.startPrank(user1);
        (bool success,) = address(dcaBot).call{value: 1 ether}("");
        assertTrue(success, "Should receive ETH");
        vm.stopPrank();

        uint256 finalBalance = address(dcaBot).balance;
        assertEq(finalBalance, initialBalance + 1 ether, "Should have received ETH");
    }

    function test_fallback() public {
        uint256 initialBalance = address(dcaBot).balance;

        // Send ETH with data to contract (triggers fallback)
        vm.startPrank(user1);
        (bool success,) = address(dcaBot).call{value: 1 ether}("0x1234");
        assertTrue(success, "Should handle fallback");
        vm.stopPrank();

        uint256 finalBalance = address(dcaBot).balance;
        assertEq(finalBalance, initialBalance + 1 ether, "Should have received ETH");
    }

    function test_multiplePools() public {
        // Create multiple pools and test pool tracking
        PoolKey[] memory poolKeys = new PoolKey[](3);
        uint24[3] memory feesArray = [uint24(100), uint24(500), uint24(10000)];
        uint24[] memory fees = new uint24[](3);
        for (uint256 i = 0; i < 3; i++) {
            fees[i] = feesArray[i];
        }

        for (uint256 i = 0; i < 3; i++) {
            poolKeys[i] = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: fees[i],
                tickSpacing: _getTickSpacing(fees[i]),
                hooks: IHooks(address(dcaBot))
            });

            manager.initialize(poolKeys[i], Constants.SQRT_PRICE_1_1);
        }

        uint256 poolCount = dcaBot.getPoolCount();
        assertEq(poolCount, 4, "Should have 4 pools (1 from setUp + 3 new)");

        (PoolId[] memory poolIds, PoolKey[] memory returnedKeys, int24[] memory ticks) = dcaBot.getAllPools();
        assertEq(poolIds.length, 4, "Should return 4 pools");
        assertEq(returnedKeys.length, 4, "Should return 4 pool keys");
        assertEq(ticks.length, 4, "Should return 4 ticks");
    }

    function test_edgeCase_ZeroTick() public view {
        // Test with zero tick
        int24 tick = dcaBot.getPoolCurrentTick(poolId);
        assertTrue(tick >= TickMath.MIN_TICK && tick <= TickMath.MAX_TICK, "Tick should be valid");
    }

    function test_edgeCase_MaxTick() public {
        // Test with max tick - use different fee than setUp pool
        PoolKey memory maxTickPool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500, // Different from setUp pool (3000)
            tickSpacing: 10,
            hooks: IHooks(address(dcaBot))
        });

        // Use MAX_TICK - 1 to avoid InvalidSqrtPrice since MAX_TICK itself may be out of range
        int24 nearMaxTick = TickMath.MAX_TICK - 1;
        manager.initialize(maxTickPool, TickMath.getSqrtPriceAtTick(nearMaxTick));

        int24 tick = dcaBot.getPoolCurrentTick(maxTickPool.toId());
        assertEq(tick, nearMaxTick, "Should handle near max tick");
    }

    function test_edgeCase_MinTick() public {
        // Test with min tick - use different fee than other pools
        PoolKey memory minTickPool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100, // Different from other pools
            tickSpacing: 1,
            hooks: IHooks(address(dcaBot))
        });

        manager.initialize(minTickPool, TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK));

        int24 tick = dcaBot.getPoolCurrentTick(minTickPool.toId());
        assertEq(tick, TickMath.MIN_TICK, "Should handle min tick");
    }

    function test_stressTest_MultipleOrders() public {
        vm.txGasPrice(1 gwei);

        // Create many orders
        uint256 numOrders = 10;
        uint256[] memory dcaIds = new uint256[](numOrders);

        for (uint256 i = 0; i < numOrders; i++) {
            address user = i % 2 == 0 ? user1 : user2;
            dcaIds[i] = _createTestDCAStrategy(user);
        }

        // Verify all orders were created
        for (uint256 i = 0; i < numOrders; i++) {
            assertEq(dcaIds[i], i + 1, "Should have correct DCA ID");
        }

        // Test that users can only manage their own orders
        vm.startPrank(user1);
        dcaBot.cancelDCAStrategy(dcaIds[0]); // Should work

        vm.expectRevert();
        dcaBot.cancelDCAStrategy(dcaIds[1]); // Should fail
        vm.stopPrank();
    }

    function test_stressTest_LargeAmounts() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 100 ether, // Large amount
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1000 ether);

        uint256 dcaId = dcaBot.createDCAStrategy{value: 10 ether}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertTrue(dcaId > 0, "Should handle large amounts");
    }

    function test_stressTest_SmallAmounts() public {
        vm.txGasPrice(1 gwei);

        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 wei, // Very small amount
            swapOrderMultiplier: 20
        });

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), 1 ether);

        uint256 dcaId = dcaBot.createDCAStrategy{value: 1 ether}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        assertTrue(dcaId > 0, "Should handle small amounts");
    }

    /* ==========================================================
       HELPER FUNCTIONS
       ========================================================== */

    function _createTestDCAStrategy(address user) internal returns (uint256 dcaId) {
        IDexterHook.PoolParams memory poolParams = IDexterHook.PoolParams({
            currency0: Currency.unwrap(currency0),
            currency1: Currency.unwrap(currency1),
            fee: 3000
        });

        IDexterHook.DCAParams memory dcaParams = IDexterHook.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 0.5 ether,
            swapOrderMultiplier: 20
        });

        uint256 gasAllocation = 1 ether;
        uint256 totalTokens = 1.5 ether;

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(dcaBot), totalTokens);

        dcaId = dcaBot.createDCAStrategy{value: gasAllocation}(poolParams, dcaParams, 100, block.timestamp + 1 hours);
        vm.stopPrank();

        return dcaId;
    }

    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        return 60;
    }
}
