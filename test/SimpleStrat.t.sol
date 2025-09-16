// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/interfaces/IDCADexterBotV1.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

// A small mock of the DCADexterBotV1 interface to simulate behavior for unit tests.
contract MockDCABot {
    using stdMath for uint256;

    struct Order {
        address user;
        address currency0;
        address currency1;
        uint256 totalAmount;
        uint256 executedAmount;
        uint256 claimableAmount;
        IDCADexterBotV1.OrderStatus status;
        bool isFullyExecuted;
        uint256 expirationTime;
        bool zeroForOne;
        uint256 totalBatches;
        uint24 currentFee;
        uint256 gasAllocated;
        uint256 gasUsed;
        uint256 gasBorrowedFromTank;
        uint256[] inputs;
        uint256[] outputs;
    }

    mapping(uint256 => Order) public orders;
    uint256 public nextId = 1;

    // createDCAStrategy accepts msg.value as gas allocation; returns id
    error InvalidTakeProfitPercent();
    error InvalidMaxSwapOrders();
    error InvalidPriceDeviation();
    error ExpiredDeadline();

    function createDCAStrategy(
        IDCADexterBotV1.PoolParams calldata poolParams,
        IDCADexterBotV1.DCAParams calldata dca,
        uint32 slippage,
        uint256 expirationTime
    ) external payable returns (uint256 dcaId) {
        // Validate parameters
        if (dca.takeProfitPercent > 5000) revert InvalidTakeProfitPercent();
        if (dca.maxSwapOrders > 10) revert InvalidMaxSwapOrders();
        if (dca.priceDeviationPercent > 2000) revert InvalidPriceDeviation();
        if (expirationTime <= block.timestamp) revert ExpiredDeadline();

        dcaId = nextId++;
        Order storage o = orders[dcaId];
        o.user = msg.sender;
        o.currency0 = poolParams.currency0;
        o.currency1 = poolParams.currency1;
        o.totalAmount = dca.swapOrderAmount * (dca.maxSwapOrders + 1);
        o.executedAmount = 0;
        o.claimableAmount = 0;
        o.status = IDCADexterBotV1.OrderStatus.ACTIVE;
        o.isFullyExecuted = false;
        o.expirationTime = expirationTime;
        o.zeroForOne = dca.zeroForOne;
        o.totalBatches = dca.maxSwapOrders;
        o.currentFee = 3000;

        // Handle token transfers
        if (dca.zeroForOne) {
            if (poolParams.currency0 != address(0)) {
                // Transfer ERC20 tokens
                ERC20Mock(poolParams.currency0).transferFrom(msg.sender, address(this), o.totalAmount);
            }
        } else {
            if (poolParams.currency1 != address(0)) {
                // Transfer ERC20 tokens
                ERC20Mock(poolParams.currency1).transferFrom(msg.sender, address(this), o.totalAmount);
            }
        }

        // Transfer initial liquidity amount for the pool
        uint256 initialLiquidity = o.totalAmount / 10; // 10% for initial liquidity
        if (dca.zeroForOne) {
            if (poolParams.currency1 != address(0)) {
                ERC20Mock(poolParams.currency1).mint(address(this), initialLiquidity);
            }
        } else {
            if (poolParams.currency0 != address(0)) {
                ERC20Mock(poolParams.currency0).mint(address(this), initialLiquidity);
            }
        }

        o.gasAllocated = msg.value;
        o.gasUsed = 0;
        o.gasBorrowedFromTank = 0;
    }

    // allow test to simulate execution
    function simulateExecution(
        uint256 dcaId,
        uint256 gasUsed,
        uint256 gasBorrowed,
        uint256[] calldata inputs,
        uint256[] calldata outputs
    ) external {
        Order storage o = orders[dcaId];
        require(o.user != address(0), "unknown dca");
        o.gasUsed = gasUsed;
        o.gasBorrowedFromTank = gasBorrowed;
        o.inputs = inputs;
        o.outputs = outputs;

        uint256 sumIn = 0;
        uint256 sumOut = 0;
        for (uint256 i = 0; i < inputs.length; i++) {
            sumIn += inputs[i];
        }
        for (uint256 i = 0; i < outputs.length; i++) {
            sumOut += outputs[i];
        }

        // Simulate token movements
        simulateTokenMovements(dcaId, inputs, outputs);

        o.executedAmount = sumIn;
        o.claimableAmount = sumOut;
        o.isFullyExecuted = true;
        o.status = IDCADexterBotV1.OrderStatus.COMPLETED;
    }

    function getDCAInfo(uint256 dcaId)
        external
        view
        returns (
            address user,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256 claimableAmount,
            IDCADexterBotV1.OrderStatus status,
            bool isFullyExecuted,
            uint256 expirationTime,
            bool zeroForOne,
            uint256 totalBatches,
            uint24 currentFee
        )
    {
        Order storage o = orders[dcaId];
        return (
            o.user,
            o.currency0,
            o.currency1,
            o.totalAmount,
            o.executedAmount,
            o.claimableAmount,
            o.status,
            o.isFullyExecuted,
            o.expirationTime,
            o.zeroForOne,
            o.totalBatches,
            o.currentFee
        );
    }

    function getDCAInfoExtended(uint256 dcaId)
        external
        view
        returns (
            address user,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256 claimableAmount,
            IDCADexterBotV1.OrderStatus status,
            bool isFullyExecuted,
            uint256 expirationTime,
            bool zeroForOne,
            uint256 totalBatches,
            uint24 currentFee,
            uint256 gasAllocated,
            uint256 gasUsed,
            uint256 gasBorrowedFromTank
        )
    {
        Order storage o = orders[dcaId];
        return (
            o.user,
            address(0),
            address(0),
            o.totalAmount,
            o.executedAmount,
            o.claimableAmount,
            o.status,
            o.isFullyExecuted,
            o.expirationTime,
            o.zeroForOne,
            o.totalBatches,
            o.currentFee,
            o.gasAllocated,
            o.gasUsed,
            o.gasBorrowedFromTank
        );
    }

    function getDCAOrder(uint256 dcaId)
        external
        view
        returns (
            address user,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256[] memory targetPrices,
            uint256[] memory targetAmounts,
            IDCADexterBotV1.OrderStatus status,
            bool isFullyExecuted
        )
    {
        Order storage o = orders[dcaId];
        return (
            o.user,
            o.currency0,
            o.currency1,
            o.totalAmount,
            o.executedAmount,
            new uint256[](0),
            new uint256[](0),
            o.status,
            o.isFullyExecuted
        );
    }

    // Function to simulate token movements during execution
    function simulateTokenMovements(uint256 dcaId, uint256[] memory inputs, uint256[] memory outputs) internal {
        Order storage o = orders[dcaId];

        // Transfer input tokens from contract to simulate swap
        if (o.zeroForOne) {
            if (o.currency0 != address(0)) {
                for (uint256 i = 0; i < inputs.length; i++) {
                    // Simulate input token consumption
                    ERC20Mock(o.currency0).transfer(address(0xdead), inputs[i]);
                }
            }
            // Mint or transfer output tokens to user
            if (o.currency1 != address(0)) {
                for (uint256 i = 0; i < outputs.length; i++) {
                    ERC20Mock(o.currency1).mint(o.user, outputs[i]);
                }
            }
        } else {
            if (o.currency1 != address(0)) {
                for (uint256 i = 0; i < inputs.length; i++) {
                    ERC20Mock(o.currency1).transfer(address(0xdead), inputs[i]);
                }
            }
            if (o.currency0 != address(0)) {
                for (uint256 i = 0; i < outputs.length; i++) {
                    ERC20Mock(o.currency0).mint(o.user, outputs[i]);
                }
            }
        }
    }
}

