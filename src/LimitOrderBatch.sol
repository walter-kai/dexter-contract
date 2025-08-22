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

    // ========== TOOLS STORAGE (Integrated) ==========
    
    // Advanced features storage
    mapping(PoolId => BestExecutionQueue) public bestExecutionQueues;
    mapping(PoolId => PoolInitializationTracker) public poolTrackers;
    mapping(PoolId => PriceAnalytics) public priceAnalytics;
    mapping(uint256 => AdvancedBatchMetrics) public advancedMetrics;
    
    // Best execution queue structure - optimized for gas efficiency
    struct BestExecutionQueue {
        uint256[] queuedOrderIds;
        mapping(uint256 => uint256) orderPositions; // orderId => position in queue
        uint64 lastProcessedTimestamp;     // 8 bytes
        uint64 bestExecutionTimeout;      // 8 bytes  
        uint32 currentIndex;              // 4 bytes
        int24 bestExecutionTick;          // 3 bytes
        // Total: 23 bytes (fits in one slot with 9 bytes padding)
    }
    
    // Pool initialization tracking - packed for gas efficiency
    struct PoolInitializationTracker {
        uint160 initialSqrtPriceX96;      // 20 bytes
        uint64 initializationTimestamp;   // 8 bytes
        uint32 totalOrdersProcessed;      // 4 bytes
        // Total: 32 bytes (exactly one slot)
        
        uint64 firstOrderTimestamp;       // 8 bytes
        int24 initialTick;                // 3 bytes
        bool isInitialized;               // 1 byte
        // Total: 12 bytes (fits in one slot with 20 bytes padding)
    }
    
    // Price analytics - optimized struct
    struct PriceAnalytics {
        int24[] recentTicks;
        uint256[] recentTimestamps;
        uint64 lastAnalysisTimestamp;     // 8 bytes
        uint32 volatilityScore;           // 4 bytes
        uint32 averageTickMovement;       // 4 bytes
        int24 trendDirection;             // 3 bytes
        // Total: 19 bytes (fits in one slot with 13 bytes padding)
    }
    
    // Advanced batch metrics - packed for efficiency
    struct AdvancedBatchMetrics {
        uint64 creationTimestamp;         // 8 bytes
        uint64 expectedExecutionTime;     // 8 bytes
        uint64 actualExecutionTime;       // 8 bytes
        uint32 creationGasPrice;          // 4 bytes
        uint32 bestPriceAchieved;         // 4 bytes
        // Total: 32 bytes (exactly one slot)
        
        uint32 slippageRealized;          // 4 bytes
        uint32 gasSavingsRealized;        // 4 bytes
        bool usedBestExecution;           // 1 byte
        // Total: 9 bytes (fits in one slot with 23 bytes padding)
    }

    // ========== CONSTANTS ==========
    
    uint24 public constant BASE_FEE = 3000; // 0.3%
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint256 public constant FEE_BASIS_POINTS = 30; // 0.3%
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    
    // Tools constants
    uint256 public constant QUEUE_TIMEOUT = 300; // 5 minutes default
    uint256 public constant MAX_QUEUE_SIZE = 100;
    uint256 public constant ANALYTICS_WINDOW = 50; // Track last 50 price points
    int24 public constant TREND_THRESHOLD = 10; // Minimum tick movement for trend detection
    int24 public constant BEST_EXECUTION_TICKS = 1; // Minimum tick improvement for best execution
    
    address public immutable FEE_RECIPIENT;
    address public owner;

    // ========== ERRORS ==========
    
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    error MustUseDynamicFee();
    error SlippageExceeded();

    // ========== EVENTS ==========
    
    event BatchOrderCreatedOptimized(uint256 indexed batchId, address indexed user, uint256 totalAmount);
    event BatchLevelExecutedOptimized(uint256 indexed batchId, uint256 tick, uint256 amount);
    event BatchOrderCancelledOptimized(uint256 indexed batchId, address indexed user);
    event TokensRedeemedOptimized(uint256 indexed batchId, address indexed user, uint256 amount);
    event GasPriceTrackedOptimized(uint128 gasPrice, uint128 newAverage, uint104 count);
    
    // Tools events
    event OrderQueuedForBestExecution(uint256 indexed orderId, PoolId indexed poolId, uint256 timeout);
    event BestExecutionCompleted(uint256 indexed orderId, int24 executionTick, uint256 gasUsed);
    event QueueProcessed(PoolId indexed poolId, uint256 processedOrders, int24 currentTick);
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);
    event PriceAnalyticsUpdated(PoolId indexed poolId, int24 newTick, int24 trendDirection);
    event AdvancedMetricsCalculated(uint256 indexed orderId, uint256 gasSavings, uint256 priceImprovement);

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
    
    constructor(IPoolManager _poolManager, address _feeRecipient, address _owner) 
        BaseHook(_poolManager) 
    {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_owner != address(0), "Invalid owner");
        owner = _owner;
        FEE_RECIPIENT = _feeRecipient;
    }

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Create a batch limit order
     */
    function createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint256 deadline
    ) external payable virtual returns (uint256 batchId) {
        return _createBatchOrderInternal(
            currency0,
            currency1,
            fee,
            zeroForOne,
            targetPrices,
            targetAmounts,
            deadline
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
        uint256 deadline
    ) internal returns (uint256 batchId) {
        _validateOrderInputs(targetPrices, targetAmounts, deadline, currency0, currency1);
        
        PoolKey memory key = _createPoolKey(currency0, currency1, fee);
        int24[] memory targetTicks = _pricesToTicks(targetPrices);
        uint256 totalAmount = _sumAmounts(targetAmounts);
        
        batchId = _createBatch(key, targetTicks, targetAmounts, totalAmount, zeroForOne, deadline);
        _handleTokenDeposit(key, zeroForOne, totalAmount);
        
        emit BatchOrderCreated(batchId, msg.sender, currency0, currency1, totalAmount, targetPrices, targetAmounts);
        emit BatchOrderCreatedOptimized(batchId, msg.sender, totalAmount);
        
        return batchId;
    }

    /**
     * @notice Cancel batch order - refunds only the unexecuted portion
     */
    function cancelBatchOrder(uint256 batchOrderId) external validBatchOrder(batchOrderId) {
        BatchInfo storage batch = batchOrders[batchOrderId];
        require(batch.user == msg.sender, "Not authorized");
        
        uint256 userClaimBalance = balanceOf[msg.sender][batchOrderId];
        require(userClaimBalance > 0, "No tokens to cancel");
        
        // Check total pending amount
        PoolId poolId = batch.poolKey.toId();
        uint256 totalPendingAmount = 0;
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            totalPendingAmount += pendingBatchOrders[poolId][batchTargetTicks[batchOrderId][i]][batch.zeroForOne];
        }
        
        require(totalPendingAmount > 0, "Batch already executed, use redeem instead");
        
        uint256 cancellableAmount = userClaimBalance * totalPendingAmount / uint256(batch.totalAmount);
        require(cancellableAmount > 0, "Nothing to cancel");
        
        // Burn claim tokens and update pending orders
        _burn(msg.sender, address(uint160(batchOrderId)), cancellableAmount);
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 targetTick = batchTargetTicks[batchOrderId][i];
            uint256 levelPending = pendingBatchOrders[poolId][targetTick][batch.zeroForOne];
            if (levelPending > 0) {
                uint256 levelCancellation = cancellableAmount * levelPending / totalPendingAmount;
                pendingBatchOrders[poolId][targetTick][batch.zeroForOne] -= levelCancellation;
            }
        }
        
        claimTokensSupply[batchOrderId] -= cancellableAmount;
        if (totalPendingAmount == cancellableAmount) batch.isActive = false;
        
        // Return tokens
        Currency inputCurrency = batch.zeroForOne ? batch.poolKey.currency0 : batch.poolKey.currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            payable(msg.sender).transfer(cancellableAmount);
        } else {
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

    /**
     * @notice Redeem executed order output tokens
     */    // ========== HOOK IMPLEMENTATIONS ==========

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
        
        // Track pool initialization with integrated tools
        trackPoolInitialization(key, tick);
        
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
        
        // Update price analytics with integrated tools
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        updatePriceAnalytics(key, currentTick);
        
        return (this.afterSwap.selector, 0);
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========

    function _validateOrderInputs(
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 deadline,
        address currency0,
        address currency1
    ) internal view {
        require(targetPrices.length == targetAmounts.length && targetPrices.length > 0 && targetPrices.length <= 10, "Invalid arrays");
        require(deadline > block.timestamp, "Expired deadline");
        require(currency0 != currency1, "Same currencies");
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

    function _createBatch(
        PoolKey memory key,
        int24[] memory targetTicks,
        uint256[] memory targetAmounts,
        uint256 totalAmount,
        bool zeroForOne,
        uint256 deadline
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
            maxSlippageBps: 300,  // Fixed 3% slippage
            bestPriceTimeout: 0,  // No timeout
            ticksLength: uint16(targetTicks.length),
            zeroForOne: zeroForOne,
            isActive: true,
            minOutputAmount: 0    // No minimum output requirement
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

        if (currentTick != lastTick) {
            // Process best execution queue with integrated tools
            processBestExecutionQueue(key, currentTick);
            
            _executeOrdersInRange(key, lastTick, currentTick);
            lastTicks[key.toId()] = currentTick;
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
     */
    function executeBatchLevel(uint256 batchId, uint256 levelIndex) external returns (bool isFullyExecuted) {
        BatchInfo storage batch = batchOrders[batchId];
        require(batch.isActive && msg.sender == owner && levelIndex < batch.ticksLength, "Invalid execution");
        
        PoolId poolId = batch.poolKey.toId();
        int24 targetTick = batchTargetTicks[batchId][levelIndex];
        uint256 pendingAmount = pendingBatchOrders[poolId][targetTick][batch.zeroForOne];
        require(pendingAmount > 0, "No pending orders");
        
        uint256 amountToExecute = batchTargetAmounts[batchId][levelIndex];
        if (pendingAmount < amountToExecute) amountToExecute = pendingAmount;
        
        // Perform swap
        SwapParams memory params = SwapParams({
            zeroForOne: batch.zeroForOne,
            amountSpecified: -int256(amountToExecute),
            sqrtPriceLimitX96: batch.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        
        bytes memory result = poolManager.unlock(abi.encode(batch.poolKey, params));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        uint256 outputAmount = batch.zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        
        // Update state
        claimableOutputTokens[batchId] += outputAmount;
        pendingBatchOrders[poolId][targetTick][batch.zeroForOne] -= amountToExecute;
        
        if (pendingBatchOrders[poolId][targetTick][batch.zeroForOne] == 0) {
            _removeBatchIdFromTick(poolId, targetTick, batch.zeroForOne, batchId);
        }
        
        // Check if fully executed
        isFullyExecuted = true;
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            if (pendingBatchOrders[poolId][batchTargetTicks[batchId][i]][batch.zeroForOne] > 0) {
                isFullyExecuted = false;
                break;
            }
        }
        
        emit ManualBatchLevelExecuted(batchId, levelIndex, msg.sender, amountToExecute);
        emit BatchLevelExecuted(batchId, levelIndex, uint256(uint24(targetTick)), amountToExecute);
        
        if (isFullyExecuted) {
            batch.isActive = false;
            emit BatchFullyExecuted(batchId, amountToExecute, claimableOutputTokens[batchId]);
        }
        
        return isFullyExecuted;
    }

    // ========== CONSOLIDATED VIEW FUNCTION ==========

    /**
     * @notice Get comprehensive batch and contract info in one call
     */
    function getBatchInfo(uint256 batchId) external view returns (
        address user,
        address currency0,
        address currency1, 
        uint256 totalAmount,
        uint256 executedAmount,
        uint256 claimableAmount,
        bool isActive,
        bool isFullyExecuted,
        uint256 expirationTime,
        bool zeroForOne,
        uint256 totalBatches,
        uint24 currentFee
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        require(batch.user != address(0), "Invalid batch");
        
        uint256 execAmount = uint256(batch.totalAmount) - claimTokensSupply[batchId];
        
        return (
            batch.user,
            Currency.unwrap(batch.poolKey.currency0),
            Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount),
            execAmount,
            claimableOutputTokens[batchId],
            batch.isActive,
            claimTokensSupply[batchId] == 0,
            uint256(batch.expirationTime),
            batch.zeroForOne,
            nextBatchOrderId - 1,
            BASE_FEE
        );
    }

    // ========== BACKWARD COMPATIBILITY ==========

    function getBatchOrder(uint256 batchId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256[] memory targetPrices, uint256[] memory targetAmounts,
        bool isActive, bool isFullyExecuted
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        return (
            batch.user,
            Currency.unwrap(batch.poolKey.currency0),
            Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount),
            uint256(batch.totalAmount) - claimTokensSupply[batchId],
            new uint256[](0), // Empty arrays for compatibility
            new uint256[](0),
            batch.isActive,
            claimTokensSupply[batchId] == 0
        );
    }

    // ========== INTEGRATED TOOLS FUNCTIONALITY ==========

    /**
     * @notice Queue an order for best execution timing
     * @param orderId The batch order ID to queue
     * @param key Pool key for the order
     * @param currentTick Current tick of the pool
     * @param timeout Timeout for best execution in seconds
     */
    function queueForBestExecution(
        uint256 orderId,
        PoolKey calldata key,
        int24 currentTick,
        uint256 timeout
    ) external {
        require(msg.sender == owner || msg.sender == address(this), "Unauthorized");
        
        PoolId poolId = key.toId();
        BestExecutionQueue storage queue = bestExecutionQueues[poolId];
        
        require(queue.queuedOrderIds.length < MAX_QUEUE_SIZE, "Queue full");
        require(timeout > 0 && timeout <= QUEUE_TIMEOUT, "Invalid timeout");
        
        // Add to queue if not already present
        if (queue.orderPositions[orderId] == 0) {
            queue.queuedOrderIds.push(orderId);
            queue.orderPositions[orderId] = queue.queuedOrderIds.length;
            queue.bestExecutionTimeout = uint64(timeout);
            queue.bestExecutionTick = currentTick;
            
            emit OrderQueuedForBestExecution(orderId, poolId, timeout);
        }
    }

    /**
     * @notice Process the best execution queue for a pool
     * @param key Pool key to process
     * @param currentTick Current tick of the pool
     * @return processedOrderIds Array of processed order IDs
     */
    function processBestExecutionQueue(
        PoolKey calldata key,
        int24 currentTick
    ) public returns (uint256[] memory processedOrderIds) {
        PoolId poolId = key.toId();
        BestExecutionQueue storage queue = bestExecutionQueues[poolId];
        
        if (queue.queuedOrderIds.length == 0) {
            return new uint256[](0);
        }
        
        uint256[] memory processed = new uint256[](queue.queuedOrderIds.length);
        uint256 processedCount = 0;
        
        // Process orders that meet best execution criteria or have timed out
        for (uint256 i = queue.currentIndex; i < queue.queuedOrderIds.length; i++) {
            uint256 orderId = queue.queuedOrderIds[i];
            
            if (_shouldExecuteBestPrice(currentTick, queue.bestExecutionTick) || _isQueueTimeout(queue)) {
                processed[processedCount] = orderId;
                processedCount++;
                
                // Calculate and store advanced metrics
                calculateAdvancedMetrics(orderId, true);
                
                emit BestExecutionCompleted(orderId, currentTick, gasleft());
            }
        }
        
        // Clean up processed orders
        if (processedCount > 0) {
            _cleanupProcessedOrders(queue, processedCount);
            queue.lastProcessedTimestamp = uint64(block.timestamp);
            emit QueueProcessed(poolId, processedCount, currentTick);
        }
        
        // Resize array to actual processed count
        assembly {
            mstore(processed, processedCount)
        }
        
        return processed;
    }

    /**
     * @notice Track pool initialization for analytics
     * @param key Pool key that was initialized
     * @param tick Initial tick of the pool
     */
    function trackPoolInitialization(
        PoolKey calldata key,
        int24 tick
    ) public {
        require(msg.sender == address(this) || msg.sender == owner, "Unauthorized");
        
        PoolId poolId = key.toId();
        PoolInitializationTracker storage tracker = poolTrackers[poolId];
        
        if (!tracker.isInitialized) {
            (, , uint160 sqrtPriceX96, ) = StateLibrary.getSlot0(poolManager, poolId);
            
            tracker.initialSqrtPriceX96 = sqrtPriceX96;
            tracker.initializationTimestamp = uint64(block.timestamp);
            tracker.initialTick = tick;
            tracker.isInitialized = true;
            
            emit PoolInitializationTracked(poolId, tick, block.timestamp);
        }
    }

    /**
     * @notice Update price analytics for a pool
     * @param key Pool key to update analytics for
     * @param newTick New tick to add to analytics
     */
    function updatePriceAnalytics(
        PoolKey calldata key,
        int24 newTick
    ) public {
        require(msg.sender == address(this) || msg.sender == owner, "Unauthorized");
        
        PoolId poolId = key.toId();
        PriceAnalytics storage analytics = priceAnalytics[poolId];
        
        // Add new tick data
        analytics.recentTicks.push(newTick);
        analytics.recentTimestamps.push(block.timestamp);
        
        // Maintain rolling window
        if (analytics.recentTicks.length > ANALYTICS_WINDOW) {
            // Remove oldest entry (simple implementation)
            for (uint256 i = 0; i < analytics.recentTicks.length - 1; i++) {
                analytics.recentTicks[i] = analytics.recentTicks[i + 1];
                analytics.recentTimestamps[i] = analytics.recentTimestamps[i + 1];
            }
            analytics.recentTicks.pop();
            analytics.recentTimestamps.pop();
        }
        
        // Update trend analysis
        _updateTrendAnalysis(analytics);
        analytics.lastAnalysisTimestamp = uint64(block.timestamp);
        
        emit PriceAnalyticsUpdated(poolId, newTick, analytics.trendDirection);
    }

    /**
     * @notice Calculate advanced metrics for an order
     * @param orderId Order ID to calculate metrics for
     * @param usedBestExecution Whether best execution was used
     */
    function calculateAdvancedMetrics(
        uint256 orderId,
        bool usedBestExecution
    ) public {
        require(msg.sender == address(this) || msg.sender == owner, "Unauthorized");
        
        AdvancedBatchMetrics storage metrics = advancedMetrics[orderId];
        
        metrics.creationTimestamp = uint64(block.timestamp);
        metrics.usedBestExecution = usedBestExecution;
        metrics.creationGasPrice = uint32(tx.gasprice);
        
        if (usedBestExecution) {
            metrics.actualExecutionTime = uint64(block.timestamp);
            uint256 gasSavings = _calculateGasSavings(orderId, gasleft());
            uint256 priceImprovement = _calculatePriceImprovement(orderId, 0);
            
            metrics.gasSavingsRealized = uint32(gasSavings);
            
            emit AdvancedMetricsCalculated(orderId, gasSavings, priceImprovement);
        }
    }

    // ========== INTERNAL TOOLS HELPERS ==========

    function _shouldExecuteBestPrice(int24 currentTick, int24 bestTick) internal pure returns (bool) {
        return (currentTick - bestTick) >= BEST_EXECUTION_TICKS;
    }

    function _isQueueTimeout(BestExecutionQueue storage queue) internal view returns (bool) {
        return block.timestamp >= queue.lastProcessedTimestamp + queue.bestExecutionTimeout;
    }

    function _updateTrendAnalysis(PriceAnalytics storage analytics) internal {
        if (analytics.recentTicks.length < 2) return;
        
        uint256 len = analytics.recentTicks.length;
        int24 recentMovement = analytics.recentTicks[len - 1] - analytics.recentTicks[len - 2];
        
        if (recentMovement > TREND_THRESHOLD) {
            analytics.trendDirection = 1; // Upward
        } else if (recentMovement < -TREND_THRESHOLD) {
            analytics.trendDirection = -1; // Downward
        } else {
            analytics.trendDirection = 0; // Sideways
        }
        
        // Update average tick movement
        int256 totalMovement = 0;
        for (uint256 i = 1; i < len; i++) {
            totalMovement += analytics.recentTicks[i] - analytics.recentTicks[i - 1];
        }
        analytics.averageTickMovement = uint32(uint256(totalMovement < 0 ? -totalMovement : totalMovement) / (len - 1));
    }

    function _cleanupProcessedOrders(BestExecutionQueue storage queue, uint256 processedCount) internal {
        for (uint256 i = 0; i < processedCount; i++) {
            uint256 orderId = queue.queuedOrderIds[queue.currentIndex + i];
            delete queue.orderPositions[orderId];
        }
        
        // Shift remaining orders
        for (uint256 i = processedCount; i < queue.queuedOrderIds.length; i++) {
            queue.queuedOrderIds[i - processedCount] = queue.queuedOrderIds[i];
        }
        
        // Resize array
        for (uint256 i = 0; i < processedCount; i++) {
            queue.queuedOrderIds.pop();
        }
        
        queue.currentIndex = 0;
    }

    function _calculateGasSavings(uint256 orderId, uint256 gasUsed) internal pure returns (uint256) {
        // Simplified gas savings calculation
        return gasUsed > 100000 ? gasUsed - 100000 : 0;
    }

    function _calculatePriceImprovement(uint256 orderId, uint256 executionTick) internal pure returns (uint256) {
        // Simplified price improvement calculation
        return 0;
    }

    // ========== FALLBACKS ==========

    receive() external payable {}
    fallback() external payable {}
}
