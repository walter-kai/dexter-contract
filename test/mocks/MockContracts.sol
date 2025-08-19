// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../src/interfaces/ILimitOrderBatch.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

// Mock ERC20 Token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        // Don't mint any tokens automatically - let tests mint what they need
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function mintToSelf(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}

// Mock SwapRouter for testing  
contract MockSwapRouter {
    using SafeERC20 for IERC20;
    
    uint256 public mockAmountOut = 1000e18; // Default mock amount out
    bool public shouldFail = false;
    
    function setMockAmountOut(uint256 _amountOut) external {
        mockAmountOut = _amountOut;
    }
    
    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }
    
    function exactInputSingle(
        bytes calldata /* params */
    ) external payable returns (uint256 amountOut) {
        // Mock implementation - just return a fixed amount
        return 100e18;
    }
    
    function swap(
        address currency0,
        address currency1,
        uint24 /* fee */,
        int24 /* tickSpacing */,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 /* sqrtPriceLimitX96 */
    ) external payable returns (BalanceDelta) {
        require(!shouldFail, "Mock swap failed");
        require(amountSpecified < 0, "Expected negative amountSpecified for exact input");
        
        uint256 amountIn = uint256(-amountSpecified);
        
        // Simulate actual token transfers like a real DEX would
        if (zeroForOne) {
            // Swapping currency0 for currency1
            if (currency0 == address(0)) {
                // Input is ETH - we should have received it with msg.value
                require(msg.value >= amountIn, "Insufficient ETH sent");
            } else {
                // Input is ERC20 - transfer from sender to this contract
                IERC20(currency0).transferFrom(msg.sender, address(this), amountIn);
            }
            
            // Output currency1 to sender
            if (currency1 == address(0)) {
                // Output is ETH
                (bool success,) = msg.sender.call{value: mockAmountOut}("");
                require(success, "ETH transfer failed");
            } else {
                // Output is ERC20 - we need to have it in our balance first
                // For testing, we'll mint tokens if we don't have enough
                MockERC20 tokenOut = MockERC20(currency1);
                if (tokenOut.balanceOf(address(this)) < mockAmountOut) {
                    // This is a hack for testing - real DEX would have liquidity
                    tokenOut.mint(address(this), mockAmountOut);
                }
                tokenOut.transfer(msg.sender, mockAmountOut);
            }
            
            // Return proper deltas
            int128 amount0Delta = int128(int256(amountIn));  // Positive for input
            int128 amount1Delta = -int128(int256(mockAmountOut)); // Negative for output
            return toBalanceDelta(amount0Delta, amount1Delta);
        } else {
            // Swapping currency1 for currency0
            if (currency1 == address(0)) {
                // Input is ETH
                require(msg.value >= amountIn, "Insufficient ETH sent");
            } else {
                // Input is ERC20
                IERC20(currency1).transferFrom(msg.sender, address(this), amountIn);
            }
            
            // Output currency0 to sender
            if (currency0 == address(0)) {
                // Output is ETH
                (bool success,) = msg.sender.call{value: mockAmountOut}("");
                require(success, "ETH transfer failed");
            } else {
                // Output is ERC20
                MockERC20 tokenOut = MockERC20(currency0);
                if (tokenOut.balanceOf(address(this)) < mockAmountOut) {
                    tokenOut.mint(address(this), mockAmountOut);
                }
                tokenOut.transfer(msg.sender, mockAmountOut);
            }
            
            // Return proper deltas  
            int128 amount0Delta = -int128(int256(mockAmountOut)); // Negative for output
            int128 amount1Delta = int128(int256(amountIn));  // Positive for input
            return toBalanceDelta(amount0Delta, amount1Delta);
        }
    }
    
    receive() external payable {}
}

