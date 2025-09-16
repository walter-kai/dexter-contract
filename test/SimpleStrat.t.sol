// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/DCADexterBotV1.sol";
import "@uniswap/v4-core/src/PoolManager.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-periphery/utils/BaseHook.sol";
import "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Test-only subclass that overrides validateHookAddress to skip the address-bit validation
contract TestDCABot is DCADexterBotV1 {
    constructor(IPoolManager _poolManager, address feeRecipient, address executor) DCADexterBotV1(_poolManager, feeRecipient, executor) {}

    // Override BaseHook.validateHookAddress via a shadowed function with same name/signature as BaseHook
    // BaseHook.validateHookAddress is internal and virtual; override by creating our own internal implementation
    function validateHookAddress(BaseHook _this) internal pure override {
        // no-op in tests to allow deployment at any address
    }

    // expose underlying library validation for debugging
    function checkValid(uint24 fee) external view returns (bool) {
        return Hooks.isValidHookAddress(IHooks(address(this)), fee);
    }
}

contract SimpleStratTest is Test {
    PoolManager poolManager;
    TestDCABot bot;

    address owner = address(0xBEEF);

    function setUp() public {
        vm.deal(address(this), 10 ether);
        // deploy PoolManager with an arbitrary owner
        poolManager = new PoolManager(address(this));

        // deploy the test bot, skipping address validation but ensure its address low bits match expected hook permissions
        Deployer deployer = new Deployer();

        bytes memory initCode = abi.encodePacked(type(TestDCABot).creationCode, abi.encode(IPoolManager(address(poolManager)), address(0x1111), address(this)));
        bytes32 initHash = keccak256(initCode);

        // target bits for permissions: beforeInit + afterInit + beforeSwap + afterSwap
        uint160 targetBits = uint160((1 << 13) | (1 << 12) | (1 << 7) | (1 << 6)); // 8192+4096+128+64 = 12480
        uint160 forbiddenReturnBits = uint160((1 << 3) | (1 << 2) | (1 << 1) | (1 << 0)); // return-delta flags must be off

        address deployedAddr = address(0);
        for (uint256 salt = 0; salt < 5000; salt++) {
            address predicted = deployer.computeAddress(initHash, salt);
            uint160 lowbits = uint160(uint160(predicted) & ((uint160(1) << 14) - 1));
            if ((lowbits & targetBits) == targetBits && (lowbits & forbiddenReturnBits) == 0) {
                deployedAddr = deployer.deploy(initCode, salt);
                break;
            }
        }
        if (deployedAddr == address(0)) revert("Could not find suitable salt for hook address; increase search range");
        bot = TestDCABot(payable(deployedAddr));

        // set deterministic gas price
        vm.txGasPrice(1 gwei);
    }

    function test_createStrategyAllocatesGas() public {
        // use dynamic-fee sentinel so the hooks address is accepted regardless of low bits
        uint24 dynamicFee = uint24(0x800000);
        IDCADexterBotV1.PoolParams memory poolParams = IDCADexterBotV1.PoolParams({
            currency0: address(0),
            currency1: address(0x2),
            fee: dynamicFee
        });

        IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
            zeroForOne: true,
            takeProfitPercent: 1000,
            maxSwapOrders: 3,
            priceDeviationPercent: 500,
            priceDeviationMultiplier: 20,
            swapOrderAmount: 1 ether,
            swapOrderMultiplier: 10
        });

        uint256 gasBase = 150000 * tx.gasprice;
        uint256 expected = (gasBase * (2 + dca.maxSwapOrders) * 120) / 100;

        // initialize a pool key that points to our bot as hooks
        // use two distinct placeholder addresses (must be currency0 < currency1)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0x2)),
            fee: dynamicFee,
            tickSpacing: int24(60),
            hooks: IHooks(address(bot))
        });

    // debug: check Hooks.isValidHookAddress for our bot and dynamic fee
    bool ok = bot.checkValid(dynamicFee);
    uint160 mask = (uint160(1) << 14) - 1;
    uint160 lowbits = uint160(uint160(address(bot)) & mask);
    console.log("bot.addr lowbits:", uint256(lowbits));
    console.log("fee.isDynamic (expected 1):", uint256(uint24(dynamicFee) == uint24(0x800000) ? 1 : 0));
    console.log("bot.checkValid(dynamicFee)", ok ? 1 : 0);

    // initialize pool with a non-zero sqrtPrice to avoid _ensurePoolInitialized revert
    uint160 sqrtPriceX96 = uint160(1 << 96);
    poolManager.initialize(key, sqrtPriceX96);

    // compute expected totalAmount for initial level: base + first target amount
    uint256 baseSwap = dca.swapOrderAmount;
    uint256 amountLevelMultiplier = dca.swapOrderMultiplier; // per contract math this is scaled by 10
    uint256 target0 = (baseSwap * amountLevelMultiplier) / 10;
    uint256 totalAmount = baseSwap + target0;

    // send ETH = totalAmount + gasAllocation (as expected by _handleTokenDeposit for ETH sell)
    uint256 valueToSend = expected + totalAmount;
    uint256 dcaId = bot.createDCAStrategy{value: valueToSend}(poolParams, dca, 100, block.timestamp + 1 hours);

        (, , , , , , , , , , , , uint256 gasAllocated, , ) = bot.getDCAInfoExtended(dcaId);

        assertEq(gasAllocated, expected, "gas allocated should equal expected");

        console.log("expected gas", expected);
        console.log("allocated gas", gasAllocated);
    }
}

/// @notice Tiny CREATE2 deployer used in tests
contract Deployer {
    function deploy(bytes memory initCode, uint256 salt) external returns (address addr) {
        bytes32 _salt = bytes32(salt);
        assembly {
            addr := create2(0, add(initCode, 0x20), mload(initCode), _salt)
        }
        require(addr != address(0), "CREATE2_FAILED");
    }

    function computeAddress(bytes32 initHash, uint256 salt) external view returns (address) {
        // per EIP-1014: address = keccak256(0xff ++ address ++ salt ++ keccak256(init_code))[12:]
        bytes32 data = keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initHash));
        return address(uint160(uint256(data)));
    }
}
