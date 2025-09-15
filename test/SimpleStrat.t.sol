// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/interfaces/IDCADexterBotV1.sol";

// A small mock of the DCADexterBotV1 interface to simulate behavior for unit tests.
contract MockDCABot {
    using stdMath for uint256;

    struct Order {
        address user;
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
    function createDCAStrategy(
        IDCADexterBotV1.PoolParams calldata,
        IDCADexterBotV1.DCAParams calldata dca,
        uint32,
        uint256 expirationTime
    ) external payable returns (uint256 dcaId) {
        dcaId = nextId++;
        Order storage o = orders[dcaId];
        o.user = msg.sender;
        o.totalAmount = dca.swapOrderAmount * (dca.maxSwapOrders + 1);
        o.executedAmount = 0;
        o.claimableAmount = 0;
        o.status = IDCADexterBotV1.OrderStatus.ACTIVE;
        o.isFullyExecuted = false;
        o.expirationTime = expirationTime;
        o.zeroForOne = dca.zeroForOne;
        o.totalBatches = dca.maxSwapOrders;
        o.currentFee = 3000;

        o.gasAllocated = msg.value;
        o.gasUsed = 0;
        o.gasBorrowedFromTank = 0;
    }

    // allow test to simulate execution
    function simulateExecution(uint256 dcaId, uint256 gasUsed, uint256 gasBorrowed, uint256[] calldata inputs, uint256[] calldata outputs) external {
        Order storage o = orders[dcaId];
        require(o.user != address(0), "unknown dca");
        o.gasUsed = gasUsed;
        o.gasBorrowedFromTank = gasBorrowed;
        o.inputs = inputs;
        o.outputs = outputs;

        uint256 sumIn = 0;
        uint256 sumOut = 0;
        for (uint256 i = 0; i < inputs.length; i++) sumIn += inputs[i];
        for (uint256 i = 0; i < outputs.length; i++) sumOut += outputs[i];

        o.executedAmount = sumIn;
        o.claimableAmount = sumOut;
        o.isFullyExecuted = true;
        o.status = IDCADexterBotV1.OrderStatus.COMPLETED;
    }

    function getDCAInfo(uint256 dcaId) external view returns (
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
    ) {
        Order storage o = orders[dcaId];
        return (o.user, address(0), address(0), o.totalAmount, o.executedAmount, o.claimableAmount, o.status, o.isFullyExecuted, o.expirationTime, o.zeroForOne, o.totalBatches, o.currentFee);
    }

    function getDCAInfoExtended(uint256 dcaId) external view returns (
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
    ) {
        Order storage o = orders[dcaId];
        return (o.user, address(0), address(0), o.totalAmount, o.executedAmount, o.claimableAmount, o.status, o.isFullyExecuted, o.expirationTime, o.zeroForOne, o.totalBatches, o.currentFee, o.gasAllocated, o.gasUsed, o.gasBorrowedFromTank);
    }

    function getDCAOrder(uint256 dcaId) external view returns (
        address user,
        address currency0,
        address currency1,
        uint256 totalAmount,
        uint256 executedAmount,
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        IDCADexterBotV1.OrderStatus status,
        bool isFullyExecuted
    ) {
        Order storage o = orders[dcaId];
        return (o.user, address(0), address(0), o.totalAmount, o.executedAmount, new uint256[](0), new uint256[](0), o.status, o.isFullyExecuted);
    }
}

contract SimpleStrat is Test {
    MockDCABot public mock;

    function setUp() public {
        mock = new MockDCABot();
        // deterministic gas price
        vm.txGasPrice(1 gwei);
        vm.deal(address(this), 10 ether);
    }

    receive() external payable {}

    function _calcExpectedGas(uint8 maxSwapOrders) internal view returns (uint256) {
        uint256 gasBase = 150000 * tx.gasprice;
        return (gasBase * (2 + maxSwapOrders) * 120) / 100;
    }

    function test_multiOrderGasAccounting_and_receipt() public {
        IDCADexterBotV1.PoolParams memory poolParams = IDCADexterBotV1.PoolParams({
            currency0: address(0),
            currency1: address(0),
            fee: 3000
        });

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
        inputs[0] = 1 ether; inputs[1] = 2 ether; inputs[2] = 3 ether;
        outputs[0] = 0.9 ether; outputs[1] = 1.8 ether; outputs[2] = 2.7 ether;

    // call simulateExecution
    mock.simulateExecution(id, gasUsed, gasBorrowed, inputs, outputs);

        (, , , uint256 totalAmount, uint256 executedAmount, uint256 claimableAmount, , bool isFullyExecuted, , , uint256 totalBatches, uint24 fee) = mock.getDCAInfo(id);
        (, , , , , , , , , , , , uint256 gasAllocated, uint256 gasUsedRead, uint256 gasBorrowedRead) = mock.getDCAInfoExtended(id);

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
        IDCADexterBotV1.PoolParams memory poolParams = IDCADexterBotV1.PoolParams({
            currency0: address(0),
            currency1: address(0),
            fee: 3000
        });

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
        inputs[0] = 2 ether; inputs[1] = 2 ether;
        outputs[0] = 1.9 ether; outputs[1] = 1.9 ether;

    mock.simulateExecution(id, gasUsed, gasBorrowed, inputs, outputs);

        (, , , , , , , , , , , , uint256 gasAllocated, uint256 gasUsedRead, uint256 gasBorrowedRead) = mock.getDCAInfoExtended(id);

        // Assertions: gasBorrowed should be > 0 and reflect the difference
        assertTrue(gasBorrowedRead > 0, "gasBorrowed should be > 0");
        assertEq(gasAllocated, provided, "gas allocated should match what was provided");
        assertEq(gasUsedRead, gasUsed, "gas used should equal simulated usage");

        console.log("Borrowed (wei):", gasBorrowedRead);
    }
}


