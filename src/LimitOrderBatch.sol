// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILimitOrderBatch} from "./interfaces/ILimitOrderBatch.sol";
import {ERC6909Base} from "./base/ERC6909Base.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BaseHook} from "@uniswap/v4-periphery/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

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
    
    // ========== EVENTS ==========

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
    
    mapping(uint256 => BatchInfo) public batchInfos;
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
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    
    // Gas estimation constants
    uint256 public constant ESTIMATED_EXECUTION_GAS = 200000;
    uint256 public constant GAS_PRICE_BUFFER_MULTIPLIER = 120; // 20% buffer
    uint256 public constant MAX_GAS_FEE_ETH = 0.01 ether; // Maximum gas fee cap

    // Tools constants (minimal)
    address public owner;

    // ========== ERRORS ==========
    
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    error MustUseDynamicFee();
    error SlippageExceeded();

    // ========== EVENTS ==========
    
    event BatchLevelExecutedOptimized(uint256 indexed batchId, uint256 tick, uint256 amount);
    event BatchOrderCancelledOptimized(uint256 indexed batchId, address indexed user);
    event TokensRedeemedOptimized(uint256 indexed batchId, address indexed user, uint256 amount);
    event GasPriceTrackedOptimized(uint128 gasPrice, uint128 newAverage, uint104 count);
    
    // Gas fee events
    event GasFeePreCollected(uint256 indexed batchId, uint256 estimatedGasFee);
    event GasFeeConsumed(uint256 indexed batchId, uint256 actualGasCost, uint256 protocolFee);
    event GasFeeRefunded(uint256 indexed batchId, address indexed user, uint256 refundAmount);
    
    // Liquidity events
    event LiquidityProvisionAttempted(PoolId indexed poolId, uint256 amount, bool zeroForOne);
    event LiquidityAdded(PoolId indexed poolId, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper);
    event LiquidityAdditionFailed(PoolId indexed poolId, uint256 amount, string reason);
    event LimitOrderAsLiquidityCreated(uint256 indexed batchId, address indexed user, PoolId indexed poolId, int24 tick, uint256 amount);
    
    // Simplified events
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);

    // ========== MODIFIERS ==========
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not contract owner");
        _;
    }

    modifier validBatchOrder(uint256 batchId) {
        require(batchId > 0 && batchId < nextBatchOrderId, "Invalid batch ID");
        require(batchInfos[batchId].isActive, "Order not active");
        _;
    }

    // ========== CONSTRUCTOR ==========
    
    constructor(IPoolManager _poolManager, address _feeRecipient, address _owner) 
        BaseHook(_poolManager) 
    {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_owner != address(0), "Invalid owner");
        owner = _owner;
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


    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Create a batch limit order with optional liquidity provision
     * @param currency0 First token address 
     * @param currency1 Second token address
     * @param fee Pool fee tier
     * @param zeroForOne Direction of the trade
     * @param targetPrices Array of target prices for execution
     * @param targetAmounts Array of amounts for each price level
     * @param deadline Expiration time for the order
     * @param provideLiquidity Choose order execution method:
     *        - false: Traditional limit orders (stored separately, executed via afterSwap)
     *        - true: Liquidity-based limit orders (added as concentrated liquidity, earns fees)
     * @return batchId The ID of the created batch order
     * 
     * @dev Traditional vs Liquidity-based limit orders:
     * 
     * Traditional (provideLiquidity = false):
     * - Orders stored in mapping, executed when price crosses tick
     * - Exact price execution, no fee earning while waiting
     * - Better for short-term traders who want precise fills
     * 
     * Liquidity-based (provideLiquidity = true):
     * - Orders become concentrated liquidity at target ticks
     * - Earn trading fees while waiting for execution
     * - Capital is productive, helps pool liquidity
     * - Better for longer-term positions
     */
    function createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint256 deadline,
        bool provideLiquidity // New parameter: true = provide liquidity at target ticks, false = traditional limit orders
    ) external payable virtual returns (uint256 batchId) {
        _validateOrderInputs(targetPrices, targetAmounts, deadline, currency0, currency1);
        
        PoolKey memory key = _createPoolKey(currency0, currency1, fee);
        
        // Check if pool exists
        (uint160 currentPrice, , , ) = StateLibrary.getSlot0(poolManager, key.toId());
        require(currentPrice > 0, "Pool does not exist");
        
        int24[] memory targetTicks = _pricesToTicks(targetPrices);
        uint256 totalAmount = _sumAmounts(targetAmounts);
        
        batchId = _createBatch(key, targetTicks, targetAmounts, totalAmount, zeroForOne, deadline);
        _handleTokenDeposit(key, zeroForOne, totalAmount);
        
        // Optional: Provide liquidity at target ticks instead of traditional limit orders
        if (provideLiquidity) {
            _createLimitOrderAsLiquidity(key, targetTicks, targetAmounts, zeroForOne, batchId);
        }
        
        emit BatchOrderCreated(batchId, msg.sender, currency0, currency1, totalAmount, targetPrices, targetAmounts);
        
        return batchId;
    }

    /**
     * @notice Settle batch order - redeems executed portions or cancels unexecuted portions
     */
    function settleOrder(uint256 batchOrderId) external validBatchOrder(batchOrderId) {
        BatchInfo storage batch = batchInfos[batchOrderId];
        require(batch.user == msg.sender, "Not authorized");
        
        uint256 userClaimBalance = balanceOf[msg.sender][batchOrderId];
        require(userClaimBalance > 0, "No tokens to settle");
        
        // Check if there are claimable output tokens (executed portions)
        uint256 claimableOutput = claimableOutputTokens[batchOrderId];
        
        if (claimableOutput > 0) {
            // REDEEM: There are executed portions to claim
            uint256 userShare = (claimableOutput * userClaimBalance) / claimTokensSupply[batchOrderId];
            
            // Update state for redemption
            claimableOutputTokens[batchOrderId] -= userShare;
            claimTokensSupply[batchOrderId] -= userClaimBalance;
            _burn(msg.sender, address(uint160(batchOrderId)), userClaimBalance);
            
            // Transfer output tokens
            Currency outputToken = batch.zeroForOne ? batch.poolKey.currency1 : batch.poolKey.currency0;
            outputToken.transfer(msg.sender, userShare);
            
            emit TokensRedeemedOptimized(batchOrderId, msg.sender, userShare);
            
        } else {
            // CANCEL: No executed portions, cancel remaining unexecuted amounts
            PoolId poolId = batch.poolKey.toId();
            uint256 totalPendingAmount = 0;
            for (uint256 i = 0; i < batch.ticksLength; i++) {
                totalPendingAmount += pendingBatchOrders[poolId][batchTargetTicks[batchOrderId][i]][batch.zeroForOne];
            }
            
            require(totalPendingAmount > 0, "Nothing to settle");
            
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
            
            // Return input tokens
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

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata) 
        internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Skip hook processing if the sender is this contract (to avoid recursion)
        if (sender == address(this)) {
            uint24 baseFee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, baseFee);
        }

        // Set fee and let swap proceed normally
        // All limit order execution happens in afterSwap
        uint24 fee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata) 
        internal override returns (bytes4, int128) {
        // Update last tick for tracking price movement
        (, int24 newTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        lastTicks[key.toId()] = newTick;
        
        return (BaseHook.afterSwap.selector, 0);
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

    /**
     * @notice Add liquidity to pool using deposited tokens from batch orders
     * @dev This function is called after tokens are deposited to provide initial liquidity
     */
    function _addLiquidityFromDeposit(
        PoolKey memory key, 
        bool zeroForOne, 
        uint256 totalAmount
    ) internal {
        // Skip if amount is too small for meaningful liquidity
        if (totalAmount < 1000) return;
        
        // Use a portion of the deposited amount to add liquidity to the pool
        // This ensures that when account 2 tries to execute swaps, there's liquidity available
        uint256 liquidityAmount = totalAmount / 4; // Use 25% for liquidity provision
        
        if (liquidityAmount == 0) return;
        
        // Add liquidity through unlock callback
        bytes memory liquidityData = abi.encode(
            key,
            liquidityAmount,
            zeroForOne,
            "ADD_LIQUIDITY"
        );
        
        try poolManager.unlock(liquidityData) {
            // Liquidity added successfully
            emit LiquidityAdded(key.toId(), liquidityAmount, liquidityAmount, 0, 0);
        } catch {
            // If liquidity addition fails, continue without it
            // The pool initialization is more important than liquidity
            emit LiquidityAdditionFailed(key.toId(), liquidityAmount, "Unlock failed");
        }
    }

    /**
     * @notice Create limit orders as concentrated liquidity at exact ticks
     * @param key The pool key
     * @param targetTicks Array of target ticks for orders
     * @param targetAmounts Array of amounts for each tick
     * @param zeroForOne Direction of the orders
     * @param batchId The batch ID for tracking positions
     */
    function _createLimitOrderAsLiquidity(
        PoolKey memory key,
        int24[] memory targetTicks,
        uint256[] memory targetAmounts,
        bool zeroForOne,
        uint256 batchId
    ) internal {
        for (uint256 i = 0; i < targetTicks.length; i++) {
            if (targetAmounts[i] == 0) continue;
            
            int24 targetTick = targetTicks[i];
            uint256 amount = targetAmounts[i];
            
            // Create concentrated liquidity at exactly one tick
            // This liquidity will only be active when price is at this exact level
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: targetTick,
                tickUpper: targetTick + key.tickSpacing, // Single tick range
                liquidityDelta: int256(amount),
                salt: bytes32(uint256(keccak256(abi.encode(msg.sender, batchId, i))))
            });
            
            try poolManager.modifyLiquidity(key, params, "") {
                // Track this liquidity position for the user
                _trackLiquidityPosition(key, targetTick, amount, batchId, i);
                
                emit LiquidityAdded(
                    key.toId(), 
                    zeroForOne ? amount : 0, 
                    zeroForOne ? 0 : amount, 
                    targetTick, 
                    targetTick + key.tickSpacing
                );
            } catch {
                // If liquidity provision fails for this tick, continue with others
                emit LiquidityAdditionFailed(key.toId(), amount, "ModifyLiquidity failed");
            }
        }
    }

    /**
     * @notice Track liquidity positions for batch orders
     * @param key The pool key
     * @param tick The tick where liquidity was added
     * @param amount The amount of liquidity
     * @param batchId The batch ID
     * @param index The index within the batch
     */
    function _trackLiquidityPosition(
        PoolKey memory key,
        int24 tick,
        uint256 amount,
        uint256 batchId,
        uint256 index
    ) internal {
        // Store position info for potential withdrawal later
        bytes32 positionKey = keccak256(abi.encode(msg.sender, batchId, index));
        
        // You could add a mapping to track positions:
        // liquidityPositions[positionKey] = LiquidityPosition({
        //     owner: msg.sender,
        //     poolId: key.toId(),
        //     tick: tick,
        //     amount: amount,
        //     active: true
        // });
        
        // Emit event for tracking limit order as liquidity
        emit LimitOrderAsLiquidityCreated(batchId, msg.sender, key.toId(), tick, amount);
    }

    /**
     * @notice Internal function to add general liquidity
     * @dev Simplified to not fail batch order creation
     */


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
        
        batchInfos[batchId] = BatchInfo({
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
        BatchInfo storage batch = batchInfos[batchOrderId];
        Currency outputToken = batch.zeroForOne ? batch.poolKey.currency1 : batch.poolKey.currency0;
        
        // Fee already deducted at execution time, just transfer to user
        outputToken.transfer(msg.sender, outputAmount);
    }

    /// @notice Check if any limit orders should execute based on price movement

    function _getBatchAmountAtTick(uint256 batchId, int24 tick) internal view returns (uint256) {
        uint256 ticksLength = batchInfos[batchId].ticksLength;
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
        require(!batchInfos[batchId].isActive, "Batch still active");
        
        uint256 preCollectedGas = preCollectedGasFees[batchId];
        uint256 totalActualGas = actualGasCosts[batchId];
        
        if (preCollectedGas > totalActualGas) {
            uint256 refundAmount = preCollectedGas - totalActualGas;
            gasRefundProcessed[batchId] = true;
            
            address user = batchInfos[batchId].user;
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
        // Decode the operation type from the first part of data
        if (data.length > 64) {
            // Try to decode as general liquidity operation
            (string memory operationType) = abi.decode(data, (string));
            
            if (keccak256(abi.encodePacked(operationType)) == keccak256(abi.encodePacked("general_liquidity"))) {
                (, PoolKey memory key, ModifyLiquidityParams memory liquidityParams) = abi.decode(data, (string, PoolKey, ModifyLiquidityParams));
                return _handleGeneralLiquidityOperation(key, liquidityParams);
            }
            
            // Try to decode as batch order liquidity operation
            try this._decodeLiquidityOperation(data) returns (
                PoolKey memory liquidityKey,
                uint256 amount,
                bool zeroForOne,
                string memory batchOperation
            ) {
                if (keccak256(abi.encodePacked(batchOperation)) == keccak256(abi.encodePacked("ADD_LIQUIDITY"))) {
                    return _handleLiquidityOperation(liquidityKey, amount, zeroForOne);
                }
            } catch {
                // Not a liquidity operation, continue to swap handling
            }
        }
        
        // Default: handle as swap operation
        (PoolKey memory swapKey, SwapParams memory swapParams) = abi.decode(data, (PoolKey, SwapParams));
        BalanceDelta delta = poolManager.swap(swapKey, swapParams, "");
        return abi.encode(delta);
    }

    /**
     * @notice Handle general liquidity addition operations
     */
    function _handleGeneralLiquidityOperation(
        PoolKey memory key,
        ModifyLiquidityParams memory params
    ) internal returns (bytes memory) {
        // Add liquidity to the pool
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
        
        // Settle the deltas by sending tokens to pool manager
        if (delta.amount0() > 0) {
            // Send token0 (ETH or ERC20)
            if (Currency.unwrap(key.currency0) == address(0)) {
                // ETH - settle with the sent value
                poolManager.settle{value: uint256(int256(delta.amount0()))}();
            } else {
                // ERC20 token - transfer and settle
                Currency.wrap(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint256(int256(delta.amount0())));
                poolManager.settle();
            }
        }
        
        if (delta.amount1() > 0) {
            // Send token1 (always ERC20) - transfer and settle
            Currency.wrap(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint256(int256(delta.amount1())));
            poolManager.settle();
        }
        
        return abi.encode(delta);
    }

    /**
     * @notice Helper to decode liquidity operation data (external for try/catch)
     */
    function _decodeLiquidityOperation(bytes calldata data) external pure returns (
        PoolKey memory key,
        uint256 amount,
        bool zeroForOne,
        string memory operation
    ) {
        return abi.decode(data, (PoolKey, uint256, bool, string));
    }

    /**
     * @notice Handle adding liquidity when unlocked
     */
    function _handleLiquidityOperation(
        PoolKey memory key,
        uint256 amount,
        bool zeroForOne
    ) internal returns (bytes memory) {
        // Get current pool state
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        
        // Calculate wide tick range for liquidity provision
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = currentTick - (100 * tickSpacing);
        int24 tickUpper = currentTick + (100 * tickSpacing);
        
        // Ensure ticks are aligned
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;
        
        // Calculate liquidity delta (simplified calculation)
        uint128 liquidityDelta = uint128(amount / 100); // Conservative amount
        if (liquidityDelta == 0) liquidityDelta = 1000;
        
        // Create ModifyLiquidityParams struct
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityDelta)),
            salt: bytes32(uint256(block.timestamp))
        });
        
        // Add liquidity to the pool
        (BalanceDelta callerDelta, ) = poolManager.modifyLiquidity(key, params, "");
        
        return abi.encode(callerDelta);
    }

    // ========== MANUAL EXECUTION FUNCTIONS ==========

    /**
     * @notice Execute a specific batch order level at current market price
     */
    function executeBatchLevel(uint256 batchId, uint256 levelIndex) external returns (bool isFullyExecuted) {
        BatchInfo storage batch = batchInfos[batchId];
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
        BatchInfo storage batch = batchInfos[batchId];
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
        BatchInfo storage batch = batchInfos[batchId];
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
        BatchInfo storage batch = batchInfos[batchId];
        
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

    // ========== LIMIT ORDER PROCESSING HELPERS ==========

    /**
     * @notice Calculate target tick from sqrtPriceLimitX96
     */
    function _getTargetTick(uint160 sqrtPriceLimitX96, bool zeroForOne) internal pure returns (int24) {
        if (sqrtPriceLimitX96 == 0) {
            return zeroForOne ? TickMath.MIN_TICK : TickMath.MAX_TICK;
        }
        return TickMath.getTickAtSqrtPrice(sqrtPriceLimitX96);
    }

    /**
     * @notice Find limit orders in the tick range that can be executed
     */
    function _findLimitOrdersInRange(
        PoolId poolId,
        int24 currentTick,
        int24 targetTick,
        bool zeroForOne,
        int24 tickSpacing
    ) internal view returns (uint256 totalAmount, bool hasOrders) {
        totalAmount = 0;
        hasOrders = false;

        if (zeroForOne) {
            // Selling token0 for token1 (price going down)
            // Execute buy orders (opposite direction orders) that are at higher ticks
            for (int24 tick = currentTick; tick >= targetTick; tick -= tickSpacing) {
                uint256 amount = pendingBatchOrders[poolId][tick][false]; // false = buy orders
                if (amount > 0) {
                    totalAmount += amount;
                    hasOrders = true;
                }
            }
        } else {
            // Buying token0 with token1 (price going up) 
            // Execute sell orders (opposite direction orders) that are at lower ticks
            for (int24 tick = currentTick; tick <= targetTick; tick += tickSpacing) {
                uint256 amount = pendingBatchOrders[poolId][tick][true]; // true = sell orders
                if (amount > 0) {
                    totalAmount += amount;
                    hasOrders = true;
                }
            }
        }
    }

    /**
     * @notice Utility function to get minimum of two values
     */
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ========== PUBLIC LIQUIDITY FUNCTIONS ==========
    
    /**
     * @notice Add general liquidity to a pool for trading
     * @dev This provides liquidity across a wide price range for general trading
     */
    function addGeneralLiquidity(
        address currency0,
        address currency1,
        uint24 fee,
        uint256 amount0,
        uint256 amount1
    ) external payable {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: 60, // Standard tick spacing for dynamic fee
            hooks: IHooks(address(this))
        });
        
        // Wide range for general liquidity: -600 to +600 ticks
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: int256(amount0 + amount1), // Use total amount as liquidity
            salt: bytes32(0)
        });
        
        // Add liquidity through unlock callback
        poolManager.unlock(abi.encode("general_liquidity", key, params));
        
        emit LiquidityAdded(key.toId(), amount0, amount1, -600, 600);
    }
    // ========== FALLBACKS ==========

    receive() external payable {}
    fallback() external payable {}
}
