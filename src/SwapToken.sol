// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ImmutableState} from "@uniswap/v4-periphery/base/ImmutableState.sol";

/**
 * @title SwapToken
 * @notice A V4-compatible swap router following Uniswap documentation patterns
 */
contract SwapToken is ImmutableState, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // Store the hook address
    address public immutable hookAddress;

    // Events for debugging
    event SwapExecuted(address indexed user, uint256 amountIn, uint256 amountOut);
    event Debug(string message, uint256 value);

    error TransferFailed();
    error InsufficientOutput();
    error InvalidToken();

    // Struct to hold swap data for the callback
    struct SwapCallbackData {
        address tokenIn;
        address tokenOut;
        address payer;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    constructor(address _poolManager, address _hookAddress) ImmutableState(IPoolManager(_poolManager)) {
        hookAddress = _hookAddress;
    }

    function swap(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external payable returns (BalanceDelta delta) {
        // Create the pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddress)
        });

        // For exact input (negative amountSpecified)
        if (amountSpecified < 0) {
            uint256 amountIn = uint256(-amountSpecified);
            _swapExactInputSingle(key, zeroForOne, amountIn, 0);
            return BalanceDelta.wrap(0); // Return empty delta, actual result handled internally
        } else {
            // For exact output, we'll implement a simpler version
            revert("Exact output not implemented");
        }
    }

    function _swapExactInputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        // Determine tokens
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address tokenOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        emit Debug("Starting swap", amountIn);
        emit Debug("Zero for one", zeroForOne ? 1 : 0);

        // Handle input token - for exact input swaps, we need the input upfront
        if (tokenIn == address(0)) {
            // Native ETH input
            require(msg.value >= amountIn, "Insufficient ETH sent");
        } else {
            // ERC20 token input
            require(msg.value == 0, "ETH sent with ERC20 swap");
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        // Set up swap parameters
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn), // Negative for exact input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Prepare callback data
        SwapCallbackData memory callbackData = SwapCallbackData({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            payer: msg.sender,
            amountIn: amountIn,
            minAmountOut: minAmountOut
        });

        // Execute swap through unlock - the actual swap happens in the callback
        BalanceDelta delta = abi.decode(
            poolManager.unlock(abi.encode(key, swapParams, callbackData)),
            (BalanceDelta)
        );

        // Calculate output amount from the returned delta
        if (zeroForOne) {
            // When selling token0 for token1, we expect positive amount1() (we receive token1)
            amountOut = uint256(uint128(delta.amount1()));
        } else {
            // When selling token1 for token0, we expect positive amount0() (we receive token0)
            amountOut = uint256(uint128(delta.amount0()));
        }
        
        require(amountOut >= minAmountOut, "Insufficient output amount");

        emit SwapExecuted(msg.sender, amountIn, amountOut);
        return amountOut;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager can call this");
        
        (PoolKey memory key, SwapParams memory swapParams, SwapCallbackData memory callbackData) = 
            abi.decode(data, (PoolKey, SwapParams, SwapCallbackData));
        
        emit Debug("Callback start", callbackData.amountIn);
        
        // Perform the actual swap - this is where the swap should happen
        BalanceDelta delta = poolManager.swap(key, swapParams, "");
        
        emit Debug("Swap executed, delta amounts", uint256(uint128(-delta.amount0())));
        
        // Settle what we owe to the pool (the input amount)
        if (delta.amount0() < 0) {
            Currency currency0 = key.currency0;
            uint256 amountToSettle = uint256(uint128(-delta.amount0()));
            _settle(currency0, amountToSettle);
        }
        if (delta.amount1() < 0) {
            Currency currency1 = key.currency1;
            uint256 amountToSettle = uint256(uint128(-delta.amount1()));
            _settle(currency1, amountToSettle);
        }
        
        // Take what we're owed from the pool (the output amount)
        if (delta.amount0() > 0) {
            Currency currency0 = key.currency0;
            uint256 amountToTake = uint256(uint128(delta.amount0()));
            _take(currency0, callbackData.payer, amountToTake);
        }
        if (delta.amount1() > 0) {
            Currency currency1 = key.currency1;
            uint256 amountToTake = uint256(uint128(delta.amount1()));
            _take(currency1, callbackData.payer, amountToTake);
        }
        
        return abi.encode(delta);
    }

    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        
        poolManager.sync(currency);
        
        if (currency.isAddressZero()) {
            // ETH settlement
            poolManager.settle{value: amount}();
        } else {
            // ERC20 settlement - we already have the tokens in this contract
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        
        poolManager.take(currency, recipient, amount);
    }

    // Allow contract to receive ETH
    receive() external payable {
        emit Debug("Received ETH", msg.value);
    }
}
