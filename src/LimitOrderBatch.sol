// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILimitOrderBatch} from "./interfaces/ILimitOrderBatch.sol";
import {ERC6909Base} from "./base/ERC6909Base.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FixedPointMathLib} from "@uniswap/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/**
 * @title LimitOrderBatch - TakeProfitsHook Pattern with ERC6909
 * @notice Batch limit order system following TakeProfitsHook design but with batching
 * @dev Uses tick-based storage like TakeProfitsHook but groups orders in batches
 * @dev ERC6909 tokens represent claims on output tokens from executed orders
 */
contract LimitOrderBatch is ILimitOrderBatch, ERC6909Base, BaseHook, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;
    using LPFeeLibrary for uint24;

    // Storage following TakeProfitsHook pattern
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
    
    // Batch orders mapped by tick and direction like TakeProfitsHook
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => uint256 inputAmount)))
        public pendingBatchOrders;
    
    // Track claimable output tokens per batch order ID (ERC6909 token ID)
    mapping(uint256 batchOrderId => uint256 outputClaimable) public claimableOutputTokens;
    
    // Track total supply of claim tokens for each batch order
    mapping(uint256 batchOrderId => uint256 claimsSupply) public claimTokensSupply;
    
    // Efficient mapping from pool+tick+direction to batch IDs for quick lookup
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => uint256[] batchIds)))
        private tickToBatchIds;
    
    // Additional batch tracking
    struct BatchOrderInfo {
        address user;
        PoolKey poolKey;
        int24[] targetTicks;        // Multiple ticks for batch execution
        uint256[] targetAmounts;    // Amount per tick
        bool zeroForOne;
        uint256 totalAmount;
        uint256 expirationTime;
        bool isActive;
        // MEV Protection fields (simplified)
        uint256 maxSlippageBps;     // Maximum slippage in basis points
        uint256 minOutputAmount;    // Minimum acceptable output
        uint256 creationBlock;      // Block when order was created
        uint256 bestPriceTimeout;  // Seconds to wait for better price, 0 = disabled
    }
    
    mapping(uint256 => BatchOrderInfo) public batchOrdersInfo;
    uint256 public nextBatchOrderId = 1;

    // Pool tracking for Option 1 implementation
    mapping(PoolId => bool) public poolInitialized;
    mapping(PoolId => uint256) public poolInitializationBlock;

    // Best price execution queue structures
    struct QueuedOrder {
        uint256 batchOrderId;
        int24 originalTick;
        int24 targetTick;        // Tick we're waiting for (better price)
        uint256 amount;
        uint256 queueTime;
        uint256 maxWaitTime;     // Timeout after this timestamp
        bool zeroForOne;
    }

    // Queue storage
    mapping(PoolId => QueuedOrder[]) public bestPriceQueue;
    mapping(PoolId => uint256) public queueIndex; // Current processing index

    // Configuration
    int24 public constant BEST_EXECUTION_TICKS = 1; // Wait for 1 tick better execution

    // MEV Protection Configuration (simplified)
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5% maximum slippage protection

    // Gas price-based fee calculation (following GasPriceFeesHook pattern)
    uint128 public movingAverageGasPrice;
    uint104 public movingAverageGasPriceCount;
    uint24 public constant BASE_FEE = 3000; // 0.3% base fee in hundredths of bps
    
    // Errors following TakeProfitsHook pattern
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    error MustUseDynamicFee();
    error InvalidCommitment();
    error CommitmentExpired();
    error SlippageExceeded();
    error ExecutionDelayNotMet();
    
    // Fee configuration
    address public immutable FEE_RECIPIENT;
    uint256 public constant FEE_BASIS_POINTS = 30; // 0.3% fee
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not contract owner");
        _;
    }

    constructor(IPoolManager _poolManager, address _feeRecipient) 
        BaseHook(_poolManager) 
    {
        require(_feeRecipient != address(0), "Fee recipient cannot be zero address");
        owner = msg.sender;
        FEE_RECIPIENT = _feeRecipient;
    }

    /**
     * @notice Calculate dynamic fee based on current gas price
     * @return fee The calculated fee in hundredths of basis points
     */
    function getDynamicFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);

        // If no gas price history, return base fee
        if (movingAverageGasPriceCount == 0) {
            return BASE_FEE;
        }

        // if gasPrice > movingAverageGasPrice * 1.1, then halve the fees (encourage trading during high gas)
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEE / 2;
        }

        // if gasPrice < movingAverageGasPrice * 0.9, then double the fees (discourage trading during low gas)
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEE * 2;
        }

        return BASE_FEE;
    }

    /**
     * @notice Update moving average gas price
     */
    function updateMovingAverageGasPrice() internal {
        uint128 gasPrice = uint128(tx.gasprice);

        // New Average = ((Old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) /
            (movingAverageGasPriceCount + 1);

        movingAverageGasPriceCount++;

        // Emit event for tracking
        emit GasPriceTracked(gasPrice, movingAverageGasPrice, movingAverageGasPriceCount);
    }

    /**
     * @notice Create batch order with MEV protection via deadline and slippage protection
     * @param currency0 First token address
     * @param currency1 Second token address  
     * @param fee Pool fee tier
     * @param zeroForOne Direction of swap
     * @param targetPrices Array of target prices for batch levels
     * @param targetAmounts Array of amounts for each price level
     * @param deadline Timestamp after which order creation will revert (MEV protection)
     * @param maxSlippageBps Maximum slippage in basis points (500 = 5%)
     * @param minOutputAmount Minimum total output expected
     * @param bestPriceTimeout Seconds to wait for better execution price (0 = disabled)
     */
    function createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint256 deadline,
        uint256 maxSlippageBps,
        uint256 minOutputAmount,
        uint256 bestPriceTimeout
    ) external payable returns (uint256 batchId) {
        // MEV Protection: Deadline enforcement
        require(block.timestamp <= deadline, "Order creation deadline exceeded");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        
        return _createBatchOrder(
            currency0, currency1, fee, zeroForOne,
            targetPrices, targetAmounts, deadline,
            maxSlippageBps, minOutputAmount, bestPriceTimeout
        );
    }

    /**
     * @notice Internal function to create batch orders with MEV protection
     */
    function _createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint256 deadline,
        uint256 maxSlippageBps,
        uint256 minOutputAmount,
        uint256 bestPriceTimeout
    ) internal returns (uint256 batchId) {
        // Input validation
        require(targetPrices.length == targetAmounts.length, "Array length mismatch");
        require(targetPrices.length > 0, "Empty order arrays");
        require(targetPrices.length <= 10, "Invalid price levels");
        require(deadline > block.timestamp, "Invalid deadline");
        require(currency0 != address(0) && currency1 != address(0), "Invalid token address");
        require(currency0 != currency1, "Same token addresses");
        
        // Validate amounts are not zero
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < targetAmounts.length; i++) {
            require(targetAmounts[i] > 0, "Invalid amount");
            totalAmount += targetAmounts[i];
        }
        require(totalAmount > 0, "Invalid order");

        // Auto-initialize pool with our hook if it doesn't exist
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000, // Force dynamic fee flag for our hook
            tickSpacing: _getTickSpacingForFee(fee),
            hooks: IHooks(address(this))
        });
        
        PoolId poolId = key.toId();
        
        // Initialize pool if it doesn't exist
        if (!poolInitialized[poolId]) {
            uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price
            poolManager.initialize(key, sqrtPriceX96);
            poolInitialized[poolId] = true;
            poolInitializationBlock[poolId] = block.number;
        }

        // Convert prices to ticks
        int24[] memory targetTicks = new int24[](targetPrices.length);
        
        for (uint256 i = 0; i < targetPrices.length; i++) {
            uint160 sqrtPrice = uint160(targetPrices[i]);
            int24 tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
            targetTicks[i] = getLowerUsableTick(tick, key.tickSpacing);
            
            // Add to pending orders storage
            pendingBatchOrders[key.toId()][targetTicks[i]][zeroForOne] += targetAmounts[i];
        }

        // Create batch order ID
        batchId = nextBatchOrderId++;
        
        // Store batch info with simplified MEV protection
        batchOrdersInfo[batchId] = BatchOrderInfo({
            user: msg.sender,
            poolKey: key,
            targetTicks: targetTicks,
            targetAmounts: targetAmounts,
            zeroForOne: zeroForOne,
            totalAmount: totalAmount,
            expirationTime: deadline,
            isActive: true,
            maxSlippageBps: maxSlippageBps,
            minOutputAmount: minOutputAmount,
            creationBlock: block.number,
            bestPriceTimeout: bestPriceTimeout
        });
        
        // Populate tickToBatchIds mapping
        for (uint256 i = 0; i < targetTicks.length; i++) {
            tickToBatchIds[key.toId()][targetTicks[i]][zeroForOne].push(batchId);
        }
        
        // Mint ERC6909 claim tokens
        claimTokensSupply[batchId] = totalAmount;
        _mint(msg.sender, address(uint160(batchId)), totalAmount);

        // Handle token deposits
        address sellToken = zeroForOne 
            ? Currency.unwrap(key.currency0) 
            : Currency.unwrap(key.currency1);
            
        if (sellToken == address(0)) {
            require(msg.value >= totalAmount, "Insufficient ETH");
            if (msg.value > totalAmount) {
                payable(msg.sender).transfer(msg.value - totalAmount);
            }
        } else {
            require(msg.value == 0, "ETH sent with ERC20");
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        }

        emit BatchOrderCreated(
            batchId, msg.sender, maxSlippageBps, minOutputAmount
        );
        
        return batchId;
    }

    /**
     * @notice Get current dynamic fee (external view function)
     * @return fee Current fee based on gas price
     */
    function getCurrentDynamicFee() external view returns (uint24 fee) {
        return getDynamicFee();
    }

    /**
     * @notice Get gas price statistics
     * @return currentGasPrice Current transaction gas price
     * @return averageGasPrice Moving average gas price
     * @return count Number of transactions tracked
     */
    function getGasPriceStats() external view returns (
        uint128 currentGasPrice,
        uint128 averageGasPrice,
        uint104 count
    ) {
        return (
            uint128(tx.gasprice),
            movingAverageGasPrice,
            movingAverageGasPriceCount
        );
    }

    /**
     * @notice Get lower usable tick - following TakeProfitsHook pattern
     * @param tick Target tick
     * @param tickSpacing Tick spacing for the pool
     * @return Lower usable tick
     */
    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        // Following TakeProfitsHook logic exactly
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) intervals--;
        return intervals * tickSpacing;
    }

    /**
     * @notice Returns hook permissions - includes dynamic fee management
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,        // Required for dynamic fee validation
            afterInitialize: true,         // Track pool initialization
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,              // Required for dynamic fee calculation
            afterSwap: true,               // Execute orders and update gas price tracking
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }    /**
     * @notice Validate pool requires dynamic fees
     */
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        // Require dynamic fees for gas-price based fee calculation
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Initialize pool tracking - following TakeProfitsHook pattern
     */
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    /**
     * @notice Calculate dynamic fees based on gas price before swap
     */
    function _beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = getDynamicFee();
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeWithFlag
        );
    }

    /**
     * @notice Execute orders after swaps and update gas price tracking
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Update gas price tracking
        updateMovingAverageGasPrice();
        
        // Avoid infinite loops like TakeProfitsHook does
        // Avoid calling ourselves
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        // Try executing orders following TakeProfitsHook pattern
        bool tryMore = true;
        int24 currentTick;

        while (tryMore) {
            (tryMore, currentTick) = tryExecutingBatchOrders(key, params.zeroForOne);
        }

        // Update last known tick
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Cancel batch order - following TakeProfitsHook pattern
     * @param batchOrderId The batch order to cancel
     */
    function cancelBatchOrder(uint256 batchOrderId) external {
        BatchOrderInfo storage batchInfo = batchOrdersInfo[batchOrderId];
        require(batchInfo.user == msg.sender, "Not authorized");
        require(batchInfo.isActive, "Order not active");
        
        // Allow cancellation of expired orders - they should be treatable as cancelled
        bool isExpired = block.timestamp > batchInfo.expirationTime;
        
        // Calculate refund amount
        uint256 claimBalance = balanceOf[msg.sender][batchOrderId];
        if (claimBalance == 0) revert NothingToClaim();

        // Remove from pending orders storage
        PoolId poolId = batchInfo.poolKey.toId();
        for (uint256 i = 0; i < batchInfo.targetTicks.length; i++) {
            int24 tick = batchInfo.targetTicks[i];
            uint256 tickAmount = batchInfo.targetAmounts[i];
            
            // Only remove if still pending
            if (pendingBatchOrders[poolId][tick][batchInfo.zeroForOne] >= tickAmount) {
                pendingBatchOrders[poolId][tick][batchInfo.zeroForOne] -= tickAmount;
            }
        }

        // Mark as inactive
        batchInfo.isActive = false;
        
        // Burn the claim tokens
        _burn(msg.sender, address(uint160(batchOrderId)), claimBalance);
        
        // Reset claim tokens supply to 0
        claimTokensSupply[batchOrderId] = 0;

        // Refund tokens
        Currency token = batchInfo.zeroForOne ? batchInfo.poolKey.currency0 : batchInfo.poolKey.currency1;
        token.transfer(msg.sender, claimBalance);

        emit BatchOrderCancelled(batchOrderId, msg.sender, isExpired);
    }

    /**
     * @notice Redeem output tokens from executed batch order - following TakeProfitsHook pattern
     * @param batchOrderId The batch order ID
     * @param inputAmountToClaimFor Amount of input tokens to claim for
     */
    function redeemBatchOrder(
        uint256 batchOrderId,
        uint256 inputAmountToClaimFor
    ) external {
        if (claimableOutputTokens[batchOrderId] == 0) revert NothingToClaim();

        uint256 claimTokens = balanceOf[msg.sender][batchOrderId];
        if (claimTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForBatch = claimableOutputTokens[batchOrderId];
        uint256 totalInputAmountForBatch = claimTokensSupply[batchOrderId];

        // Calculate proportional output following TakeProfitsHook pattern
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForBatch,
            totalInputAmountForBatch
        );

        // Update state
        claimableOutputTokens[batchOrderId] -= outputAmount;
        claimTokensSupply[batchOrderId] -= inputAmountToClaimFor;
        _burn(msg.sender, address(uint160(batchOrderId)), inputAmountToClaimFor);

        // Transfer output tokens
        BatchOrderInfo storage batchInfo = batchOrdersInfo[batchOrderId];
        Currency outputToken = batchInfo.zeroForOne ? batchInfo.poolKey.currency1 : batchInfo.poolKey.currency0;
        
        // Apply fees
        uint256 feeAmount = (outputAmount * FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        uint256 userAmount = outputAmount - feeAmount;
        
        if (feeAmount > 0) {
            outputToken.transfer(FEE_RECIPIENT, feeAmount);
        }
        outputToken.transfer(msg.sender, userAmount);
    }

    /**
     * @notice Try executing batch orders - following TakeProfitsHook pattern
     * @param key Pool key
     * @param zeroForOne Direction to execute
     * @return tryMore Whether to try executing more orders
     * @return newTick New tick after execution
     */
    function tryExecutingBatchOrders(
        PoolKey calldata key,
        bool zeroForOne
    ) internal virtual returns (bool tryMore, int24 newTick) {
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // First, check queued orders for best execution
        _processQueuedOrders(key, currentTick);

        // Following TakeProfitsHook logic for tick range execution
        if (currentTick > lastTick) {
            // Tick increased - execute orders selling token0 (triggered by zeroForOne=false swaps)
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[key.toId()][tick][true]; // Always check sell token0 orders
                if (inputAmount > 0) {
                    executeBatchOrderAtTick(key, tick, true, inputAmount);
                    return (true, currentTick);
                }
            }
        } else if (currentTick < lastTick) {
            // Tick decreased - execute orders selling token1 (triggered by zeroForOne=true swaps)
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingBatchOrders[key.toId()][tick][false]; // Always check sell token1 orders
                if (inputAmount > 0) {
                    executeBatchOrderAtTick(key, tick, false, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            // currentTick == lastTick - queue for best price execution
            // Check both directions for orders at the current tick
            uint256 inputAmountToken0 = pendingBatchOrders[key.toId()][currentTick][true]; // Sell token0 orders
            uint256 inputAmountToken1 = pendingBatchOrders[key.toId()][currentTick][false]; // Sell token1 orders
            
            if (inputAmountToken0 > 0) {
                uint256 batchOrderId = getBatchOrderIdForTick(key, currentTick, true);
                uint256 timeout = batchOrderId > 0 ? batchOrdersInfo[batchOrderId].bestPriceTimeout : 0;
                _queueForBestExecution(key, currentTick, true, inputAmountToken0, timeout);
                return (false, currentTick); // Don't execute immediately
            }
            if (inputAmountToken1 > 0) {
                uint256 batchOrderId = getBatchOrderIdForTick(key, currentTick, false);
                uint256 timeout = batchOrderId > 0 ? batchOrdersInfo[batchOrderId].bestPriceTimeout : 0;
                _queueForBestExecution(key, currentTick, false, inputAmountToken1, timeout);
                return (false, currentTick); // Don't execute immediately
            }
        }

        return (false, currentTick);
    }

    /**
     * @notice Queue order for best price execution
     */
    function _queueForBestExecution(
        PoolKey calldata key,
        int24 currentTick,
        bool zeroForOne,
        uint256 amount,
        uint256 timeoutSeconds
    ) internal {
        PoolId poolId = key.toId();
        
        // Calculate target tick for better price
        int24 targetTick;
        if (zeroForOne) {
            // For selling token0, wait for higher tick (better price)
            targetTick = currentTick + (BEST_EXECUTION_TICKS * key.tickSpacing);
        } else {
            // For selling token1, wait for lower tick (better price)
            targetTick = currentTick - (BEST_EXECUTION_TICKS * key.tickSpacing);
        }
        
        // Find the batch order ID for this tick
        uint256 batchOrderId = getBatchOrderIdForTick(key, currentTick, zeroForOne);
        
        // Remove from pending orders at original tick (move to queue)
        pendingBatchOrders[poolId][currentTick][zeroForOne] -= amount;
        
        // Calculate maxWaitTime: if timeoutSeconds is 0, disable timeout (set to max)
        uint256 maxWaitTime = timeoutSeconds == 0 
            ? type(uint256).max 
            : _getBlockTimestamp() + timeoutSeconds;
        
        // Add to queue
        bestPriceQueue[poolId].push(QueuedOrder({
            batchOrderId: batchOrderId,
            originalTick: currentTick,
            targetTick: targetTick,
            amount: amount,
            queueTime: _getBlockTimestamp(),
            maxWaitTime: maxWaitTime,
            zeroForOne: zeroForOne
        }));
        
        emit OrderQueuedForBestExecution(batchOrderId, currentTick, targetTick, amount);
    }

    /**
     * @notice Process queued orders - execute if price improved or timeout
     */
    function _processQueuedOrders(PoolKey calldata key, int24 currentTick) internal virtual {
        PoolId poolId = key.toId();
        QueuedOrder[] storage queue = bestPriceQueue[poolId];
        uint256 currentIndex = queueIndex[poolId];
        
        // Process orders in queue
        while (currentIndex < queue.length) {
            QueuedOrder storage order = queue[currentIndex];
            bool shouldExecute = false;
            bool shouldRemove = false;
            
            // Check if best execution achieved
            if (order.zeroForOne && currentTick >= order.targetTick) {
                shouldExecute = true; // Better sell price for token0
        } else if (!order.zeroForOne && currentTick <= order.targetTick) {
            shouldExecute = true; // Better sell price for token1
        } else if (_getBlockTimestamp() >= order.maxWaitTime) {
            shouldExecute = true; // Timeout - execute at current price
        }            if (shouldExecute) {
                // Execute the order
                int24 executionTick = currentTick; // Use current tick, not original
                
                // Execute at current tick using known batch order ID
                _executeBatchOrderWithId(key, executionTick, order.zeroForOne, order.amount, order.batchOrderId);
                
            emit OrderExecutedFromQueue(
                order.batchOrderId, 
                order.originalTick, 
                executionTick, 
                order.amount,
                _getBlockTimestamp() >= order.maxWaitTime // Was timeout?
            );                shouldRemove = true;
            }
            
            if (shouldRemove) {
                // Remove from queue by swapping with last element
                queue[currentIndex] = queue[queue.length - 1];
                queue.pop();
                // Don't increment currentIndex since we swapped
            } else {
                currentIndex++;
            }
            
            // Prevent infinite loops
            if (gasleft() < 50000) break;
        }
        
        queueIndex[poolId] = currentIndex;
    }

    /**
     * @notice Clear expired orders from queue (maintenance function)
     */
    function clearExpiredQueuedOrders(PoolKey calldata key) external virtual {
        PoolId poolId = key.toId();
        QueuedOrder[] storage queue = bestPriceQueue[poolId];
        
        uint256 i = 0;
        while (i < queue.length) {
            if (_getBlockTimestamp() >= queue[i].maxWaitTime) {
                // Execute expired order at original tick using known batch order ID
                QueuedOrder storage order = queue[i];
                _executeBatchOrderWithId(key, order.originalTick, order.zeroForOne, order.amount, order.batchOrderId);
                
                // Remove from queue
                queue[i] = queue[queue.length - 1];
                queue.pop();
            } else {
                i++;
            }
        }
    }

    /**
     * @notice Get queue status for a pool
     */
    function getQueueStatus(PoolKey calldata key) external view virtual returns (
        uint256 queueLength,
        uint256 currentIndex,
        QueuedOrder[] memory orders
    ) {
        PoolId poolId = key.toId();
        return (
            bestPriceQueue[poolId].length,
            queueIndex[poolId],
            bestPriceQueue[poolId]
        );
    }

    /**
     * @notice Execute batch order at specific tick - following TakeProfitsHook pattern
     * @param key Pool key
     * @param tick Execution tick
     * @param zeroForOne Swap direction
     * @param inputAmount Amount to execute
     */
    function executeBatchOrderAtTick(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount
    ) internal {
        _executeBatchOrderAtTick(key, tick, zeroForOne, inputAmount, true);
    }

    /**
     * @notice Execute batch order at specific tick - internal version with skipPendingUpdate option
     */
    function _executeBatchOrderAtTick(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount,
        bool updatePendingOrders
    ) internal virtual {
        // Execute order with slippage protection if configured
        uint256 batchOrderId = getBatchOrderIdForTick(key, tick, zeroForOne);
        
        if (batchOrderId != 0) {
            BatchOrderInfo storage batchInfo = batchOrdersInfo[batchOrderId];
            
            // Apply slippage protection if enabled
            if (batchInfo.maxSlippageBps > 0) {
                _executeOrderWithSlippageProtection(key, tick, zeroForOne, inputAmount, batchOrderId, updatePendingOrders);
                return;
            }
        }
        
        // Standard execution without MEV protection
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount), // Exact input
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // Remove from pending orders only if requested (not for queued orders)
        if (updatePendingOrders) {
            pendingBatchOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        }
        
        // Calculate output amount
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        // Update claimable tokens
        if (batchOrderId != 0) {
            claimableOutputTokens[batchOrderId] += outputAmount;
            emit BatchLevelExecuted(batchOrderId, uint256(uint24(tick)), uint256(int256(tick)), inputAmount);
        }
    }

    /**
     * @notice Execute order with slippage protection
     */
    function _executeOrderWithSlippageProtection(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount,
        uint256 batchOrderId,
        bool updatePendingOrders
    ) internal {
        BatchOrderInfo storage batchInfo = batchOrdersInfo[batchOrderId];
        
        // Calculate slippage-protected price limit
        uint160 slippageProtectedPrice = _calculateSlippageProtectedPrice(
            tick, 
            zeroForOne, 
            batchInfo.maxSlippageBps
        );
        
        // Execute with slippage protection
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: slippageProtectedPrice
            })
        );
        
        // Calculate actual output
        uint256 actualOutput = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));
        
        // Check slippage protection
        if (actualOutput < batchInfo.minOutputAmount) {
            emit SlippageProtectionActivated(batchOrderId, batchInfo.minOutputAmount, actualOutput);
            return; // Don't complete the trade
        }
        
        // Update pending orders if requested
        if (updatePendingOrders) {
            pendingBatchOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        }
        
        // Update claimable tokens
        claimableOutputTokens[batchOrderId] += actualOutput;
        emit BatchLevelExecuted(batchOrderId, uint256(uint24(tick)), uint256(int256(tick)), inputAmount);
    }

    /**
     * @notice Calculate slippage-protected price limit
     */
    function _calculateSlippageProtectedPrice(
        int24 tick,
        bool zeroForOne,
        uint256 maxSlippageBps
    ) internal pure returns (uint160) {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        
        if (zeroForOne) {
            // For selling token0, protect against price going too low
            uint256 minPrice = (uint256(sqrtPrice) * (10000 - maxSlippageBps)) / 10000;
            return uint160(minPrice);
        } else {
            // For selling token1, protect against price going too high
            uint256 maxPrice = (uint256(sqrtPrice) * (10000 + maxSlippageBps)) / 10000;
            return uint160(maxPrice);
        }
    }

    /**
     * @notice Execute batch order with known batch order ID (for queued orders)
     */
    function _executeBatchOrderWithId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount,
        uint256 batchOrderId
    ) internal {
        // Execute swap following TakeProfitsHook pattern
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount), // Exact input
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        
        // Calculate output amount
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        // Update claimable tokens with known batch order ID
        if (batchOrderId != 0) {
            claimableOutputTokens[batchOrderId] += outputAmount;
            emit BatchLevelExecuted(batchOrderId, uint256(uint24(tick)), uint256(int256(tick)), inputAmount);
        }
    }

    /**
     * @notice Swap and settle balances - following TakeProfitsHook pattern
     * @param key Pool key
     * @param params Swap parameters
     * @return delta Balance delta from swap
     */
    function swapAndSettleBalances(
        PoolKey calldata key,
        SwapParams memory params
    ) internal returns (BalanceDelta delta) {
        // Conduct swap following TakeProfitsHook pattern
        delta = poolManager.swap(key, params, "");

        // Settle balances following TakeProfitsHook pattern
        if (params.zeroForOne) {
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }
            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    /**
     * @notice Settle currency with pool manager - following TakeProfitsHook pattern
     * @param currency Currency to settle
     * @param amount Amount to settle
     */
    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    /**
     * @notice Take currency from pool manager - following TakeProfitsHook pattern
     * @param currency Currency to take
     * @param amount Amount to take
     */
    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    /**
     * @notice Get batch order ID for tick (efficient mapping)
     * @dev Uses direct mapping for O(1) lookup instead of O(n) iteration
     * @param key Pool key
     * @param tick Target tick
     * @param zeroForOne Swap direction
     * @return batchOrderId The batch order ID, 0 if not found
     */
    function getBatchOrderIdForTick(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) internal view returns (uint256 batchOrderId) {
        return _getBatchIdForTick(key.toId(), tick, zeroForOne);
    }

    /**
     * @notice Get current timestamp (can be overridden for testing)
     */
    function _getBlockTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }
     /* @param key Pool key
     * @param tick Target tick
     * @param zeroForOne Swap direction
     * @return Unique order ID
     */
    function getOrderId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    // Callback for unlock pattern
    function unlockCallback(bytes calldata /* data */) external view override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        // Implementation would go here for unlock pattern if needed
        return "";
    }

    /**
     * @notice Execute all orders at a specific tick
     */
    function _executeOrdersAtTick(PoolId poolId, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        // Clear the pending order amount
        pendingBatchOrders[poolId][tick][zeroForOne] = 0;
        
        // For now, just emit an event since we don't have full swap implementation
        // In production, this would execute actual swaps
        emit BatchOrderExecuted(
            0, // Placeholder batch ID
            tick,
            inputAmount,
            0 // Placeholder output amount
        );
    }



    /**
     * @notice Get batch ID for specific tick (implementation needed)
     */
    function _getBatchIdForTick(PoolId poolId, int24 tick, bool zeroForOne) internal view returns (uint256) {
        uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
        
        // Return the first active batch ID at this tick
        for (uint256 i = 0; i < batchIds.length; i++) {
            uint256 batchId = batchIds[i];
            if (batchOrdersInfo[batchId].isActive) {
                return batchId;
            }
        }
        
        return 0; // No active batch found
    }

    /**
     * @notice Initialize pool with our hook if it doesn't exist (Option 1)
     * @param currency0 First currency
     * @param currency1 Second currency  
     * @param fee Fee tier (will have dynamic fee flag added)
     * @return key The initialized pool key
     */
    function initializePoolWithHook(
        address currency0,
        address currency1,
        uint24 fee
    ) external returns (PoolKey memory key) {
        // Construct pool key with our hook and dynamic fee flag
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000, // Add dynamic fee flag
            tickSpacing: _getTickSpacingForFee(fee),
            hooks: IHooks(address(this))
        });
        
        PoolId poolId = key.toId();
        
        // Only initialize if not already done
        if (!poolInitialized[poolId]) {
            // Initialize pool at 1:1 price (can be adjusted)
            uint160 sqrtPriceX96 = 79228162514264337593543950336; // sqrt(1) * 2^96
            
            poolManager.initialize(key, sqrtPriceX96);
            
            // Mark as initialized
            poolInitialized[poolId] = true;
            poolInitializationBlock[poolId] = block.number;
            
            emit PoolInitializedWithHook(
                poolId,
                currency0,
                currency1,
                fee & 0x7FFFFF, // Emit base fee without dynamic flag
                key.tickSpacing,
                block.number
            );
        }
        
        return key;
    }

    /**
     * @notice Check if pool with our hook exists
     * @param currency0 First currency
     * @param currency1 Second currency
     * @param fee Fee tier
     * @return exists Whether pool is initialized
     */
    function isPoolInitialized(
        address currency0,
        address currency1,
        uint24 fee
    ) external view returns (bool exists) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000, // Dynamic fee flag
            tickSpacing: _getTickSpacingForFee(fee),
            hooks: IHooks(address(this))
        });
        
        return poolInitialized[key.toId()];
    }

    /**
     * @notice Perform swap using deposited funds
     */
    function _performSwap(PoolKey memory key, uint256 inputAmount, bool zeroForOne) internal returns (uint256 outputAmount) {
        // Similar to TakeProfitsHook swap execution
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        
        // Set up swap parameters
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        
        // Execute swap through pool manager
        BalanceDelta delta = poolManager.swap(key, params, "");
        
        // Extract output amount
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        require(outputDelta > 0, "Invalid swap output");
        outputAmount = uint256(uint128(outputDelta));
        
        // Handle settlement (simplified)
        _settleSwap(inputCurrency, outputCurrency, inputAmount, outputAmount);
        
        return outputAmount;
    }

    /**
     * @notice Handle swap settlement
     */
    function _settleSwap(Currency inputCurrency, Currency outputCurrency, uint256 inputAmount, uint256 outputAmount) internal {
        // Pay input to pool
        if (Currency.unwrap(inputCurrency) == address(0)) {
            poolManager.settle{value: inputAmount}();
        } else {
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(poolManager), inputAmount);
            poolManager.settle();
        }
        
        // Take output from pool
        poolManager.take(outputCurrency, address(this), outputAmount);
    }

    /**
     * @notice Redeem output tokens using ERC6909 claim tokens
     * @param batchOrderId The batch order ID to claim from
     * @param amountToClaim Amount of claim tokens to redeem
     */
    function redeem(uint256 batchOrderId, uint256 amountToClaim) external {
        require(amountToClaim > 0, "Invalid amount");
        require(balanceOf[msg.sender][batchOrderId] >= amountToClaim, "Insufficient claim tokens");
        require(claimableOutputTokens[batchOrderId] > 0, "Nothing to claim");
        
        BatchOrderInfo storage info = batchOrdersInfo[batchOrderId];
        Currency outputCurrency = info.zeroForOne ? info.poolKey.currency1 : info.poolKey.currency0;
        address outputToken = Currency.unwrap(outputCurrency);
        
        // Calculate proportional output amount
        uint256 totalClaimSupply = claimTokensSupply[batchOrderId];
        uint256 outputAmount = (claimableOutputTokens[batchOrderId] * amountToClaim) / totalClaimSupply;
        
        // Burn claim tokens
        _burn(msg.sender, address(uint160(batchOrderId)), amountToClaim);
        
        // Update claimable amount  
        claimableOutputTokens[batchOrderId] -= outputAmount;
        claimTokensSupply[batchOrderId] -= amountToClaim;
        
        // Transfer output tokens
        if (outputToken == address(0)) {
            (bool success,) = msg.sender.call{value: outputAmount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(outputToken).safeTransfer(msg.sender, outputAmount);
        }
        
        emit TokensRedeemed(batchOrderId, msg.sender, outputAmount);
    }

    /**
     * @notice Create batch order with PoolKey and single tick (for test compatibility)
     * @param key Pool key
     * @param tick Target tick
     * @param amount Amount to trade
     * @param zeroForOne Swap direction
     * @return batchId The batch order ID
     */
    function createBatchOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amount,
        bool zeroForOne
    ) external payable returns (uint256 batchId) {
        require(amount > 0, "Invalid amount");
        
        // Update gas price tracking for dynamic fees (at the beginning)
        updateMovingAverageGasPrice();
        
        // Convert tick to price
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        
        // Set expiration to 1 hour from now
        uint256 expirationTime = block.timestamp + 3600;
        
        // Create arrays for single tick batch order
        uint256[] memory targetPrices = new uint256[](1);
        uint256[] memory targetAmounts = new uint256[](1);
        targetPrices[0] = uint256(sqrtPrice);
        targetAmounts[0] = amount;
        
        // Call internal helper that accepts memory arrays - use default 5 minute timeout
        return _createBatchOrderFromMemory(
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            zeroForOne,
            targetPrices,
            targetAmounts,
            expirationTime,
            300 // Default 5 minute best price execution timeout
        );
    }

    /**
     * @notice Internal helper to create batch order from memory arrays
     */
    function _createBatchOrderFromMemory(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 expirationTime,
        uint256 bestPriceTimeout
    ) internal returns (uint256 batchId) {
        require(targetPrices.length == targetAmounts.length, "Array length mismatch");
        require(targetPrices.length > 0 && targetPrices.length <= 10, "Invalid price levels");
        require(expirationTime > block.timestamp, "Invalid expiration");

        // Auto-initialize pool with our hook if it doesn't exist (Option 1)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000, // Force dynamic fee flag for our hook
            tickSpacing: _getTickSpacingForFee(fee),
            hooks: IHooks(address(this))
        });
        
        PoolId poolId = key.toId();
        
        // Initialize pool if it doesn't exist
        if (!poolInitialized[poolId]) {
            uint160 sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price
            poolManager.initialize(key, sqrtPriceX96);
            poolInitialized[poolId] = true;
            poolInitializationBlock[poolId] = block.number;
            
            emit PoolInitializedWithHook(
                poolId,
                currency0,
                currency1,
                fee & 0x7FFFFF, // Emit base fee without dynamic flag
                key.tickSpacing,
                block.number
            );
        }

        // Convert prices to ticks (following TakeProfitsHook pattern)
        int24[] memory targetTicks = new int24[](targetPrices.length);
        uint256 totalAmount = 0;
        
        for (uint256 i = 0; i < targetPrices.length; i++) {
            require(targetAmounts[i] > 0, "Invalid amount");
            totalAmount += targetAmounts[i];
            
            // Convert price to sqrt price then to tick
            uint160 sqrtPrice = uint160(targetPrices[i]); // Simplified conversion
            int24 tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
            targetTicks[i] = getLowerUsableTick(tick, key.tickSpacing);
            
            // Add to pending orders storage (like TakeProfitsHook)
            pendingBatchOrders[key.toId()][targetTicks[i]][zeroForOne] += targetAmounts[i];
        }

        // Create batch order ID (unique ERC6909 token ID)
        batchId = nextBatchOrderId++;
        
        // Store batch info
        batchOrdersInfo[batchId] = BatchOrderInfo({
            user: msg.sender,
            poolKey: key,
            targetTicks: targetTicks,
            targetAmounts: targetAmounts,
            zeroForOne: zeroForOne,
            totalAmount: totalAmount,
            expirationTime: expirationTime,
            isActive: true,
            maxSlippageBps: 500,         // 5% slippage protection
            minOutputAmount: 0,          // Calculated during execution
            creationBlock: block.number,
            bestPriceTimeout: bestPriceTimeout
        });
        
        // FIRST FUNCTION - Populate tickToBatchIds mapping for quick lookup during best execution
        for (uint256 i = 0; i < targetTicks.length; i++) {
            tickToBatchIds[key.toId()][targetTicks[i]][zeroForOne].push(batchId);
        }
        
        // Mint ERC6909 claim tokens to user
        claimTokensSupply[batchId] = totalAmount;
        _mint(msg.sender, address(uint160(batchId)), totalAmount);

        // Handle token deposits
        address sellToken = zeroForOne 
            ? Currency.unwrap(key.currency0) 
            : Currency.unwrap(key.currency1);
            
        if (sellToken == address(0)) {
            // ETH
            require(msg.value >= totalAmount, "Insufficient ETH");
            if (msg.value > totalAmount) {
                payable(msg.sender).transfer(msg.value - totalAmount);
            }
        } else {
            // ERC20
            require(msg.value == 0, "ETH sent with ERC20");
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        }

        emit BatchOrderCreated(
            batchId,
            msg.sender,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            totalAmount,
            targetPrices,
            targetAmounts
        );
        
        return batchId;
    }
    
    /**
     * @notice Create batch order with BatchParams struct (interface implementation)
     * @param params Batch order parameters
     * @return batchId The batch order ID
     */
    function createBatchOrder(BatchParams calldata params) 
        external 
        payable 
        returns (uint256 batchId) {
        return createBatchOrder(
            params.currency0,
            params.currency1,
            3000, // Default fee tier, will be overridden by dynamic calculation
            params.zeroForOne,
            params.targetPrices,
            params.targetAmounts,
            params.expirationTime,
            params.bestPriceTimeout
        );
    }

    /**
     * @notice Create batch order with individual parameters (for server API compatibility)
     * @param currency0 First currency address
     * @param currency1 Second currency address  
     * @param fee Pool fee
     * @param zeroForOne Swap direction
     * @param targetPrices Array of target prices
     * @param targetAmounts Array of target amounts
     * @param expirationTime Expiration timestamp
     * @param bestPriceTimeout Seconds to wait for better price, 0 = disabled
     * @return batchId The batch order ID
     */
    function createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint256 expirationTime,
        uint256 bestPriceTimeout
    ) public payable returns (uint256 batchId) {
        require(targetPrices.length == targetAmounts.length, "Array length mismatch");
        require(targetPrices.length > 0 && targetPrices.length <= 10, "Invalid price levels");
        require(expirationTime > block.timestamp, "Invalid expiration");

        // Update gas price tracking for dynamic fees (at the beginning)
        updateMovingAverageGasPrice();

        // Construct PoolKey with proper tick spacing based on fee
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: _getTickSpacingForFee(fee),
            hooks: IHooks(address(this))
        });

        // Convert prices to ticks (following TakeProfitsHook pattern)
        int24[] memory targetTicks = new int24[](targetPrices.length);
        uint256 totalAmount = 0;
        
        for (uint256 i = 0; i < targetPrices.length; i++) {
            require(targetAmounts[i] > 0, "Invalid amount");
            totalAmount += targetAmounts[i];
            
            // Convert price to sqrt price then to tick
            uint160 sqrtPrice = uint160(targetPrices[i]); // Simplified conversion
            int24 tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
            targetTicks[i] = getLowerUsableTick(tick, key.tickSpacing);
            
            // Add to pending orders storage (like TakeProfitsHook)
            pendingBatchOrders[key.toId()][targetTicks[i]][zeroForOne] += targetAmounts[i];
        }

        // Create batch order ID (unique ERC6909 token ID)
        batchId = nextBatchOrderId++;
        
        // Store batch info
        batchOrdersInfo[batchId] = BatchOrderInfo({
            user: msg.sender,
            poolKey: key,
            targetTicks: targetTicks,
            targetAmounts: targetAmounts,
            zeroForOne: zeroForOne,
            totalAmount: totalAmount,
            expirationTime: expirationTime,
            isActive: true,
            maxSlippageBps: 500,         // 5% slippage protection
            minOutputAmount: 0,          // Calculated during execution
            creationBlock: block.number,
            bestPriceTimeout: bestPriceTimeout
        });
        
        // SECOND FUNCTION - Populate tickToBatchIds mapping for quick lookup during best execution
        for (uint256 i = 0; i < targetTicks.length; i++) {
            tickToBatchIds[key.toId()][targetTicks[i]][zeroForOne].push(batchId);
        }
        
        // Mint ERC6909 claim tokens to user
        claimTokensSupply[batchId] = totalAmount;
        _mint(msg.sender, address(uint160(batchId)), totalAmount);

        // Handle token deposits
        address sellToken = zeroForOne 
            ? Currency.unwrap(key.currency0) 
            : Currency.unwrap(key.currency1);
            
        if (sellToken == address(0)) {
            // ETH
            require(msg.value >= totalAmount, "Insufficient ETH");
            if (msg.value > totalAmount) {
                payable(msg.sender).transfer(msg.value - totalAmount);
            }
        } else {
            // ERC20
            require(msg.value == 0, "ETH sent with ERC20");
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        }

        emit BatchOrderCreated(
            batchId,
            msg.sender,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            totalAmount,
            targetPrices,
            targetAmounts
        );
        
        return batchId;
    }

    /**
     * @notice Manually execute a specific batch level (owner only)
     * @dev Allows owner to execute orders at favorable prices for optimal execution
     * @param batchId The batch order ID to execute
     * @param priceLevel The specific price level to execute (0-based index)
     * @return isFullyExecuted Whether the entire batch is now fully executed
     */
    function executeBatchLevel(uint256 batchId, uint256 priceLevel) 
        external 
        onlyOwner
        returns (bool isFullyExecuted) {
        
        BatchOrderInfo storage batchInfo = batchOrdersInfo[batchId];
        require(batchInfo.isActive, "Batch order not active");
        require(priceLevel < batchInfo.targetTicks.length, "Invalid price level");
        
        int24 targetTick = batchInfo.targetTicks[priceLevel];
        uint256 targetAmount = batchInfo.targetAmounts[priceLevel];
        
        // Check if this level has pending orders
        PoolId poolId = batchInfo.poolKey.toId();
        uint256 pendingAmount = pendingBatchOrders[poolId][targetTick][batchInfo.zeroForOne];
        
        if (pendingAmount >= targetAmount) {
            // Create memory copy for the swap
            PoolKey memory poolKey = batchInfo.poolKey;
            
            // Execute the swap directly (similar to _executeBatchOrderAtTick logic)
            BalanceDelta delta = poolManager.swap(
                poolKey, 
                SwapParams({
                    zeroForOne: batchInfo.zeroForOne,
                    amountSpecified: -int256(targetAmount), // Exact input
                    sqrtPriceLimitX96: batchInfo.zeroForOne
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }), 
                ""
            );
            
            // Update pending orders
            pendingBatchOrders[poolId][targetTick][batchInfo.zeroForOne] -= targetAmount;
            
            // Calculate output amount
            uint256 outputAmount = batchInfo.zeroForOne
                ? uint256(int256(delta.amount1()))
                : uint256(int256(delta.amount0()));

            // Update claimable tokens
            claimableOutputTokens[batchId] += outputAmount;
            
            emit ManualBatchLevelExecuted(batchId, priceLevel, msg.sender, targetAmount);
            emit BatchLevelExecuted(batchId, priceLevel, uint256(int256(targetTick)), targetAmount);
        }
        
        // Check if batch is fully executed
        uint256 totalClaimable = claimableOutputTokens[batchId];
        if (totalClaimable >= batchInfo.totalAmount) {
            batchInfo.isActive = false;
            emit BatchFullyExecuted(batchId, batchInfo.totalAmount, totalClaimable);
            isFullyExecuted = true;
        }
        
        return isFullyExecuted;
    }

    function getBatchOrders(uint256 /* batchId */) external pure returns (uint256[] memory orderIds) {
        // Return empty array for now - this would need more complex tracking
        return new uint256[](0);
    }

    function getBatchOrderDetails(uint256 batchId) external view override returns (
        address user,
        address currency0,
        address currency1,
        uint256 totalAmount,
        uint256 executedAmount,
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 expirationTime,
        bool isActive,
        bool isFullyExecuted,
        uint256 executedLevels,
        bool zeroForOne
    ) {
        BatchOrderInfo storage info = batchOrdersInfo[batchId];
        user = info.user;
        currency0 = Currency.unwrap(info.poolKey.currency0);
        currency1 = Currency.unwrap(info.poolKey.currency1);
        totalAmount = info.totalAmount;
        executedAmount = claimableOutputTokens[batchId];
        targetPrices = new uint256[](info.targetTicks.length);
        targetAmounts = info.targetAmounts;
        expirationTime = info.expirationTime;
        isActive = info.isActive;
        isFullyExecuted = executedAmount > 0;
        executedLevels = 0; // Simplified for now
        zeroForOne = info.zeroForOne;
        
        // Convert ticks to prices
        for (uint256 i = 0; i < info.targetTicks.length; i++) {
            uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(info.targetTicks[i]);
            targetPrices[i] = uint256(sqrtPrice);
        }
    }

    function getExecutedLevels(uint256 batchId) external view returns (uint256 executedLevels, bool[] memory levelStatus) {
        BatchOrderInfo storage info = batchOrdersInfo[batchId];
        levelStatus = new bool[](info.targetTicks.length);
        executedLevels = 0;
        
        // Check which levels have been executed (simplified)
        bool hasExecuted = claimableOutputTokens[batchId] > 0;
        for (uint256 i = 0; i < info.targetTicks.length; i++) {
            levelStatus[i] = hasExecuted;
        }
    }

    function getBatchStatistics() external view returns (uint256 totalBatches) {
        return nextBatchOrderId;
    }
    function getBatchOrder(uint256 batchOrderId) 
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
            bool isActive,
            bool isFullyExecuted
        ) 
    {
        BatchOrderInfo storage info = batchOrdersInfo[batchOrderId];
        uint256 claimableAmount = claimableOutputTokens[batchOrderId];
        uint256 claimSupply = claimTokensSupply[batchOrderId];
        
        // Convert ticks back to prices for display
        uint256[] memory prices = new uint256[](info.targetTicks.length);
        for (uint256 i = 0; i < info.targetTicks.length; i++) {
            uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(info.targetTicks[i]);
            prices[i] = uint256(sqrtPrice);
        }
        
        return (
            info.user,
            Currency.unwrap(info.poolKey.currency0),
            Currency.unwrap(info.poolKey.currency1),
            info.totalAmount,
            info.totalAmount - claimSupply, // executed amount
            prices,
            info.targetAmounts,
            info.isActive,
            claimableAmount > 0 // fully executed if has claimable output
        );
    }

    function getFeeInfo() external view returns (
        address feeRecipient,
        uint256 feeBasisPoints,
        uint256 basisPointsDenominator,
        uint24 baseFee,
        uint24 currentDynamicFee,
        uint128 currentGasPrice,
        uint128 averageGasPrice
    ) {
        return (
            FEE_RECIPIENT, 
            FEE_BASIS_POINTS, 
            BASIS_POINTS_DENOMINATOR,
            BASE_FEE,
            getDynamicFee(),
            uint128(tx.gasprice),
            movingAverageGasPrice
        );
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner, amount);
        }
    }

    /**
     * @dev Get tick spacing for a given fee tier (Uniswap V4 standard)
     * @param fee The fee tier (may include dynamic fee flag)
     * @return tickSpacing The corresponding tick spacing
     */
    function _getTickSpacingForFee(uint24 fee) internal pure returns (int24 tickSpacing) {
        // Strip dynamic fee flag if present
        uint24 baseFee = fee & 0x7FFFFF;
        
        if (baseFee == 100) {
            return 1;      // 0.01% fee tier
        } else if (baseFee == 500) {
            return 10;     // 0.05% fee tier
        } else if (baseFee == 3000) {
            return 60;     // 0.3% fee tier
        } else if (baseFee == 10000) {
            return 200;    // 1% fee tier
        } else {
            return 60;     // Default to 0.3% tier spacing
        }
    }

    // Events for best execution queue
    event OrderQueuedForBestExecution(uint256 indexed batchOrderId, int24 originalTick, int24 targetTick, uint256 amount);
    event OrderExecutedFromQueue(uint256 indexed batchOrderId, int24 originalTick, int24 executionTick, uint256 amount, bool wasTimeout);

    // Events for gas price-based dynamic fees
    event DynamicFeeUpdated(uint24 oldFee, uint24 newFee, uint128 gasPrice, uint128 averageGasPrice);
    event GasPriceTracked(uint128 gasPrice, uint128 newAverage, uint104 count);

    // Events for pool management (Option 1)
    event PoolInitializedWithHook(
        PoolId indexed poolId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        uint256 blockNumber
    );

    // Events for simplified MEV Protection
    event BatchOrderCreated(
        uint256 indexed batchOrderId, 
        address indexed user, 
        uint256 maxSlippageBps, 
        uint256 minOutputAmount
    );
    event SlippageProtectionActivated(uint256 indexed batchOrderId, uint256 expectedOutput, uint256 actualOutput);

    // Events for new TakeProfitsHook-style functionality
    event BatchOrderExecuted(uint256 indexed batchOrderId, int24 tick, uint256 inputAmount, uint256 outputAmount);
    event TokensRedeemed(uint256 indexed batchOrderId, address indexed user, uint256 amount);
    event BatchOrderCancelled(uint256 indexed batchOrderId, address indexed user, bool wasExpired);

    /**
     * @notice Converts a user-provided key to the internal key with dynamic fee flag
     * @param userKey The key provided by the user
     * @return Internal key with dynamic fee flag enabled
     */
    function _toInternalKey(PoolKey calldata userKey) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: userKey.currency0,
            currency1: userKey.currency1,
            fee: userKey.fee | 0x800000, // Add dynamic fee flag
            tickSpacing: userKey.tickSpacing,
            hooks: userKey.hooks
        });
    }

    /**
     * @notice Get queue status using user-provided key (handles dynamic fee conversion)
     * @param userKey The key provided by the user (may not have dynamic fee flag)
     * @return queueLength Number of orders in queue
     * @return currentIndex Current processing index
     * @return orders Array of queued orders
     */
    function getQueueStatusWithUserKey(PoolKey calldata userKey) external view returns (
        uint256 queueLength,
        uint256 currentIndex,
        QueuedOrder[] memory orders
    ) {
        // Convert to internal key with dynamic fee flag
        PoolKey memory internalKey = _toInternalKey(userKey);
        PoolId poolId = internalKey.toId();
        
        return (
            bestPriceQueue[poolId].length,
            queueIndex[poolId],
            bestPriceQueue[poolId]
        );
    }

    /**
     * @notice Clear expired queued orders using user-provided key
     * @param userKey The key provided by the user (may not have dynamic fee flag)
     */
    function clearExpiredQueuedOrdersWithUserKey(PoolKey calldata userKey) external {
        // Convert to internal key with dynamic fee flag
        PoolKey memory internalKey = _toInternalKey(userKey);
        PoolId poolId = internalKey.toId();
        QueuedOrder[] storage queue = bestPriceQueue[poolId];
        
        uint256 i = 0;
        while (i < queue.length) {
            if (_getBlockTimestamp() >= queue[i].maxWaitTime) {
                // Execute expired order at original tick using original user key
                QueuedOrder storage order = queue[i];
                _executeBatchOrderWithId(userKey, order.originalTick, order.zeroForOne, order.amount, order.batchOrderId);
                
                // Remove from queue
                queue[i] = queue[queue.length - 1];
                queue.pop();
            } else {
                i++;
            }
        }
    }

    /**
     * @notice Check pending orders at a specific tick using user-provided key
     * @param userKey The key provided by the user (may not have dynamic fee flag)
     * @param tick The tick to check
     * @param zeroForOne The direction to check
     * @return amount Amount of pending orders at that tick
     */
    function getPendingOrdersAtTick(
        PoolKey calldata userKey,
        int24 tick,
        bool zeroForOne
    ) external view returns (uint256 amount) {
        // Convert to internal key with dynamic fee flag
        PoolKey memory internalKey = _toInternalKey(userKey);
        PoolId poolId = internalKey.toId();
        
        return pendingBatchOrders[poolId][tick][zeroForOne];
    }

    receive() external payable {}
    fallback() external payable {}
}
