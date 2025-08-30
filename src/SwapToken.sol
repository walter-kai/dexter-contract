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
 * @notice A simplified swap router that properly handles ETH transfers
 */
contract SwapToken is ImmutableState, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // Debug events
    event Debug(string message, uint256 value);
    event ETHBalanceCheck(string stage, uint256 balance);
    event ETHTransferAttempt(address to, uint256 amount, bool success);

    error TransferFailed();
    error InsufficientETH();
    error InvalidToken();

    // Struct to hold swap data for the callback
    struct SwapData {
        PoolKey key;
        SwapParams params;
        address sender;
        bool isETHOutput;
    }

    constructor(address _poolManager) ImmutableState(IPoolManager(_poolManager)) {}

    function swap(
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external payable returns (BalanceDelta delta) {
        require(amountSpecified != 0, "Amount must not be zero");
        
        // Determine tokens
        address tokenIn = zeroForOne ? currency0 : currency1;
        address tokenOut = zeroForOne ? currency1 : currency0;
        bool isETHOutput = (tokenOut == address(0));
        
        emit Debug("Starting swap", amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified));
        emit Debug("Is ETH output", isETHOutput ? 1 : 0);
        
        // Handle input token transfers for exact input (negative amountSpecified)
        // Note: Transfers will happen during settlement, so we don't pre-transfer here
        if (amountSpecified < 0) {
            uint256 amountIn = uint256(-amountSpecified);
            
            if (tokenIn == address(0)) {
                // Native ETH input
                require(msg.value >= amountIn, "Insufficient ETH sent");
            } else {
                // ERC20 token input - verify allowance but don't transfer yet
                require(msg.value == 0, "ETH sent with ERC20 swap");
                emit Debug("ERC20 swap amount", amountIn);
            }
        }

        // Construct PoolKey - use the LimitOrderBatch hook address
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(0xB8308CaE46C322a4aECd7FC84C601f59e5A8B0C4)
        });

        // Try to initialize the pool if it's not already initialized
        // We'll attempt initialization and catch any reverts
        try poolManager.initialize(key, 1447439070190732076203095993308308) {
            emit Debug("Pool initialized successfully", 1447439070190732076203095993308308);
        } catch {
            // Pool is already initialized or initialization failed, continue with swap
            emit Debug("Pool already initialized or init failed", 0);
        }

        // Set proper price limit if none provided
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        // Prepare swap params
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        // Prepare swap data for callback
        SwapData memory swapData = SwapData({
            key: key,
            params: params,
            sender: msg.sender,
            isETHOutput: isETHOutput
        });

        emit ETHBalanceCheck("Before unlock", address(this).balance);

        // Perform the swap through unlock mechanism
        delta = abi.decode(poolManager.unlock(abi.encode(swapData)), (BalanceDelta));
        
        emit ETHBalanceCheck("After unlock", address(this).balance);
        emit Debug("Delta amount0", delta.amount0() >= 0 ? uint256(uint128(delta.amount0())) : uint256(uint128(-delta.amount0())));
        emit Debug("Delta amount1", delta.amount1() >= 0 ? uint256(uint128(delta.amount1())) : uint256(uint128(-delta.amount1())));
        
        return delta;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager can call this");
        
        SwapData memory swapData = abi.decode(data, (SwapData));
        
        emit ETHBalanceCheck("Callback start", address(this).balance);
        
        // Store initial ETH balance if output is ETH
        uint256 initialETHBalance = 0;
        if (swapData.isETHOutput) {
            initialETHBalance = address(this).balance;
            emit Debug("Initial ETH balance tracked", initialETHBalance);
        }
        
        // Perform the actual swap
        BalanceDelta delta = poolManager.swap(swapData.key, swapData.params, "");
        
        emit ETHBalanceCheck("After pool swap", address(this).balance);
        emit Debug("Swap delta amount0", delta.amount0() >= 0 ? uint256(uint128(delta.amount0())) : uint256(uint128(-delta.amount0())));
        emit Debug("Swap delta amount1", delta.amount1() >= 0 ? uint256(uint128(delta.amount1())) : uint256(uint128(-delta.amount1())));
        
        // Handle settling (paying what we owe)
        if (delta.amount0() < 0) {
            // We owe currency0 to the pool
            uint256 amount = uint256(uint128(-delta.amount0()));
            emit Debug("Settling currency0", amount);
            _settle(swapData.key.currency0, swapData.sender, amount);
        }
        if (delta.amount1() < 0) {
            // We owe currency1 to the pool
            uint256 amount = uint256(uint128(-delta.amount1()));
            emit Debug("Settling currency1", amount);
            _settle(swapData.key.currency1, swapData.sender, amount);
        }
        
        emit ETHBalanceCheck("After settle", address(this).balance);
        
        // Handle taking (receiving what we're owed) - take to this contract first
        if (delta.amount0() > 0) {
            // We get currency0 from the pool
            uint256 amount = uint256(uint128(delta.amount0()));
            emit Debug("Taking currency0", amount);
            _take(swapData.key.currency0, address(this), amount);
        }
        if (delta.amount1() > 0) {
            // We get currency1 from the pool
            uint256 amount = uint256(uint128(delta.amount1()));
            emit Debug("Taking currency1", amount);
            _take(swapData.key.currency1, address(this), amount);
        }
        
        emit ETHBalanceCheck("After take", address(this).balance);
        
        // Transfer output tokens to user
        if (swapData.isETHOutput) {
            // Calculate how much ETH we received
            uint256 currentETHBalance = address(this).balance;
            uint256 ethReceived = currentETHBalance > initialETHBalance ? 
                currentETHBalance - initialETHBalance : 0;
            
            emit Debug("Current ETH balance", currentETHBalance);
            emit Debug("ETH received calculation", ethReceived);
            
            if (ethReceived > 0) {
                // Transfer ETH directly to user
                emit Debug("Attempting ETH transfer", ethReceived);
                (bool success, ) = swapData.sender.call{value: ethReceived}("");
                emit ETHTransferAttempt(swapData.sender, ethReceived, success);
                require(success, "ETH transfer failed");
            } else {
                emit Debug("No ETH to transfer", 0);
            }
        } else {
            // Transfer ERC20 tokens to user
            address tokenOut = swapData.params.zeroForOne ? 
                Currency.unwrap(swapData.key.currency1) : 
                Currency.unwrap(swapData.key.currency0);
                
            if (tokenOut != address(0)) {
                IERC20 token = IERC20(tokenOut);
                uint256 balance = token.balanceOf(address(this));
                if (balance > 0) {
                    token.safeTransfer(swapData.sender, balance);
                }
            }
        }
        
        emit ETHBalanceCheck("Callback end", address(this).balance);
        
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;

        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            // ETH settlement
            emit Debug("Settling ETH", amount);
            poolManager.settle{value: amount}();
        } else {
            // ERC20 settlement - transfer from payer to PoolManager
            emit Debug("Settling ERC20", amount);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        emit Debug("Taking currency", amount);
        emit Debug("Taking to address", uint256(uint160(recipient)));
        poolManager.take(currency, recipient, amount);
    }

    // Allow contract to receive ETH
    receive() external payable {
        emit Debug("Received ETH", msg.value);
    }
}
