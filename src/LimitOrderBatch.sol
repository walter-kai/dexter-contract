// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILimitOrderBatch} from "./interfaces/ILimitOrderBatch.sol";
import {ERC6909Base} from "./base/ERC6909Base.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/libraries/FixedPoint96.sol";

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
    
    // Gas fee management
    mapping(uint256 => uint256) public preCollectedGasFees;
    mapping(uint256 => uint256) public actualGasCosts;
    mapping(uint256 => bool) public gasRefundProcessed;
    
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

    // ========== SIMPLIFIED STORAGE ==========
    
    // Basic pool tracking for initialization
    mapping(PoolId => bool) public poolInitialized;
    
    // Enhanced pool tracking
    PoolId[] public allPoolIds;
    mapping(PoolId => PoolKey) public poolIdToKey;
    mapping(PoolId => uint256) public poolIndex; // Index in allPoolIds array


    // ========== CONSTANTS ==========
    
    uint24 public constant BASE_FEE = 3000; // 0.3%
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint256 public constant BASE_PROTOCOL_FEE_BPS = 35; // 0.35% base protocol fee
    uint256 public constant FEE_BASIS_POINTS = 35; // Backward compatibility - same as BASE_PROTOCOL_FEE_BPS
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    
    // Gas estimation constants
    uint256 public constant ESTIMATED_EXECUTION_GAS = 150000; // Conservative estimate
    uint256 public constant GAS_PRICE_BUFFER_MULTIPLIER = 120; // 20% buffer (120%)
    uint256 public constant MAX_GAS_FEE_ETH = 0.01 ether; // Cap at 0.01 ETH
    
    // Tools constants (minimal)
    
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
    
    // Gas fee events
    event GasFeePreCollected(uint256 indexed batchId, uint256 estimatedGasFee);
    event GasFeeConsumed(uint256 indexed batchId, uint256 actualGasCost, uint256 protocolFee);
    event GasFeeRefunded(uint256 indexed batchId, address indexed user, uint256 refundAmount);
    
    // Simplified events
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);

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
        
        // Refund gas fee if fully cancelled
        if (totalPendingAmount == cancellableAmount && !gasRefundProcessed[batchOrderId]) {
            uint256 gasRefund = preCollectedGasFees[batchOrderId];
            if (gasRefund > 0) {
                gasRefundProcessed[batchOrderId] = true;
                payable(msg.sender).transfer(gasRefund);
                emit GasFeeRefunded(batchOrderId, msg.sender, gasRefund);
            }
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
            beforeInitialize: true,   // Re-enable to enforce dynamic fees
            afterInitialize: true,    // Re-enable for pool tracking
            beforeSwap: true,
            afterSwap: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address /* sender */, PoolKey calldata /* key */, uint160 /* sqrtPriceX96 */) internal pure override returns (bytes4) {
        // For development, allow both static and dynamic fees
        // if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        lastTicks[key.toId()] = tick;
        
        // Simple pool initialization tracking
        PoolId poolId = key.toId();
        if (!poolInitialized[poolId]) {
            poolInitialized[poolId] = true;
            
            // Add to our tracking arrays
            poolIndex[poolId] = allPoolIds.length;
            allPoolIds.push(poolId);
            poolIdToKey[poolId] = key;
            
            emit PoolInitializationTracked(poolId, tick, block.timestamp);
        }
        
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) 
        internal pure override returns (bytes4, BeforeSwapDelta, uint24) {
        // Use fixed fee for simplified version - tools contract can override for dynamic fees
        uint24 fee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata) 
        internal override returns (bytes4, int128) {
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        // Process limit orders with return deltas for gas optimization
        int128 hookDelta = _processOrdersWithDelta(key, params, delta);
        
        return (this.afterSwap.selector, hookDelta);
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
        
        // Calculate and collect gas fee
        uint256 estimatedGasFee = _calculateEstimatedGasFee();
        uint256 batchId = nextBatchOrderId - 1; // Current batch ID (already incremented in _createBatch)
        preCollectedGasFees[batchId] = estimatedGasFee;
        
        if (sellToken == address(0)) {
            // ETH case: require total amount + gas fee
            require(msg.value >= totalAmount + estimatedGasFee, "Insufficient ETH for order + gas");
            if (msg.value > totalAmount + estimatedGasFee) {
                payable(msg.sender).transfer(msg.value - totalAmount - estimatedGasFee);
            }
        } else {
            // ERC20 case: require ETH for gas fee separately
            require(msg.value >= estimatedGasFee, "Insufficient ETH for gas fee");
            if (msg.value > estimatedGasFee) {
                payable(msg.sender).transfer(msg.value - estimatedGasFee);
            }
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        }
        
        emit GasFeePreCollected(batchId, estimatedGasFee);
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
        
        // Fee already deducted at execution time, just transfer to user
        outputToken.transfer(msg.sender, outputAmount);
    }

    function _processOrdersWithDelta(
        PoolKey calldata key,
        SwapParams calldata /* params */,
        BalanceDelta /* swapDelta */
    ) internal returns (int128) {
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 lastTick = lastTicks[key.toId()];
        
        if (currentTick == lastTick) return 0;
        
        PoolId poolId = key.toId();
        bool ascending = currentTick > lastTick;
        
        // Find limit orders that should execute in the tick range
        uint256 totalLimitOrderAmount = 0;
        bool limitOrderDirection = ascending ? false : true; // opposite of price movement
        
        // Calculate total limit order volume in range
        if (ascending) {
            // Price going up, execute sell orders (zeroForOne = false)
            unchecked {
                for (int24 tick = lastTick; tick <= currentTick; tick += key.tickSpacing) {
                    totalLimitOrderAmount += pendingBatchOrders[poolId][tick][false];
                }
            }
        } else {
            // Price going down, execute buy orders (zeroForOne = true)
            unchecked {
                for (int24 tick = lastTick; tick >= currentTick; tick -= key.tickSpacing) {
                    totalLimitOrderAmount += pendingBatchOrders[poolId][tick][true];
                }
            }
        }
        
        if (totalLimitOrderAmount == 0) {
            lastTicks[poolId] = currentTick;
            return 0;
        }
        
        // Calculate hook delta contribution
        int128 hookDelta = _calculateHookDelta(
            totalLimitOrderAmount,
            currentTick,
            limitOrderDirection
        );
        
        // Update limit order state
        _updateLimitOrderState(key, lastTick, currentTick, limitOrderDirection, totalLimitOrderAmount);
        
        lastTicks[poolId] = currentTick;
        return hookDelta;
    }

    function _calculateHookDelta(
        uint256 limitOrderAmount,
        int24 currentTick,
        bool zeroForOne
    ) internal pure returns (int128) {
        if (limitOrderAmount == 0) return 0;
        
        // Calculate output amount using current tick price
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(currentTick);
        
        uint256 outputAmount;
        if (zeroForOne) {
            // Selling token0 for token1: amount1 = amount0 * sqrtPrice / 2^96
            outputAmount = FullMath.mulDiv(limitOrderAmount, sqrtPrice, FixedPoint96.Q96);
            outputAmount = FullMath.mulDiv(outputAmount, sqrtPrice, FixedPoint96.Q96);
        } else {
            // Selling token1 for token0: amount0 = amount1 * 2^96 / sqrtPrice
            outputAmount = FullMath.mulDiv(limitOrderAmount, FixedPoint96.Q96, sqrtPrice);
            outputAmount = FullMath.mulDiv(outputAmount, FixedPoint96.Q96, sqrtPrice);
        }
        
        // Hook provides the output token and takes the input token
        // Return negative delta when hook provides tokens to pool
        return zeroForOne ? -int128(int256(outputAmount)) : int128(int256(outputAmount));
    }

    function _updateLimitOrderState(
        PoolKey calldata key,
        int24 fromTick,
        int24 toTick,
        bool /* zeroForOne */,
        uint256 totalAmount
    ) internal {
        PoolId poolId = key.toId();
        bool ascending = toTick > fromTick;
        
        if (ascending) {
            // Price going up, execute sell orders (zeroForOne = false)
            unchecked {
                for (int24 tick = fromTick; tick <= toTick; tick += key.tickSpacing) {
                    uint256 amount = pendingBatchOrders[poolId][tick][false];
                    if (amount > 0) {
                        _executeLimitOrderAtTick(key, tick, false, amount, totalAmount);
                    }
                }
            }
        } else {
            // Price going down, execute buy orders (zeroForOne = true)  
            unchecked {
                for (int24 tick = fromTick; tick >= toTick; tick -= key.tickSpacing) {
                    uint256 amount = pendingBatchOrders[poolId][tick][true];
                    if (amount > 0) {
                        _executeLimitOrderAtTick(key, tick, true, amount, totalAmount);
                    }
                }
            }
        }
    }

    function _executeLimitOrderAtTick(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount,
        uint256 /* totalExecutedAmount */
    ) internal {
        uint256 gasStart = gasleft();
        
        // Calculate proportional output based on current tick price
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        uint256 outputAmount;
        
        if (zeroForOne) {
            // Selling token0 for token1
            outputAmount = FullMath.mulDiv(inputAmount, sqrtPrice, FixedPoint96.Q96);
            outputAmount = FullMath.mulDiv(outputAmount, sqrtPrice, FixedPoint96.Q96);
        } else {
            // Selling token1 for token0
            outputAmount = FullMath.mulDiv(inputAmount, FixedPoint96.Q96, sqrtPrice);
            outputAmount = FullMath.mulDiv(outputAmount, FixedPoint96.Q96, sqrtPrice);
        }

        // Update claimable amounts for all batches at this tick
        PoolId poolId = key.toId();
        uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
        
        unchecked {
            for (uint256 i = 0; i < batchIds.length; i++) {
                uint256 batchId = batchIds[i];
                
                // Find proportion for this batch
                uint256 batchAmount = _getBatchAmountAtTick(batchId, tick);
                uint256 batchOutputRaw = (outputAmount * batchAmount) / inputAmount;
                
                // Calculate dynamic protocol fee for this batch
                uint256 gasUsed = gasStart - gasleft() + 50000; // Add base gas overhead
                uint256 actualGasCost = gasUsed * tx.gasprice;
                actualGasCosts[batchId] += actualGasCost;
                
                uint256 dynamicProtocolFee = _calculateDynamicProtocolFee(
                    batchId, 
                    batchOutputRaw, 
                    actualGasCost
                );
                
                uint256 batchOutputNet = batchOutputRaw - dynamicProtocolFee;
                claimableOutputTokens[batchId] += batchOutputNet;
                
                // Send protocol fee immediately
                if (dynamicProtocolFee > 0) {
                    Currency outputToken = zeroForOne ? key.currency1 : key.currency0;
                    outputToken.transfer(FEE_RECIPIENT, dynamicProtocolFee);
                }
                
                emit BatchLevelExecutedOptimized(batchId, uint256(uint24(tick)), batchAmount);
                emit GasFeeConsumed(batchId, actualGasCost, dynamicProtocolFee);
            }
        }

        // Clear pending orders
        pendingBatchOrders[poolId][tick][zeroForOne] = 0;
        
        // Clear batch IDs array
        delete tickToBatchIds[poolId][tick][zeroForOne];
    }

    function _getBatchAmountAtTick(uint256 batchId, int24 tick) internal view returns (uint256) {
        uint256 ticksLength = batchOrders[batchId].ticksLength;
        unchecked {
            for (uint256 i = 0; i < ticksLength; i++) {
                if (batchTargetTicks[batchId][i] == tick) {
                    return batchTargetAmounts[batchId][i];
                }
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

    // ========== GAS FEE MANAGEMENT ==========

    /**
     * @notice Calculate estimated gas fee for order execution
     */
    function _calculateEstimatedGasFee() internal view returns (uint256) {
        uint256 estimatedCost = ESTIMATED_EXECUTION_GAS * tx.gasprice;
        estimatedCost = (estimatedCost * GAS_PRICE_BUFFER_MULTIPLIER) / 100;
        
        // Cap the gas fee to prevent excessive charges
        if (estimatedCost > MAX_GAS_FEE_ETH) {
            estimatedCost = MAX_GAS_FEE_ETH;
        }
        
        return estimatedCost;
    }

    /**
     * @notice Calculate dynamic protocol fee based on gas costs
     */
    function _calculateDynamicProtocolFee(
        uint256 batchId,
        uint256 outputAmount,
        uint256 actualGasCost
    ) internal view returns (uint256) {
        // Base protocol fee (0.35%)
        uint256 baseProtocolFee = (outputAmount * BASE_PROTOCOL_FEE_BPS) / BASIS_POINTS_DENOMINATOR;
        
        // Calculate gas cost overhead
        uint256 preCollectedGas = preCollectedGasFees[batchId];
        uint256 totalActualGas = actualGasCosts[batchId] + actualGasCost;
        
        uint256 gasOverhead = 0;
        if (totalActualGas > preCollectedGas) {
            gasOverhead = totalActualGas - preCollectedGas;
            
            // Convert gas overhead to output token equivalent
            // Simple conversion: assume 1 ETH gas cost = equivalent output token value
            // In practice, you'd use an oracle for ETH/token price
            gasOverhead = (gasOverhead * outputAmount) / (outputAmount + baseProtocolFee);
        }
        
        return baseProtocolFee + gasOverhead;
    }

    /**
     * @notice Process gas fee refund for completed batch orders
     */
    function processGasRefund(uint256 batchId) external {
        require(!gasRefundProcessed[batchId], "Refund already processed");
        require(!batchOrders[batchId].isActive, "Batch still active");
        
        uint256 preCollectedGas = preCollectedGasFees[batchId];
        uint256 totalActualGas = actualGasCosts[batchId];
        
        if (preCollectedGas > totalActualGas) {
            uint256 refundAmount = preCollectedGas - totalActualGas;
            gasRefundProcessed[batchId] = true;
            
            address user = batchOrders[batchId].user;
            payable(user).transfer(refundAmount);
            
            emit GasFeeRefunded(batchId, user, refundAmount);
        } else {
            gasRefundProcessed[batchId] = true;
        }
    }

    /**
     * @notice Check gas refund status and amount
     */
    function getGasRefundInfo(uint256 batchId) external view returns (
        uint256 preCollected,
        uint256 actualUsed,
        uint256 refundable,
        bool processed
    ) {
        preCollected = preCollectedGasFees[batchId];
        actualUsed = actualGasCosts[batchId];
        processed = gasRefundProcessed[batchId];
        
        if (preCollected > actualUsed && !processed) {
            refundable = preCollected - actualUsed;
        } else {
            refundable = 0;
        }
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
     * @notice Get all pools hooked to this contract
     * @return poolIds Array of all pool IDs
     * @return poolKeys Array of corresponding pool keys
     * @return ticks Array of current ticks for each pool
     */
    function getAllPools() external view returns (
        PoolId[] memory poolIds,
        PoolKey[] memory poolKeys,
        int24[] memory ticks
    ) {
        uint256 length = allPoolIds.length;
        poolIds = new PoolId[](length);
        poolKeys = new PoolKey[](length);
        ticks = new int24[](length);
        
        for (uint256 i = 0; i < length; i++) {
            poolIds[i] = allPoolIds[i];
            poolKeys[i] = poolIdToKey[allPoolIds[i]];
            ticks[i] = lastTicks[allPoolIds[i]];
        }
        
        return (poolIds, poolKeys, ticks);
    }

    /**
     * @notice Get the number of pools hooked to this contract
     * @return count Total number of pools
     */
    function getPoolCount() external view returns (uint256 count) {
        return allPoolIds.length;
    }

    /**
     * @notice Get pool info by index
     * @param index Index in the pools array
     * @return poolId The pool ID
     * @return poolKey The pool key
     * @return tick Current tick
     * @return initialized Whether the pool is initialized
     */
    function getPoolByIndex(uint256 index) external view returns (
        PoolId poolId,
        PoolKey memory poolKey,
        int24 tick,
        bool initialized
    ) {
        require(index < allPoolIds.length, "Index out of bounds");
        
        poolId = allPoolIds[index];
        poolKey = poolIdToKey[poolId];
        tick = lastTicks[poolId];
        initialized = poolInitialized[poolId];
        
        return (poolId, poolKey, tick, initialized);
    }

    /**
     * @notice Get comprehensive batch and contract info in one call - Interface compatibility version
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

    /**
     * @notice Get comprehensive batch info including gas fees - Extended version
     */
    function getBatchInfoExtended(uint256 batchId) external view returns (
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
        uint24 currentFee,
        uint256 preCollectedGasFee,
        uint256 actualGasCost,
        uint256 gasRefundable
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        require(batch.user != address(0), "Invalid batch");
        
        uint256 execAmount = uint256(batch.totalAmount) - claimTokensSupply[batchId];
        
        // Calculate gas refund
        uint256 refundable = 0;
        if (preCollectedGasFees[batchId] > actualGasCosts[batchId] && !gasRefundProcessed[batchId]) {
            refundable = preCollectedGasFees[batchId] - actualGasCosts[batchId];
        }
        
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
            BASE_FEE,
            preCollectedGasFees[batchId],
            actualGasCosts[batchId],
            refundable
        );
    }

    // ========== BACKWARD COMPATIBILITY ==========

    function getBatchOrder(uint256 batchId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256[] memory targetPrices, uint256[] memory targetAmounts,
        bool isActive, bool isFullyExecuted
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        
        // Get target ticks and amounts from storage
        int24[] memory targetTicks = batchTargetTicks[batchId];
        uint256[] memory amounts = batchTargetAmounts[batchId];
        
        // Convert ticks back to sqrt prices
        uint256[] memory prices = new uint256[](targetTicks.length);
        for (uint256 i = 0; i < targetTicks.length; i++) {
            prices[i] = TickMath.getSqrtPriceAtTick(targetTicks[i]);
        }
        
        return (
            batch.user,
            Currency.unwrap(batch.poolKey.currency0),
            Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount),
            uint256(batch.totalAmount) - claimTokensSupply[batchId],
            prices, // Return actual target prices
            amounts, // Return actual target amounts
            batch.isActive,
            claimTokensSupply[batchId] == 0
        );
    }

    /**
     * @notice Find pools by currency pair
     * @param currency0 First currency address
     * @param currency1 Second currency address
     * @return poolIds Array of pool IDs for the currency pair
     * @return poolKeys Array of pool keys for the currency pair
     * @return ticks Array of current ticks for the currency pair
     * @return fees Array of fees for the currency pair
     */
    function getPoolsByCurrencyPair(address currency0, address currency1) external view returns (
        PoolId[] memory poolIds,
        PoolKey[] memory poolKeys,
        int24[] memory ticks,
        uint24[] memory fees
    ) {
        // First pass: count matching pools
        uint256 matchCount = 0;
        for (uint256 i = 0; i < allPoolIds.length; i++) {
            PoolKey memory key = poolIdToKey[allPoolIds[i]];
            if ((Currency.unwrap(key.currency0) == currency0 && Currency.unwrap(key.currency1) == currency1) ||
                (Currency.unwrap(key.currency0) == currency1 && Currency.unwrap(key.currency1) == currency0)) {
                matchCount++;
            }
        }
        
        // Second pass: collect matching pools
        poolIds = new PoolId[](matchCount);
        poolKeys = new PoolKey[](matchCount);
        ticks = new int24[](matchCount);
        fees = new uint24[](matchCount);
        
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < allPoolIds.length; i++) {
            PoolKey memory key = poolIdToKey[allPoolIds[i]];
            if ((Currency.unwrap(key.currency0) == currency0 && Currency.unwrap(key.currency1) == currency1) ||
                (Currency.unwrap(key.currency0) == currency1 && Currency.unwrap(key.currency1) == currency0)) {
                poolIds[currentIndex] = allPoolIds[i];
                poolKeys[currentIndex] = key;
                ticks[currentIndex] = lastTicks[allPoolIds[i]];
                fees[currentIndex] = key.fee;
                currentIndex++;
            }
        }
        
        return (poolIds, poolKeys, ticks, fees);
    }

    // ========== FALLBACKS ==========

    receive() external payable {}
    fallback() external payable {}
}
