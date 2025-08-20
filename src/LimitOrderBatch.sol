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

// Forward declaration for tools contract interface
interface ILimitOrderBatchTools {
    function queueForBestExecution(uint256 orderId, PoolKey calldata key, int24 currentTick, uint256 timeout) external;
    function processBestExecutionQueue(PoolKey calldata key, int24 currentTick) external returns (uint256[] memory);
    function updatePriceAnalytics(PoolKey calldata key, int24 newTick) external;
    function calculateAdvancedMetrics(uint256 orderId, bool usedBestExecution) external;
    function trackPoolInitialization(PoolKey calldata key, int24 tick) external;
}

/**
 * @title LimitOrderBatch - Simplified and Gas-Optimized Version
 * @notice Batch limit order system optimized for contract size and gas efficiency
 * @dev Refactored to eliminate duplicate code and reduce contract size with modular tools integration
 */
contract LimitOrderBatch is ILimitOrderBatch, ERC6909Base, BaseHook, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;
    using LPFeeLibrary for uint24;

    // ========== STORAGE ==========
    
    // Core storage following TakeProfitsHook pattern
    mapping(PoolId => int24) public lastTicks;
    mapping(PoolId => mapping(int24 => mapping(bool => uint256))) public pendingBatchOrders;
    mapping(uint256 => uint256) public claimableOutputTokens;
    mapping(uint256 => uint256) public claimTokensSupply;
    mapping(PoolId => mapping(int24 => mapping(bool => uint256[]))) internal tickToBatchIds;
    
    // Track total executed amounts per batch (for proportional calculations)
    mapping(uint256 => uint256) public batchExecutedAmounts;
    
    // Optimized batch info struct - packed for gas efficiency
    struct BatchInfo {
        address user;                    // 20 bytes
        uint96 totalAmount;             // 12 bytes - packed with user (32 bytes total)
        
        PoolKey poolKey;                // 32 bytes (separate slot)
        
        uint64 expirationTime;          // 8 bytes 
        uint32 maxSlippageBps;          // 4 bytes
        uint32 bestPriceTimeout;        // 4 bytes
        uint16 ticksLength;             // 2 bytes - store length instead of dynamic array
        bool zeroForOne;                // 1 byte
        bool isActive;                  // 1 byte
        // Total: 22 bytes (fits in one slot with 10 bytes padding)
        
        uint256 minOutputAmount;        // 32 bytes (separate slot)
    }
    
    // Store arrays separately to avoid dynamic array gas costs
    mapping(uint256 => int24[]) public batchTargetTicks;
    mapping(uint256 => uint256[]) public batchTargetAmounts;
    
    mapping(uint256 => BatchInfo) public batchOrders;
    uint256 public nextBatchOrderId = 1;

    // Best execution queue (simplified version)
    struct QueuedOrder {
        uint256 batchOrderId;
        int24 originalTick;
        int24 targetTick;
        uint256 amount;
        uint256 queueTime;
        uint256 maxWaitTime;
        bool zeroForOne;
    }
    
    mapping(PoolId => QueuedOrder[]) public bestPriceQueue;
    mapping(PoolId => uint256) public queueIndex;

    // ========== CONSTANTS ==========
    
    uint24 public constant BASE_FEE = 3000; // 0.3%
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint256 public constant FEE_BASIS_POINTS = 30; // 0.3%
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    int24 public constant BEST_EXECUTION_TICKS = 1;
    
    address public immutable FEE_RECIPIENT;
    address public owner;
    ILimitOrderBatchTools public toolsContract;

    // ========== ERRORS ==========
    
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    error MustUseDynamicFee();
    error SlippageExceeded();
    error ToolsAlreadySet();

    // ========== EVENTS ==========
    
    event BatchOrderCreatedOptimized(uint256 indexed batchId, address indexed user, uint256 totalAmount);
    event BatchLevelExecutedOptimized(uint256 indexed batchId, uint256 tick, uint256 amount);
    event BatchOrderCancelledOptimized(uint256 indexed batchId, address indexed user);
    event TokensRedeemedOptimized(uint256 indexed batchId, address indexed user, uint256 amount);
    event GasPriceTrackedOptimized(uint128 gasPrice, uint128 newAverage, uint104 count);
    event ToolsContractSet(address indexed toolsContract);

    // ========== MODIFIERS ==========
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not contract owner");
        _;
    }

    modifier validBatchOrder(uint256 batchId) {
        require(batchId > 0 && batchId < nextBatchOrderId, "Invalid batch ID");
        require(batchOrders[batchId].isActive, "Order not active");
        _;
    }

    // ========== CONSTRUCTOR ==========
    
    constructor(IPoolManager _poolManager, address _feeRecipient, address _owner, address _toolsContract) 
        BaseHook(_poolManager) 
    {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_owner != address(0), "Invalid owner");
        owner = _owner;
        FEE_RECIPIENT = _feeRecipient;
        
        // Set tools contract if provided (can be zero initially)
        if (_toolsContract != address(0)) {
            toolsContract = ILimitOrderBatchTools(_toolsContract);
        }
    }

    // ========== TOOLS INTEGRATION ==========
    
    /**
     * @notice Set the tools contract address (can only be done once if not set in constructor)
     * @param _toolsContract Address of the LimitOrderBatchTools contract
     */
    function setToolsContract(address _toolsContract) external onlyOwner {
        require(address(toolsContract) == address(0), "Tools already set");
        require(_toolsContract != address(0), "Invalid tools contract");
        toolsContract = ILimitOrderBatchTools(_toolsContract);
        emit ToolsContractSet(_toolsContract);
    }

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Universal batch order creation function
     * @dev Single entry point for all batch order variations
     */
    /**
     * @notice Create a batch limit order with multiple price levels
     * @param currency0 Address of token0 in the pool
     * @param currency1 Address of token1 in the pool  
     * @param fee Pool fee tier
     * @param zeroForOne True if selling token0 for token1, false otherwise
     * @param targetPrices Array of target prices (as sqrt price X96)
     * @param targetAmounts Array of amounts for each price level
     * @param deadline Order expiration timestamp
     * @param maxSlippageBps Maximum slippage in basis points (e.g., 300 = 3%)
     * @param minOutputAmount Minimum output amount expected
     * @param bestPriceTimeout Timeout for best price execution optimization
     * @return batchId Unique identifier for the created batch order
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
        return _createBatchOrderInternal(
            currency0,
            currency1,
            fee,
            zeroForOne,
            targetPrices,
            targetAmounts,
            deadline,
            maxSlippageBps,
            minOutputAmount,
            bestPriceTimeout
        );
    }

    // Alias for test compatibility
    function createBatchOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amount,
        bool zeroForOne
    ) external payable virtual returns (uint256 batchId) {
        // Convert single tick to arrays
        uint256[] memory prices = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        prices[0] = uint256(TickMath.getSqrtPriceAtTick(tick));
        amounts[0] = amount;
        
        return _createBatchOrderInternal(
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            zeroForOne,
            prices,
            amounts,
            block.timestamp + 3600, // 1 hour default deadline
            300, // 3% default slippage
            amount * 95 / 100, // 95% min output
            300 // 5 minute timeout
        );
    }

    /**
     * @notice Simplified batch order creation (compatibility wrapper)
     */
    function createBatchOrderFromPoolKey(
        PoolKey calldata key,
        int24 tick,
        uint256 amount,
        bool zeroForOne
    ) external payable returns (uint256 batchId) {
        // Convert single tick to arrays
        uint256[] memory prices = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        prices[0] = uint256(TickMath.getSqrtPriceAtTick(tick));
        amounts[0] = amount;
        
        return _createBatchOrderInternal(
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            zeroForOne,
            prices,
            amounts,
            block.timestamp + 3600, // 1 hour default deadline
            300, // 3% default slippage
            amount * 95 / 100, // 95% min output
            300 // 5 minute timeout
        );
    }

    /**
     * @notice Internal batch order creation logic
     */
    function _createBatchOrderInternal(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 deadline,
        uint256 maxSlippageBps,
        uint256 minOutputAmount,
        uint256 bestPriceTimeout
    ) internal returns (uint256 batchId) {
        // Consolidated validation
        _validateOrderInputs(targetPrices, targetAmounts, deadline, maxSlippageBps, currency0, currency1);
        
        // Create pool key
        PoolKey memory key = _createPoolKey(currency0, currency1, fee);
        
        // Convert prices to ticks
        int24[] memory targetTicks = _pricesToTicks(targetPrices);
        
        // Calculate total amount
        uint256 totalAmount = _sumAmounts(targetAmounts);
        
        // Create batch order
        batchId = _createBatch(key, targetTicks, targetAmounts, totalAmount, zeroForOne, deadline, maxSlippageBps, minOutputAmount, bestPriceTimeout);
        
        // Handle token deposits
        _handleTokenDeposit(key, zeroForOne, totalAmount);
        
        // Integrate with tools contract for advanced features (simplified)
        if (address(toolsContract) != address(0) && bestPriceTimeout > 0) {
            // Only queue for best execution if timeout is specified
            try toolsContract.queueForBestExecution(batchId, key, _getCurrentTick(key), bestPriceTimeout) {
                // Best execution queued successfully
            } catch {
                // Continue without best execution if tools contract fails
            }
        }
        
        emit BatchOrderCreated(batchId, msg.sender, currency0, currency1, totalAmount, targetPrices, targetAmounts);
        
        return batchId;
    }

    /**
     * @notice Cancel batch order - refunds only the unexecuted portion
     * @dev Can be called at any time, even after partial execution
     */
    function cancelBatchOrder(uint256 batchOrderId) external validBatchOrder(batchOrderId) {
        BatchInfo storage batch = batchOrders[batchOrderId];
        require(batch.user == msg.sender, "Not authorized");
        
        // In ERC6909 model, user can only cancel if the batch hasn't been executed yet
        // Once executed, the swap already happened and output tokens are available for redemption
        uint256 userClaimBalance = balanceOf[msg.sender][batchOrderId];
        require(userClaimBalance > 0, "No tokens to cancel");
        
        // Check if there are still pending orders (unexecuted)
        // For multi-level batches, check if any level has pending orders
        PoolId poolId = batch.poolKey.toId();
        bool zeroForOne = batch.zeroForOne;
        uint256 totalPendingAmount = 0;
        
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 targetTick = batchTargetTicks[batchOrderId][i];
            totalPendingAmount += pendingBatchOrders[poolId][targetTick][zeroForOne];
        }
        
        require(totalPendingAmount > 0, "Batch already executed, use redeem instead");
        
        // User can only cancel their proportional share of what's still pending
        uint256 cancellableAmount = userClaimBalance * totalPendingAmount / uint256(batch.totalAmount);
        require(cancellableAmount > 0, "Nothing to cancel");
        
        // Burn the cancellable claim tokens
        _burn(msg.sender, address(uint160(batchOrderId)), cancellableAmount);
        
        // Update pending orders proportionally across all levels
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 targetTick = batchTargetTicks[batchOrderId][i];
            uint256 levelPending = pendingBatchOrders[poolId][targetTick][zeroForOne];
            if (levelPending > 0) {
                uint256 levelCancellation = cancellableAmount * levelPending / totalPendingAmount;
                pendingBatchOrders[poolId][targetTick][zeroForOne] -= levelCancellation;
            }
        }
        
        // Update claim tokens supply
        claimTokensSupply[batchOrderId] -= cancellableAmount;
        
        // Mark batch as inactive if no pending orders left
        if (totalPendingAmount == cancellableAmount) {
            batch.isActive = false;
        }
        
        // Return the input tokens
        Currency inputCurrency = zeroForOne ? batch.poolKey.currency0 : batch.poolKey.currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            // ETH
            payable(msg.sender).transfer(cancellableAmount);
        } else {
            // ERC20
            IERC20(Currency.unwrap(inputCurrency)).transfer(msg.sender, cancellableAmount);
        }
        
        emit BatchOrderCancelledOptimized(batchOrderId, msg.sender);
    }

    /**
     * @notice Redeem executed order output tokens
     */
    function redeemBatchOrder(uint256 batchOrderId, uint256 inputAmountToClaimFor) external {
        require(claimableOutputTokens[batchOrderId] > 0, "Nothing to claim");
        require(balanceOf[msg.sender][batchOrderId] >= inputAmountToClaimFor, "Insufficient balance");

        // Calculate proportional output
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            claimableOutputTokens[batchOrderId],
            claimTokensSupply[batchOrderId]
        );

        // Update state
        claimableOutputTokens[batchOrderId] -= outputAmount;
        claimTokensSupply[batchOrderId] -= inputAmountToClaimFor;
        _burn(msg.sender, address(uint160(batchOrderId)), inputAmountToClaimFor);

        // Transfer tokens with fee
        _transferWithFee(batchOrderId, outputAmount);

        emit TokensRedeemedOptimized(batchOrderId, msg.sender, outputAmount);
    }

    // ========== TOOLS CONTRACT INTEGRATION ==========
    
    /**
     * @notice Execute specific order (called by tools contract for best execution)
     * @param batchOrderId The batch order ID to execute
     */
    function executeSpecificOrder(uint256 batchOrderId) external {
        require(msg.sender == address(toolsContract), "Only tools contract");
        require(batchOrderId > 0 && batchOrderId < nextBatchOrderId, "Invalid batch ID");
        
        BatchInfo storage batch = batchOrders[batchOrderId];
        require(batch.isActive, "Order not active");
        
        // Execute the order using internal logic
        PoolKey memory key = batch.poolKey;
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        
        // Execute at current market conditions
        _executeOrderAtCurrentPrice(batchOrderId, key, currentTick);
    }
    
    /**
     * @notice Internal function to execute an order at current market price
     */
    function _executeOrderAtCurrentPrice(uint256 batchOrderId, PoolKey memory key, int24 currentTick) internal {
        BatchInfo storage batch = batchOrders[batchOrderId];
        PoolId poolId = key.toId();
        
        // Calculate total amount to execute
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 targetTick = batchTargetTicks[batchOrderId][i];
            uint256 tickAmount = batchTargetAmounts[batchOrderId][i];
            
            // Check if this level should be executed at current price
            bool shouldExecute = batch.zeroForOne ? (currentTick <= targetTick) : (currentTick >= targetTick);
            if (shouldExecute) {
                totalAmount += tickAmount;
                // Remove from pending
                pendingBatchOrders[poolId][targetTick][batch.zeroForOne] -= tickAmount;
            }
        }
        
        if (totalAmount > 0) {
            // Perform the swap
            SwapParams memory params = SwapParams({
                zeroForOne: batch.zeroForOne,
                amountSpecified: -int256(totalAmount),
                sqrtPriceLimitX96: batch.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });

            bytes memory result = poolManager.unlock(abi.encode(key, params));
            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            uint256 outputAmount = batch.zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));

            // Update claimable tokens
            claimableOutputTokens[batchOrderId] += outputAmount;
            batchExecutedAmounts[batchOrderId] += totalAmount;
            
            emit BatchLevelExecutedOptimized(batchOrderId, uint256(uint24(currentTick)), totalAmount);
        }
    }

    // ========== HOOK IMPLEMENTATIONS ==========

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeSwap: true,
            afterSwap: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        lastTicks[key.toId()] = tick;
        
        // Simplified tools integration for pool initialization
        if (address(toolsContract) != address(0)) {
            try toolsContract.trackPoolInitialization(key, tick) {
                // Pool initialization tracked
            } catch {
                // Continue without tracking if tools contract fails
            }
        }
        
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) 
        internal pure override returns (bytes4, BeforeSwapDelta, uint24) {
        // Use fixed fee for simplified version - tools contract can override for dynamic fees
        uint24 fee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata) 
        internal override returns (bytes4, int128) {
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        _processOrders(key);
        return (this.afterSwap.selector, 0);
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========

    function _validateOrderInputs(
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 deadline,
        uint256 maxSlippageBps,
        address currency0,
        address currency1
    ) internal view {
        if (targetPrices.length == 0 || targetAmounts.length == 0) {
            revert InvalidOrder();
        }
        require(targetPrices.length == targetAmounts.length && targetPrices.length <= 10, "Array length mismatch");
        
        // Validate amounts before prices to catch zero amounts early
        for (uint256 i = 0; i < targetAmounts.length; i++) {
            require(targetAmounts[i] > 0, "Invalid amount");
        }
        
        require(deadline > block.timestamp, "Order creation deadline exceeded");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");
        require(currency0 != address(0) && currency1 != address(0) && currency0 != currency1, "Invalid currencies");
    }

    function _createPoolKey(address currency0, address currency1, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000, // Force dynamic fee
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(this))
        });
    }

    function _getCurrentTick(PoolKey memory key) internal view returns (int24) {
        PoolId poolId = key.toId();
        (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        return tick;
    }

        function _pricesToTicks(uint256[] memory prices) internal pure returns (int24[] memory ticks) {
        uint256 length = prices.length;
        ticks = new int24[](length);
        unchecked {
            for (uint256 i; i < length; ++i) {
                ticks[i] = TickMath.getTickAtSqrtPrice(uint160(prices[i]));
            }
        }
    }

        function _sumAmounts(uint256[] memory amounts) internal pure returns (uint256 total) {
        uint256 length = amounts.length;
        require(length > 0, "Empty arrays");
        unchecked {
            for (uint256 i; i < length; ++i) {
                uint256 amount = amounts[i];
                require(amount > 0, "Invalid amount");
                total += amount;
            }
        }
        require(total > 0, "Invalid total");
    }

    function _getTotalExecutedAmount(uint256 batchId) internal view returns (uint256 totalExecuted) {
        BatchInfo storage batch = batchOrders[batchId];
        PoolId poolId = batch.poolKey.toId();
        
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 tick = batchTargetTicks[batchId][i];
            uint256 originalAmount = batchTargetAmounts[batchId][i];
            uint256 pendingAmount = pendingBatchOrders[poolId][tick][batch.zeroForOne];
            totalExecuted += originalAmount - pendingAmount;
        }
    }

    function _createBatch(
        PoolKey memory key,
        int24[] memory targetTicks,
        uint256[] memory targetAmounts,
        uint256 totalAmount,
        bool zeroForOne,
        uint256 deadline,
        uint256 maxSlippageBps,
        uint256 minOutputAmount,
        uint256 bestPriceTimeout
    ) internal returns (uint256 batchId) {
        batchId = nextBatchOrderId++;
        
        // Store arrays in separate mappings
        batchTargetTicks[batchId] = targetTicks;
        batchTargetAmounts[batchId] = targetAmounts;
        
        batchOrders[batchId] = BatchInfo({
            user: msg.sender,
            totalAmount: uint96(totalAmount),
            poolKey: key,
            expirationTime: uint64(deadline),
            maxSlippageBps: uint32(maxSlippageBps),
            bestPriceTimeout: uint32(bestPriceTimeout),
            ticksLength: uint16(targetTicks.length),
            zeroForOne: zeroForOne,
            isActive: true,
            minOutputAmount: minOutputAmount
        });

        // Add to pending orders
        PoolId poolId = key.toId();
        for (uint256 i = 0; i < targetTicks.length; i++) {
            pendingBatchOrders[poolId][targetTicks[i]][zeroForOne] += targetAmounts[i];
            tickToBatchIds[poolId][targetTicks[i]][zeroForOne].push(batchId);
        }

        // Mint claim tokens
        claimTokensSupply[batchId] = totalAmount;
        _mint(msg.sender, address(uint160(batchId)), totalAmount);
    }

    function _handleTokenDeposit(PoolKey memory key, bool zeroForOne, uint256 totalAmount) internal {
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        
        if (sellToken == address(0)) {
            require(msg.value >= totalAmount, "Insufficient ETH");
            if (msg.value > totalAmount) {
                payable(msg.sender).transfer(msg.value - totalAmount);
            }
        } else {
            require(msg.value == 0, "No ETH needed");
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        }
    }

    function _cleanupBatchOrder(uint256 batchOrderId) internal {
        BatchInfo storage batch = batchOrders[batchOrderId];
        PoolId poolId = batch.poolKey.toId();
        
        // Remove from pending orders
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 tick = batchTargetTicks[batchOrderId][i];
            uint256 amount = batchTargetAmounts[batchOrderId][i];
            pendingBatchOrders[poolId][tick][batch.zeroForOne] -= amount;
            _removeBatchIdFromTick(poolId, tick, batch.zeroForOne, batchOrderId);
        }
    }

    /**
     * @notice Clean up only the unexecuted portion when cancelling
     * @dev More selective than _cleanupBatchOrder - only removes unexecuted amounts
     */
    function _cleanupUnexecutedPortion(uint256 batchOrderId, uint256 unexecutedBalance, uint256 originalAmount) internal {
        BatchInfo storage batch = batchOrders[batchOrderId];
        PoolId poolId = batch.poolKey.toId();
        
        // Calculate proportion of unexecuted vs total
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 tick = batchTargetTicks[batchOrderId][i];
            uint256 originalTickAmount = batchTargetAmounts[batchOrderId][i];
            
            // Calculate how much of this tick's amount is unexecuted
            uint256 unexecutedTickAmount = (originalTickAmount * unexecutedBalance) / originalAmount;
            
            // Only remove the unexecuted portion from pending orders
            if (unexecutedTickAmount > 0) {
                uint256 currentPending = pendingBatchOrders[poolId][tick][batch.zeroForOne];
                if (currentPending >= unexecutedTickAmount) {
                    pendingBatchOrders[poolId][tick][batch.zeroForOne] -= unexecutedTickAmount;
                } else {
                    // Safety: if pending is less than expected, remove what's there
                    pendingBatchOrders[poolId][tick][batch.zeroForOne] = 0;
                }
            }
        }
        
        // Remove batch ID from tick mappings (since order is being cancelled)
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            _removeBatchIdFromTick(poolId, batchTargetTicks[batchOrderId][i], batch.zeroForOne, batchOrderId);
        }
    }

    function _removeBatchIdFromTick(PoolId poolId, int24 tick, bool zeroForOne, uint256 batchOrderId) internal {
        uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
        for (uint256 i = 0; i < batchIds.length; i++) {
            if (batchIds[i] == batchOrderId) {
                batchIds[i] = batchIds[batchIds.length - 1];
                batchIds.pop();
                break;
            }
        }
    }

    function _transferWithFee(uint256 batchOrderId, uint256 outputAmount) internal {
        BatchInfo storage batch = batchOrders[batchOrderId];
        Currency outputToken = batch.zeroForOne ? batch.poolKey.currency1 : batch.poolKey.currency0;
        
        uint256 feeAmount = (outputAmount * FEE_BASIS_POINTS) / BASIS_POINTS_DENOMINATOR;
        uint256 userAmount = outputAmount - feeAmount;
        
        if (feeAmount > 0) {
            outputToken.transfer(FEE_RECIPIENT, feeAmount);
        }
        outputToken.transfer(msg.sender, userAmount);
    }

    function _processOrders(PoolKey calldata key) internal {
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // Process in tick range like TakeProfitsHook
        if (currentTick != lastTick) {
            _executeOrdersInRange(key, lastTick, currentTick);
            lastTicks[key.toId()] = currentTick;
            
            // Simplified tools integration - only process best execution queue
            if (address(toolsContract) != address(0)) {
                try toolsContract.processBestExecutionQueue(key, currentTick) {
                    // Best execution processed
                } catch {
                    // Continue without best execution if tools contract fails
                }
            }
        }
    }

    function _executeOrdersInRange(PoolKey calldata key, int24 fromTick, int24 toTick) internal {
        PoolId poolId = key.toId();
        bool ascending = toTick > fromTick;
        
        // Simple execution logic - can be expanded
        if (ascending) {
            // Price going up, execute sell orders
            for (int24 tick = fromTick; tick <= toTick; tick += key.tickSpacing) {
                uint256 amount = pendingBatchOrders[poolId][tick][false];
                if (amount > 0) {
                    _executeBatchAtTick(key, tick, false, amount);
                }
            }
        } else {
            // Price going down, execute buy orders
            for (int24 tick = fromTick; tick >= toTick; tick -= key.tickSpacing) {
                uint256 amount = pendingBatchOrders[poolId][tick][true];
                if (amount > 0) {
                    _executeBatchAtTick(key, tick, true, amount);
                }
            }
        }
    }

    function _executeBatchAtTick(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        // Simplified execution - perform swap and update claimable amounts
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory result = poolManager.unlock(abi.encode(key, params));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        uint256 outputAmount = zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));

        // Update claimable amounts for all batches at this tick
        PoolId poolId = key.toId();
        uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
        
        for (uint256 i = 0; i < batchIds.length; i++) {
            uint256 batchId = batchIds[i];
            BatchInfo storage batch = batchOrders[batchId];
            
            // Find proportion for this batch
            uint256 batchAmount = _getBatchAmountAtTick(batchId, tick);
            uint256 batchOutput = (outputAmount * batchAmount) / inputAmount;
            
            claimableOutputTokens[batchId] += batchOutput;
            
            // Don't burn claim tokens during execution - let users redeem proportionally
            
            emit BatchLevelExecutedOptimized(batchId, uint256(uint24(tick)), batchAmount);
        }

        // Clear pending orders
        pendingBatchOrders[poolId][tick][zeroForOne] = 0;
    }

    function _getBatchAmountAtTick(uint256 batchId, int24 tick) internal view returns (uint256) {
        BatchInfo storage batch = batchOrders[batchId];
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            if (batchTargetTicks[batchId][i] == tick) {
                return batchTargetAmounts[batchId][i];
            }
        }
        return 0;
    }

    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        return 60; // Default
    }

    // ========== CALLBACK ==========

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        BalanceDelta delta = poolManager.swap(key, params, "");
        return abi.encode(delta);
    }

    // ========== MANUAL EXECUTION FUNCTIONS ==========

    /**
     * @notice Execute a specific batch order level at current market price
     * @dev Allows manual execution regardless of target price - useful for emergency execution
     * @param batchId The batch order ID to execute
     * @param levelIndex Index of the price level to execute (0-based)
     * @return isFullyExecuted Whether the entire batch order is now fully executed
     */
    function executeBatchLevel(uint256 batchId, uint256 levelIndex) external returns (bool isFullyExecuted) {
        BatchInfo storage batch = batchOrders[batchId];
        require(batch.isActive, "Batch order not active");
        require(msg.sender == owner, "Not contract owner");
        require(levelIndex < batch.ticksLength, "Invalid price level");
        
        PoolId poolId = batch.poolKey.toId();
        int24 targetTick = batchTargetTicks[batchId][levelIndex];
        uint256 targetAmount = batchTargetAmounts[batchId][levelIndex];
        bool zeroForOne = batch.zeroForOne;
        
        // Check if this level still has pending orders
        uint256 pendingAmount = pendingBatchOrders[poolId][targetTick][zeroForOne];
        require(pendingAmount > 0, "No pending orders at this level");
        
        // Calculate the actual amount to execute (might be less if partially executed)
        uint256 amountToExecute = targetAmount;
        if (pendingAmount < targetAmount) {
            amountToExecute = pendingAmount;
        }
        
        // Perform the swap at current market price
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountToExecute),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        
        bytes memory result = poolManager.unlock(abi.encode(batch.poolKey, params));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        uint256 outputAmount = zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        
        // Update state
        claimableOutputTokens[batchId] += outputAmount;
        
        pendingBatchOrders[poolId][targetTick][zeroForOne] -= amountToExecute;
        
        // Remove from tick mapping if fully executed
        if (pendingBatchOrders[poolId][targetTick][zeroForOne] == 0) {
            _removeBatchIdFromTick(poolId, targetTick, zeroForOne, batchId);
        }
        
        // Check if entire batch is fully executed by checking all levels
        isFullyExecuted = true;
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 tick = batchTargetTicks[batchId][i];
            if (pendingBatchOrders[poolId][tick][zeroForOne] > 0) {
                isFullyExecuted = false;
                break;
            }
        }
        
        // Emit manual execution event
        emit ManualBatchLevelExecuted(batchId, levelIndex, msg.sender, amountToExecute);
        
        // Emit level execution event
        emit BatchLevelExecuted(batchId, levelIndex, uint256(uint24(targetTick)), amountToExecute);
        
        if (isFullyExecuted) {
            batch.isActive = false;
            // Emit fully executed event
            emit BatchFullyExecuted(batchId, _getTotalExecutedAmount(batchId), claimableOutputTokens[batchId]);
        }
        
        return isFullyExecuted;
    }



    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner, amount);
        }
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get basic batch order information (simplified for core contract)
     * @dev For detailed information, use LimitOrderBatchTools.getBatchOrderDetails()
     */
    function getBatchOrderDetails(uint256 batchId) external view returns (
        address user,
        address currency0,
        address currency1,
        uint256 totalAmount,
        uint256 executedAmount,
        uint256 unexecutedAmount,
        uint256 claimableOutputAmount,
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 expirationTime,
        bool isActive,
        bool isFullyExecuted,
        uint256 executedLevels,
        bool zeroForOne,
        uint128 currentGasPrice,
        uint128 averageGasPrice,
        uint24 currentDynamicFee,
        uint256 totalBatchesCreated
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        
        // Basic information only - detailed calculations moved to tools contract
        user = batch.user;
        currency0 = Currency.unwrap(batch.poolKey.currency0);
        currency1 = Currency.unwrap(batch.poolKey.currency1);
        totalAmount = uint256(batch.totalAmount);
        
        // Simple calculations
        uint256 currentClaimSupply = claimTokensSupply[batchId];
        executedAmount = totalAmount - currentClaimSupply;
        unexecutedAmount = currentClaimSupply;
        claimableOutputAmount = claimableOutputTokens[batchId];
        
        // Arrays (tools contract provides more detailed versions)
        targetPrices = new uint256[](batch.ticksLength);
        targetAmounts = batchTargetAmounts[batchId];
        
        // Basic tick to price conversion
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            targetPrices[i] = uint256(TickMath.getSqrtPriceAtTick(batchTargetTicks[batchId][i]));
        }
        
        // Basic status
        expirationTime = uint256(batch.expirationTime);
        isActive = batch.isActive;
        isFullyExecuted = (executedAmount == totalAmount);
        executedLevels = 0; // Detailed calculation moved to tools
        zeroForOne = batch.zeroForOne;
        
        // Basic gas info (detailed tracking in tools)
        currentGasPrice = uint128(tx.gasprice);
        averageGasPrice = 0; // Moved to tools contract
        currentDynamicFee = BASE_FEE; // Simplified
        totalBatchesCreated = nextBatchOrderId - 1;
    }

    // ========== BACKWARD COMPATIBILITY HELPERS ==========
    // These are simple wrappers for tests that haven't been updated yet

    function getBatchOrder(uint256 batchId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256[] memory targetPrices, uint256[] memory targetAmounts, 
        bool isActive, bool isFullyExecuted
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        // Calculate execution status
        uint256 currentClaimSupply = claimTokensSupply[batchId];
        uint256 executed = uint256(batch.totalAmount) - currentClaimSupply;
        
        // Convert ticks back to prices
        uint256[] memory prices = new uint256[](batch.ticksLength);
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            prices[i] = uint256(TickMath.getSqrtPriceAtTick(batchTargetTicks[batchId][i]));
        }
        
        return (
            batch.user,
            Currency.unwrap(batch.poolKey.currency0),
            Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount),
            executed,
            prices,
            batchTargetAmounts[batchId],
            batch.isActive,
            executed == uint256(batch.totalAmount)
        );
    }

    function getBatchOrders(uint256) external pure returns (uint256[] memory orderIds) {
        return new uint256[](0);
    }

    function getBatchStatistics() external view returns (uint256 totalBatches) {
        return nextBatchOrderId - 1; // Return actual count of created batches
    }

    function getExecutedLevels(uint256 batchId) external view returns (uint256 executedLevels, bool[] memory levelStatus) {
        BatchInfo storage batch = batchOrders[batchId];
        
        // Count executed levels
        uint256 levelsExecuted = 0;
        PoolId poolId = batch.poolKey.toId();
        bool[] memory levelStat = new bool[](batch.ticksLength);
        
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            uint256 pendingAtTick = pendingBatchOrders[poolId][batchTargetTicks[batchId][i]][batch.zeroForOne];
            if (pendingAtTick == 0) {
                levelsExecuted++;
                levelStat[i] = true;
            }
        }
        
        return (levelsExecuted, levelStat);
    }

    function getGasPriceStats() external view returns (uint128, uint128, uint104) {
        return (uint128(tx.gasprice), 0, 0); // Gas tracking moved to tools contract
    }

    function getCurrentDynamicFee() external view returns (uint24) {
        return BASE_FEE; // Dynamic fee calculation moved to tools contract
    }

    // ========== FALLBACKS ==========

    receive() external payable {}
    fallback() external payable {}
}