// Mock PoolManager for testing
contract MockPoolManager {
    uint256 private mockPrice = 1; // Default mock price
    uint256 private mockAmountOut; // Dynamic mock output amount
    bool public shouldFail = false;
    
    // Add support for setting current tick per pool
    mapping(bytes32 => int24) private currentTicks;
    
    // Mock timestamp for testing timeout functionality
    uint256 private mockTimestamp;

    constructor() {
        // Set network-appropriate mock output amounts
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            // Mainnet (including Anvil forked from mainnet): Use large amounts for testing
            mockAmountOut = 200e18;
        } else if (chainId == 11155111) {
            // Sepolia: Use moderate amounts 
            mockAmountOut = 2e17; // 0.2 tokens
        } else {
            // Unknown network: Use conservative amounts
            mockAmountOut = 2e16; // 0.02 tokens
        }
    }

    function setMockPrice(uint256 price) external {
        mockPrice = price;
    }

    function setMockAmountOut(uint256 amount) external {
        mockAmountOut = amount;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }
    
    // Add function to set current tick for testing
    function setCurrentTick(bytes32 poolId, int24 tick) external {
        currentTicks[poolId] = tick;
        // Update the pool state for StateLibrary compatibility
        _updatePoolState(poolId, uint160(mockPrice), tick, 0, 0);
    }
    
    // Add function to set block timestamp for testing timeout functionality
    function setBlockTimestamp(uint256 timestamp) external {
        mockTimestamp = timestamp;
    }
    
    // Override block.timestamp when mock timestamp is set
    function getBlockTimestamp() public view returns (uint256) {
        return mockTimestamp > 0 ? mockTimestamp : block.timestamp;
    }

    // Debug variables
    bytes32 public lastQueriedPoolId;
    int24 public lastReturnedTick;
    
    function getSlot0(
        bytes32 poolId
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint8) {
        // Simple mock implementation
        sqrtPriceX96 = uint160(mockPrice);
        tick = currentTicks[poolId]; // Return the set tick for this pool
        
        // Store debug info in state (this is not ideal for view functions, but for testing...)
        // We'll use a getter to check these values
        
        return (sqrtPriceX96, tick, 0, 0); // Return 4 values as expected by IPoolManager
    }
    
    // Debug getter to see what getSlot0 would return for a pool
    function debugGetSlot0(bytes32 poolId) external returns (uint160, int24, uint16, uint8) {
        lastQueriedPoolId = poolId;
        int24 tick = currentTicks[poolId];
        lastReturnedTick = tick;
        return (uint160(mockPrice), tick, 0, 0);
    }
    
    // Storage for pool states to support StateLibrary.getSlot0
    mapping(bytes32 => bytes32) private poolStates;
    
    // Mock extsload function to support StateLibrary.getSlot0
    function extsload(bytes32 slot) external view returns (bytes32) {
        // Check if this is a pool state slot we've stored
        bytes32 data = poolStates[slot];
        if (data != bytes32(0)) {
            return data;
        }
        
        // Default to returning zero for unknown slots
        return bytes32(0);
    }
    
    // Helper function to update pool state for StateLibrary compatibility
    function _updatePoolState(bytes32 poolId, uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) internal {
        // Calculate the storage slot that StateLibrary expects
        // This matches: keccak256(abi.encodePacked(poolId, POOLS_SLOT))
        // where POOLS_SLOT = bytes32(uint256(6))
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        
        // Pack data according to StateLibrary.getSlot0 format:
        // bits 0-159: sqrtPriceX96
        // bits 160-183: tick (signed, 24 bits)
        // bits 184-207: protocolFee (24 bits)  
        // bits 208-231: lpFee (24 bits)
        bytes32 packedData = bytes32(
            uint256(sqrtPriceX96) |
            (uint256(uint24(int24(tick))) << 160) |
            (uint256(protocolFee) << 184) |
            (uint256(lpFee) << 208)
        );
        
        poolStates[stateSlot] = packedData;
    }

    // Mock unlock function that calls back to the LimitOrderBatch
    function unlock(bytes calldata data) external returns (bytes memory) {
        require(!shouldFail, "Mock unlock failed");
        
        // Call back directly like the real PoolManager does
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    // Mock swap function for the callback
    function swap(
        PoolKey memory /* poolKey */,
        SwapParams memory swapParams,
        bytes memory /* hookData */
    ) external returns (BalanceDelta) {
        require(!shouldFail, "Mock swap failed");
        require(swapParams.amountSpecified < 0, "Expected negative amountSpecified for exact input");
        
        uint256 amountIn = uint256(-swapParams.amountSpecified);
        
        emit Debug("DEBUG: MockPoolManager swap - amountIn", amountIn);
        emit Debug("DEBUG: MockPoolManager swap - mockAmountOut", mockAmountOut);
        emit Debug("DEBUG: MockPoolManager swap - zeroForOne", swapParams.zeroForOne ? 1 : 0);
        
        // Return proper deltas for a successful swap
        if (swapParams.zeroForOne) {
            // amount0 is positive (input), amount1 is negative (output)
            int128 amount0Delta = int128(int256(amountIn));
            int128 amount1Delta = -int128(int256(mockAmountOut));
            emit Debug("DEBUG: MockPoolManager swap - amount0Delta", uint256(uint128(amount0Delta)));
            emit Debug("DEBUG: MockPoolManager swap - amount1Delta", uint256(uint128(-amount1Delta)));
            return toBalanceDelta(amount0Delta, amount1Delta);
        } else {
            // amount1 is positive (input), amount0 is negative (output)
            int128 amount0Delta = -int128(int256(mockAmountOut));
            int128 amount1Delta = int128(int256(amountIn));
            emit Debug("DEBUG: MockPoolManager swap - amount0Delta", uint256(uint128(-amount0Delta)));
            emit Debug("DEBUG: MockPoolManager swap - amount1Delta (negative)", uint256(uint128(amount1Delta)));
            
            // Debug the actual BalanceDelta created
            BalanceDelta result = toBalanceDelta(amount0Delta, amount1Delta);
            emit Debug("DEBUG: BalanceDelta amount0", uint256(result.amount0() < 0 ? uint128(-result.amount0()) : uint128(result.amount0())));
            emit Debug("DEBUG: BalanceDelta amount0 sign", result.amount0() < 0 ? 0 : 1);
            emit Debug("DEBUG: BalanceDelta amount1", uint256(result.amount1() < 0 ? uint128(-result.amount1()) : uint128(result.amount1())));
            emit Debug("DEBUG: BalanceDelta amount1 sign", result.amount1() < 0 ? 0 : 1);
            
            return result;
        }
    }

    // Mock settle function - matches IPoolManager interface
    function settle() external payable returns (uint256) {
        // For testing purposes, assume settlement is successful
        emit Debug("DEBUG: MockPoolManager settle called", msg.value);
        return msg.value;
    }
    
    // Mock sync function - matches IPoolManager interface
    function sync(Currency currency) external {
        emit Debug("DEBUG: MockPoolManager sync called", uint256(uint160(Currency.unwrap(currency))));
        // For testing, sync is a no-op - just emit debug event
    }
    
    // Mock take function - matches IPoolManager interface
    function take(Currency currency, address to, uint256 amount) external {
        emit Debug("DEBUG: MockPoolManager take called", amount);
        
        if (Currency.unwrap(currency) == address(0)) {
            // Taking ETH
            (bool success,) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Taking ERC20
            MockERC20 token = MockERC20(Currency.unwrap(currency));
            if (token.balanceOf(address(this)) < amount) {
                token.mint(address(this), amount);
            }
            token.transfer(to, amount);
        }
    }

    // Mock validateHookAddress function - for testing hooks
    function validateHookAddress(address /* hookAddress */, bytes calldata /* permissions */) external pure {
        // In testing, we always allow hook addresses (no validation)
        return;
    }

    // Mock getLiquidity function - needed for pool validation
    function getLiquidity(bytes32 /* poolId */) external view returns (uint128) {
        // Return a mock liquidity value for testing
        return 1000000e18; // 1M units of liquidity
    }

    event Debug(string message, uint256 value);

    // Add any other functions needed for pool interaction
    function initialize(PoolKey memory /* key */, uint160 /* sqrtPriceX96 */) external returns (int24 tick) {
        // Mock implementation - just return a default tick
        return 0;
    }

    receive() external payable {}
}

// Test storage manipulation utilities
contract StorageManipulator is Test {
    /// @dev Sets the balance of an account for any ERC20 token by manipulating storage
    function setBalance(address token, address account, uint256 amount) external {
        // Standard ERC20 balance is typically at slot 0, with mapping(address => uint256) 
        // The storage slot for balances[account] = keccak256(abi.encode(account, 0))
        bytes32 slot = keccak256(abi.encode(account, uint256(0)));
        vm.store(token, slot, bytes32(amount));
    }
    
    /// @dev Sets arbitrary storage slot to a value
    function setStorageAt(address target, bytes32 slot, bytes32 value) external {
        vm.store(target, slot, value);
    }
}