contract SimpleStrat is Test {
    MockDCABot public mock;

    function setUp() public {
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        mock = new MockDCABot();
        // deterministic gas price
        vm.txGasPrice(1 gwei);
        vm.deal(address(this), 10 ether);

        // Mint and approve a very large amount for all tests
        weth.mint(address(this), 1000000 ether);
        usdc.mint(address(this), 1000000000 * 1e6);

        // Approve spending with a very high allowance
        weth.approve(address(mock), type(uint256).max);
        usdc.approve(address(mock), type(uint256).max);
    }

    receive() external payable {}

    function _calcExpectedGas(uint8 maxSwapOrders) internal view returns (uint256) {
        uint256 gasBase = 150000 * tx.gasprice;
        return (gasBase * (2 + maxSwapOrders) * 120) / 100;
    }

    function test_multiOrderGasAccounting_and_receipt() public {
        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(0), currency1: address(0), fee: 3000});

        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 4,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 10
        });

        uint256 expected = _calcExpectedGas(dca.maxSwapOrders);

        // create strategy and send expected gas
        uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

        // Simulate execution: use part of gas and no borrowing
        uint256 gasUsed = expected / 2;
        uint256 gasBorrowed = 0;
        uint256[] memory inputs = new uint256[](3);
        uint256[] memory outputs = new uint256[](3);
        inputs[0] = 1 ether;
        inputs[1] = 2 ether;
        inputs[2] = 3 ether;
        outputs[0] = 0.9 ether;
        outputs[1] = 1.8 ether;
        outputs[2] = 2.7 ether;

        // call simulateExecution
        mock.simulateExecution(id, gasUsed, gasBorrowed, inputs, outputs);

        (,,, uint256 totalAmount, uint256 executedAmount, uint256 claimableAmount,, bool isFullyExecuted,,,,) =
            mock.getDCAInfo(id);
        (,,,,,,,,,,,, uint256 gasAllocated, uint256 gasUsedRead, uint256 gasBorrowedRead) = mock.getDCAInfoExtended(id);

        // Assertions
        assertEq(gasAllocated, expected, "gas allocated should match expected");
        assertEq(gasUsedRead, gasUsed, "gas used should match simulated");
        assertEq(gasBorrowedRead, gasBorrowed, "gas borrowed should match simulated");

        // Verify swap totals
        assertEq(executedAmount, inputs[0] + inputs[1] + inputs[2], "executedAmount sum");
        assertEq(claimableAmount, outputs[0] + outputs[1] + outputs[2], "claimableAmount sum");

        // Build receipt (simple struct in test)
        console.log("--- RECEIPT ---");
        console.log("DCA ID:", id);
        console.log("User:", address(this));
        console.log("Total Allocated Input:", totalAmount / 1 ether, "ETH");
        console.log("Total Input Spent:", executedAmount / 1 ether, "ETH");
        console.log("Total Output Received:", claimableAmount / 1 ether, "ETH");
        console.log("Gas Allocated (wei):", gasAllocated);
        console.log("Gas Used (wei):", gasUsedRead);
        console.log("Gas Borrowed (wei):", gasBorrowedRead);
        console.log("Completed:", isFullyExecuted ? 1 : 0);
    }

    function test_gasBorrowedFromTank() public {
        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(0), currency1: address(0), fee: 3000});

        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: false,
            takeProfitPercent: 500,
            maxSwapOrders: 2,
            priceDeviationPercent: 200,
            priceDeviationMultiplier: 10,
            swapOrderAmount: 2 ether,
            swapOrderMultiplier: 5
        });

        uint256 expected = _calcExpectedGas(dca.maxSwapOrders);

        // create strategy and send partial gas (less than expected) so execution must borrow
        uint256 provided = expected / 4; // insufficient
        uint256 id = mock.createDCAStrategy{value: provided}(poolParams, dca, 100, block.timestamp + 1 hours);

        // Simulate execution: gasUsed requires borrowing from tank
        uint256 gasUsed = expected; // uses the full expected amount
        uint256 gasBorrowed = gasUsed > provided ? gasUsed - provided : 0;

        uint256[] memory inputs = new uint256[](2);
        uint256[] memory outputs = new uint256[](2);
        inputs[0] = 2 ether;
        inputs[1] = 2 ether;
        outputs[0] = 1.9 ether;
        outputs[1] = 1.9 ether;

        mock.simulateExecution(id, gasUsed, gasBorrowed, inputs, outputs);

        (,,,,,,,,,,,, uint256 gasAllocated, uint256 gasUsedRead, uint256 gasBorrowedRead) = mock.getDCAInfoExtended(id);

        // Assertions: gasBorrowed should be > 0 and reflect the difference
        assertTrue(gasBorrowedRead > 0, "gasBorrowed should be > 0");
        assertEq(gasAllocated, provided, "gas allocated should match what was provided");
        assertEq(gasUsedRead, gasUsed, "gas used should equal simulated usage");

        console.log("Borrowed (wei):", gasBorrowedRead);
    }

    function test_maxSwapOrders() public {
        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(0), currency1: address(0), fee: 3000});

        // Test max orders (10)
        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 10, // Maximum allowed
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 10
        });

        uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
        uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

        // Simulate full execution
        uint256[] memory inputs = new uint256[](10);
        uint256[] memory outputs = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            inputs[i] = 1 ether * (i + 1);
            outputs[i] = 0.95 ether * (i + 1); // 5% slippage simulation
        }

        mock.simulateExecution(id, expected, 0, inputs, outputs);

        (,,,, uint256 executedAmount, uint256 claimableAmount,, bool isFullyExecuted,,, uint256 totalBatches,) =
            mock.getDCAInfo(id);

        assertTrue(isFullyExecuted, "Order should be fully executed");
        assertEq(totalBatches, 10, "Should have 10 batches");
        assertTrue(executedAmount > 0, "Should have executed amount");
        assertTrue(claimableAmount > 0, "Should have claimable amount");
    }

    function test_priceDeviationMultiplier() public {
        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(0), currency1: address(0), fee: 3000});

        // Test with different price deviation multipliers
        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 3,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 50, // 5x multiplier
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 20
        });

        uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
        uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

        uint256[] memory inputs = new uint256[](3);
        uint256[] memory outputs = new uint256[](3);
        inputs[0] = 1 ether;
        inputs[1] = 2 ether;
        inputs[2] = 4 ether;
        outputs[0] = 0.95 ether;
        outputs[1] = 1.9 ether;
        outputs[2] = 3.8 ether;

        mock.simulateExecution(id, expected / 2, 0, inputs, outputs);

        (,,,, uint256 executedAmount, uint256 claimableAmount,,,,,,) = mock.getDCAInfo(id);

        assertEq(executedAmount, 7 ether, "Total executed amount should be 7 ether");
        assertEq(claimableAmount, 6.65 ether, "Total claimable should be 6.65 ether");
    }

    // Mock WETH and USDC tokens for liquidity tests
    ERC20Mock weth;
    ERC20Mock usdc;

    function test_addLiquidity() public {
        // Setup tokens with initial liquidity
        weth.mint(address(this), 100 ether);
        usdc.mint(address(this), 200_000 * 10 ** 6); // $200k USDC

        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(weth), currency1: address(usdc), fee: 3000});

        // Create DCA strategy that will also add initial liquidity
        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 10 ether, // Increased for better testing
            swapOrderMultiplier: 10
        });

        // Record initial balances
        uint256 initialWethBalance = weth.balanceOf(address(mock));
        uint256 initialUsdcBalance = usdc.balanceOf(address(mock));

        // Approve tokens
        weth.approve(address(mock), 50 ether);
        usdc.approve(address(mock), 100_000 * 10 ** 6);

        uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
        uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

        // Verify initial liquidity state
        (address user, address token0, address token1,,,,,,,,,) = mock.getDCAInfo(id);

        assertEq(user, address(this), "Invalid user");
        assertEq(token0, address(weth), "Invalid token0");
        assertEq(token1, address(usdc), "Invalid token1");

        // Check token balances after liquidity add
        assertTrue(weth.balanceOf(address(mock)) > initialWethBalance, "Should have increased WETH balance");
        assertTrue(usdc.balanceOf(address(mock)) > initialUsdcBalance, "Should have increased USDC balance");
    }

    function test_removeLiquidity() public {
        // Setup initial state similar to addLiquidity test
        weth.mint(address(this), 100 ether);
        usdc.mint(address(this), 200_000 * 10 ** 6);

        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(weth), currency1: address(usdc), fee: 3000});

        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 5 ether, // Increased amount for better testing
            swapOrderMultiplier: 10
        });

        // Record initial balances
        uint256 initialUserWethBalance = weth.balanceOf(address(this));
        uint256 initialUserUsdcBalance = usdc.balanceOf(address(this));
        uint256 initialMockWethBalance = weth.balanceOf(address(mock));
        uint256 initialMockUsdcBalance = usdc.balanceOf(address(mock));

        // Approve and create strategy
        weth.approve(address(mock), 50 ether);
        usdc.approve(address(mock), 100_000 * 10 ** 6);

        uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
        uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

        // Verify initial token transfers
        assertEq(
            weth.balanceOf(address(this)),
            initialUserWethBalance - (5 ether * 3), // swapOrderAmount * (maxSwapOrders + 1)
            "Incorrect initial WETH transfer"
        );
        assertEq(
            weth.balanceOf(address(mock)), initialMockWethBalance + (5 ether * 3), "Mock should have received WETH"
        );

        // Simulate execution
        uint256[] memory inputs = new uint256[](1);
        uint256[] memory outputs = new uint256[](1);
        inputs[0] = 5 ether;
        outputs[0] = 9500 * 10 ** 6; // 9500 USDC for 5 ETH

        mock.simulateExecution(id, expected / 2, 0, inputs, outputs);

        // Check execution state
        (,,,, uint256 executedAmount, uint256 claimableAmount,,,,,,) = mock.getDCAInfo(id);
        assertEq(executedAmount, 5 ether, "Should have executed 5 ETH");
        assertEq(claimableAmount, 9500 * 10 ** 6, "Should have 9500 USDC claimable");

        // Verify final balances
        assertEq(
            weth.balanceOf(address(mock)),
            initialMockWethBalance + (5 ether * 2), // Initial deposit minus executed amount
            "Incorrect final mock WETH balance"
        );
        assertTrue(usdc.balanceOf(address(this)) > initialUserUsdcBalance, "User should have received USDC");
    }

    function test_addAndRemoveLiquidityWithDifferentAmounts() public {
        // Setup with varying amounts
        weth.mint(address(this), 1000 ether);
        usdc.mint(address(this), 2_000_000 * 10 ** 6);

        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(weth), currency1: address(usdc), fee: 3000});

        // Test different order sizes
        uint256[] memory orderSizes = new uint256[](3);
        orderSizes[0] = 1 ether;
        orderSizes[1] = 5 ether;
        orderSizes[2] = 10 ether;

        for (uint256 i = 0; i < orderSizes.length; i++) {
            IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
                zeroForOne: true,
                takeProfitPercent: 1000,
                maxSwapOrders: 2,
                priceDeviationPercent: 500,
                priceDeviationMultiplier: 20,
                swapOrderAmount: orderSizes[i],
                swapOrderMultiplier: 10
            });

            // Approve large amounts
            weth.approve(address(mock), 100 ether);
            usdc.approve(address(mock), 200_000 * 10 ** 6);

            uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
            uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

            // Simulate execution with different amounts
            uint256[] memory inputs = new uint256[](1);
            uint256[] memory outputs = new uint256[](1);
            inputs[0] = orderSizes[i];
            outputs[0] = orderSizes[i] * 1900; // Assuming 1 ETH = 1900 USDC

            mock.simulateExecution(id, expected / 2, 0, inputs, outputs);

            // Verify execution
            (,,,, uint256 executedAmount, uint256 claimableAmount,,,,,,) = mock.getDCAInfo(id);
            assertEq(executedAmount, orderSizes[i], "Incorrect executed amount");
            assertEq(claimableAmount, orderSizes[i] * 1900, "Incorrect claimable amount");
        }
    }

    function test_invalidInputParameters() public {
        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(weth), currency1: address(usdc), fee: 3000});

        // Test invalid take profit percent (> 5000)
        IDCADexterBotV1.DCAParams memory invalidTakeProfit = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 5001, // Invalid: > 5000
            maxSwapOrders: 4,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 10
        });

        vm.expectRevert(MockDCABot.InvalidTakeProfitPercent.selector);
        mock.createDCAStrategy{value: 1 ether}(poolParams, invalidTakeProfit, 100, block.timestamp + 1 hours);

        // Test invalid max swap orders (> 10)
        IDCADexterBotV1.DCAParams memory invalidMaxOrders = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 11, // Invalid: > 10
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 10
        });

        vm.expectRevert(MockDCABot.InvalidMaxSwapOrders.selector);
        mock.createDCAStrategy{value: 1 ether}(poolParams, invalidMaxOrders, 100, block.timestamp + 1 hours);

        // Test invalid price deviation (> 2000)
        IDCADexterBotV1.DCAParams memory invalidDeviation = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 4,
            priceDeviationPercent: 2001, // Invalid: > 2000
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 10
        });

        vm.expectRevert(MockDCABot.InvalidPriceDeviation.selector);
        mock.createDCAStrategy{value: 1 ether}(poolParams, invalidDeviation, 100, block.timestamp + 1 hours);

        // Test expired deadline
        IDCADexterBotV1.DCAParams memory validParams = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 4,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 10
        });

        vm.expectRevert(); // Should revert with ExpiredDeadline
        mock.createDCAStrategy{value: 1 ether}(poolParams, validParams, 100, block.timestamp - 1 hours);
    }

    function test_sellNowFunction() public {
        // Setup initial state
        weth.mint(address(this), 100 ether);
        usdc.mint(address(this), 200_000 * 10 ** 6);

        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(weth), currency1: address(usdc), fee: 3000});

        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 3,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 5 ether,
            swapOrderMultiplier: 10
        });

        // Create strategy and execute first level
        uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
        uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

        // Simulate some successful executions
        uint256[] memory inputs = new uint256[](2);
        uint256[] memory outputs = new uint256[](2);
        inputs[0] = 5 ether;
        inputs[1] = 5 ether;
        outputs[0] = 9500 * 10 ** 6;
        outputs[1] = 9500 * 10 ** 6;

        mock.simulateExecution(id, expected / 2, 0, inputs, outputs);

        // Get execution state before selling
        (,,,, uint256 executedAmount, uint256 claimableAmount,,,,,,) = mock.getDCAInfo(id);
        assertEq(executedAmount, 10 ether, "Should have executed 10 ETH");
        assertEq(claimableAmount, 19000 * 10 ** 6, "Should have 19000 USDC claimable");
    }

    function test_priceDeviationAndTicks() public {
        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(weth), currency1: address(usdc), fee: 3000});

        // Test different price deviations
        uint32[] memory deviations = new uint32[](3);
        deviations[0] = 500; // 5%
        deviations[1] = 1000; // 10%
        deviations[2] = 1500; // 15%

        for (uint256 i = 0; i < deviations.length; i++) {
            IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
                zeroForOne: true,
                takeProfitPercent: 1000,
                maxSwapOrders: 2,
                priceDeviationPercent: deviations[i],
                priceDeviationMultiplier: 20,
                swapOrderAmount: 1 ether,
                swapOrderMultiplier: 10
            });

            uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
            uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

            // Simulate execution with price impact
            uint256[] memory inputs = new uint256[](1);
            uint256[] memory outputs = new uint256[](1);
            inputs[0] = 1 ether;
            outputs[0] = uint256(1900 * (100 - deviations[i] / 100)) * 1e6 / 100; // Price impact based on deviation

            mock.simulateExecution(id, expected / 2, 0, inputs, outputs);

            (,,,, uint256 executedAmount, uint256 claimableAmount,,,,,,) = mock.getDCAInfo(id);
            console.log("Price Deviation:", deviations[i] / 100, "%");
            console.log("Executed Amount:", executedAmount / 1 ether, "ETH");
            console.log("Claimable Amount:", claimableAmount / 1e6, "USDC");
        }
    }

    function test_takeProfitMechanics() public {
        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(weth), currency1: address(usdc), fee: 3000});

        // Test different take-profit levels
        uint32[] memory takeProfitLevels = new uint32[](3);
        takeProfitLevels[0] = 500; // 5%
        takeProfitLevels[1] = 1000; // 10%
        takeProfitLevels[2] = 2000; // 20%

        for (uint256 i = 0; i < takeProfitLevels.length; i++) {
            IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
                zeroForOne: true,
                takeProfitPercent: takeProfitLevels[i],
                maxSwapOrders: 2,
                priceDeviationPercent: 500,
                priceDeviationMultiplier: 20,
                swapOrderAmount: 1 ether,
                swapOrderMultiplier: 10
            });

            uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
            uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

            // Simulate execution reaching take-profit level
            uint256[] memory inputs = new uint256[](1);
            uint256[] memory outputs = new uint256[](1);
            inputs[0] = 1 ether;
            // Calculate output with take-profit bonus
            outputs[0] = uint256(1900 * (100 + takeProfitLevels[i] / 100)) * 1e6 / 100;

            mock.simulateExecution(id, expected / 2, 0, inputs, outputs);

            (,,,, uint256 executedAmount, uint256 claimableAmount,, bool isFullyExecuted,,,,) = mock.getDCAInfo(id);
            console.log("Take Profit Level:", takeProfitLevels[i] / 100, "%");
            console.log("Executed Amount:", executedAmount / 1 ether, "ETH");
            console.log("Claimable Amount:", claimableAmount / 1e6, "USDC");
            assertTrue(isFullyExecuted, "Order should be fully executed at take-profit");
        }
    }

    function test_gasRefundScenarios() public {
        IDCADexterBotV1.PoolParams memory poolParams =
            IDCADexterBotV1.PoolParams({currency0: address(0), currency1: address(0), fee: 3000});

        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 2,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 10
        });

        uint256 expected = _calcExpectedGas(dca.maxSwapOrders);
        uint256 id = mock.createDCAStrategy{value: expected}(poolParams, dca, 100, block.timestamp + 1 hours);

        // Simulate using less gas than allocated
        uint256 actualGasUsed = expected / 2;
        uint256[] memory inputs = new uint256[](2);
        uint256[] memory outputs = new uint256[](2);
        inputs[0] = 1 ether;
        inputs[1] = 1 ether;
        outputs[0] = 0.95 ether;
        outputs[1] = 0.95 ether;

        mock.simulateExecution(id, actualGasUsed, 0, inputs, outputs);

        (,,,,,,,,,,,, uint256 gasAllocated, uint256 gasUsedRead,) = mock.getDCAInfoExtended(id);

        assertEq(gasAllocated, expected, "Gas allocated should match expected");
        assertEq(gasUsedRead, actualGasUsed, "Gas used should match actual usage");
        assertTrue(gasUsedRead < gasAllocated, "Should have unused gas");
    }
}
