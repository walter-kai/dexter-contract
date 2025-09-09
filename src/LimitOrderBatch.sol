// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILimitOrderBatch} from "./interfaces/ILimitOrderBatch.sol";
import {ERC6909Base} from "./base/ERC6909Base.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
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
    uint256 public constant BASE_PROTOCOL_FEE_BPS = 35; // 0.35% base protocol fee
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    
    // Gas estimation constants 
    // @note how this calculated 
    uint256 public constant ESTIMATED_EXECUTION_GAS = 150000; // Conservative estimate
    uint256 public constant GAS_PRICE_BUFFER_MULTIPLIER = 120; // 20% buffer (120%)
    uint256 public constant MAX_GAS_FEE_ETH = 0.01 ether; // Cap at 0.01 ETH
    
    // Tools constants (minimal)

    // @note used bly once we dont sent any fee there 
    address public immutable FEE_RECIPIENT;
    address public Executor; 

    

    // ========== ERRORS ==========
    error MustUseDynamicFee();
    error NothingToClaim();
    error InvalidBatchId();
    error OrderNotActive();
    error NotAuthorized();
    error NoTokensToCancel();
    error BatchAlreadyExecutedUseRedeem();
    error NothingToCancel();
    error InsufficientClaimTokenBalance();
    error InsufficientETHForOrderPlusGas();
    error InsufficientETHForGasFee();
    error RefundAlreadyProcessed();
    error BatchStillActive();
    error InvalidFeeRecipient();
    error InvalidExecutorAddress();
    error InvalidArrays();
    error ExpiredDeadline();
    error SameCurrencies();
    error EmptyArrays();
    error InvalidAmount();
    error InvalidTotal();
    error NoPendingOrders();
    error InvalidExecution();
    error InvalidBatch();

    // ========== EVENTS ==========
    
    event BatchOrderCreatedOptimized(uint256 indexed batchId, address indexed user, uint256 totalAmount);
    event BatchOrderCancelledOptimized(uint256 indexed batchId, address indexed user);
    event TokensRedeemedOptimized(uint256 indexed batchId, address indexed user, uint256 amount);
    
    // Gas fee events
    event GasFeePreCollected(uint256 indexed batchId, uint256 estimatedGasFee);
    event GasFeeRefunded(uint256 indexed batchId, address indexed user, uint256 refundAmount);
    
    // Liquidity events
    event LiquidityAdded(PoolId indexed poolId, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper);
    event LiquidityAdditionFailed(PoolId indexed poolId, uint256 amount, string reason);
    
    // Simplified events
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);

    // ========== MODIFIERS ==========
    modifier validBatchOrder(uint256 batchId) {
        if (!(batchId > 0 && batchId < nextBatchOrderId)) revert InvalidBatchId();
        if (!batchOrders[batchId].isActive) revert OrderNotActive();
        _;
    }

    // ========== CONSTRUCTOR ==========
    
    constructor(IPoolManager _poolManager, address _feeRecipient, address _executor) 
        BaseHook(_poolManager) 
    {
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (_executor == address(0)) revert InvalidExecutorAddress();
        Executor = _executor;
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
        uint32 slippage,
        uint256 deadline
    ) external payable virtual returns (uint256 batchId) {
        return _createBatchOrderInternal(
            currency0,
            currency1,
            fee,
            zeroForOne,
            targetPrices,
            targetAmounts,
            slippage,
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
        uint32 slippage,
        uint256 deadline
    ) internal returns (uint256 batchId) {
        _validateOrderInputs(targetPrices, targetAmounts, deadline, currency0, currency1);
        
        PoolKey memory key = _createPoolKey(currency0, currency1, fee);
        
        // Initialize pool if it doesn't exist
        _ensurePoolInitialized(key);
        
        int24[] memory targetTicks = _pricesToTicks(targetPrices);
        uint256 totalAmount = _sumAmounts(targetAmounts);
        
        batchId = _createBatch(key, targetTicks, targetAmounts, totalAmount, zeroForOne, slippage, deadline);
        _handleTokenDeposit(key, zeroForOne, totalAmount);
        
        // Add liquidity using a portion of the deposited tokens
        // _addLiquidityFromDeposit(key, zeroForOne, totalAmount);
        
        emit BatchOrderCreated(batchId, msg.sender, currency0, currency1, totalAmount, targetPrices, targetAmounts);
        emit BatchOrderCreatedOptimized(batchId, msg.sender, totalAmount);
        
        return batchId;
    }

    /**
     * @notice Cancel batch order - refunds only the unexecuted portion
     */
    function cancelBatchOrder(uint256 batchOrderId) external validBatchOrder(batchOrderId) {
        BatchInfo storage batch = batchOrders[batchOrderId];
        if (batch.user != msg.sender) revert NotAuthorized();
        
        uint256 userClaimBalance = balanceOf[msg.sender][batchOrderId];
        if (userClaimBalance == 0) revert NoTokensToCancel();
        
        // Check total pending amount
        PoolId poolId = batch.poolKey.toId();
        uint256 totalPendingAmount = 0;
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            totalPendingAmount += pendingBatchOrders[poolId][batchTargetTicks[batchOrderId][i]][batch.zeroForOne];
        }
        
        if (totalPendingAmount == 0) revert BatchAlreadyExecutedUseRedeem();
        
        uint256 cancellableAmount = userClaimBalance * totalPendingAmount / uint256(batch.totalAmount);
        if (cancellableAmount == 0) revert NothingToCancel();
        
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
            (bool success, ) = payable(msg.sender).call{value: cancellableAmount}("");
            require(success, "Failed Transaction");
        } else {
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(msg.sender, cancellableAmount);
        }
        
        // Refund gas fee if fully cancelled
        if (totalPendingAmount == cancellableAmount && !gasRefundProcessed[batchOrderId]) {
            uint256 gasRefund = preCollectedGasFees[batchOrderId];
            if (gasRefund > 0) {
                gasRefundProcessed[batchOrderId] = true;
                (bool success,) = payable(msg.sender).call{value: gasRefund}("");
                require(success, "Failed transaction");
                emit GasFeeRefunded(batchOrderId, msg.sender, gasRefund);
            }
        }
        
        emit BatchOrderCancelledOptimized(batchOrderId, msg.sender);
    }

    /**
     * @notice Redeem executed order output tokens
     */
    function redeemBatchOrder(uint256 batchOrderId, uint256 inputAmountToClaimFor) external {
        if (claimableOutputTokens[batchOrderId] == 0) revert NothingToClaim();
        if (balanceOf[msg.sender][batchOrderId] < inputAmountToClaimFor) revert InsufficientClaimTokenBalance();

        // Calculate proportional output
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            claimableOutputTokens[batchOrderId],
            claimTokensSupply[batchOrderId]
        );

        // Update state
        claimableOutputTokens[batchOrderId] -= outputAmount;
        claimTokensSupply[batchOrderId] -= inputAmountToClaimFor;
        _burn(msg.sender, address(uint160(batchOrderId)), inputAmountToClaimFor);

        _transfer(batchOrderId, outputAmount);

        emit TokensRedeemedOptimized(batchOrderId, msg.sender, outputAmount);
    }
    /**
     * @notice Execute a specific batch order level at current market price
     */
    function executeBatchLevel(uint256 batchId, uint256 levelIndex) external returns (bool isFullyExecuted) {
        BatchInfo storage batch = batchOrders[batchId];
        if (!(batch.isActive && msg.sender == Executor && levelIndex < batch.ticksLength)) revert InvalidExecution();
        
        PoolId poolId = batch.poolKey.toId();
        int24 targetTick = batchTargetTicks[batchId][levelIndex];
        uint256 pendingAmount = pendingBatchOrders[poolId][targetTick][batch.zeroForOne];
        if (pendingAmount == 0) revert NoPendingOrders();
        
        uint256 amountToExecute = batchTargetAmounts[batchId][levelIndex];
        if (pendingAmount < amountToExecute) amountToExecute = pendingAmount;
        
        // Perform swap
        SwapParams memory params = SwapParams({
            zeroForOne: batch.zeroForOne,
            amountSpecified: -int256(amountToExecute),
            // @note we can disactive this by setting it to zero  
            sqrtPriceLimitX96: batch.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        
        bytes memory result = poolManager.unlock(abi.encode(batch.poolKey, params));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        uint256 outputAmount = batch.zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        
        // Update state
        claimableOutputTokens[batchId] -= outputAmount;
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
    
    // ========== CALLBACK ==========
    // @audit only poolmanager should be able call this ?? 
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

    ////////////////////////   BASEHOOK FUNCTIONS  ////////////////////////

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
            afterSwapReturnDelta: false, 
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    function _beforeInitialize(address /* sender */, PoolKey calldata  key , uint160 /* sqrtPriceX96 */) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        lastTicks[key.toId()] = tick;
        
        // Simple pool initialization tracking
        PoolId poolId = key.toId();
        poolInitialized[poolId] = true;
            
        // Add to our tracking arrays
        poolIndex[poolId] = allPoolIds.length;
        allPoolIds.push(poolId);
        poolIdToKey[poolId] = key;
            
        emit PoolInitializationTracked(poolId, tick, block.timestamp);
        
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata) 
        internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Skip hook processing if the sender is this contract (to avoid recursion)
        if (msg.sender == address(this)) {
            uint24 baseFee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, baseFee);
        }

        // Process limit orders that can satisfy the swap
        BeforeSwapDelta delta = _processLimitOrdersBeforeSwap(key, params);
        
        // Use fixed fee for simplified version - tools contract can override for dynamic fees
        uint24 fee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, delta, fee);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata) 
        internal override returns (bytes4, int128) {
        // Skip hook processing if the sender is this contract (to avoid recursion)
        if (msg.sender == address(this)) return (BaseHook.afterSwap.selector, 0);


        // Update last tick for tracking price movement
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        lastTicks[key.toId()] = currentTick;
        
        return (BaseHook.afterSwap.selector, 0);
    }
    

    //////////////////  INTERNAL FUNCTIONS  /////////////////
    /**
     * @notice Process limit orders before a swap to potentially satisfy swap demand
     * @param key The pool key
     * @param params The swap parameters
     * @return delta The before swap delta representing limit order execution
     */
    function _processLimitOrdersBeforeSwap(PoolKey calldata key, SwapParams calldata params) 
        internal returns (BeforeSwapDelta) {
        
        // Check if pool is initialized by checking if currentTick is accessible
        // If this fails, it means the pool isn't initialized yet
        int24 currentTick;
        try this.getPoolCurrentTick(key.toId()) returns (int24 tick) {
            currentTick = tick;
        } catch {
            // Pool not initialized, return zero delta to allow normal swap
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }
        
        // Calculate the target tick based on sqrtPriceLimitX96
        int24 targetTick = _getTargetTick(params.sqrtPriceLimitX96, params.zeroForOne);
        
        // Find limit orders between current tick and target tick
        (uint256 totalLimitOrderAmount, bool hasOrders) = _findLimitOrdersInRange(
            key.toId(), 
            currentTick, 
            targetTick, 
            params.zeroForOne,
            key.tickSpacing
        );
        
        if (!hasOrders || totalLimitOrderAmount == 0) {
            // No limit orders available - let the pool handle the swap with its own liquidity
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }
        
        // Calculate how much of the swap demand can be satisfied by limit orders
        uint256 swapAmount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 limitOrderFulfillment = _min(totalLimitOrderAmount, swapAmount);
        
        if (limitOrderFulfillment == 0) {
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }
        
        // Execute the limit orders that can fulfill this swap
        _executeLimitOrdersInRange(
            key, 
            currentTick, 
            targetTick, 
            params.zeroForOne, 
            limitOrderFulfillment
        );
        
        // Create the before swap delta to represent the limit order execution
        return _createBeforeSwapDelta(params.zeroForOne, limitOrderFulfillment);
    }


    // ========== INTERNAL HELPER FUNCTIONS ==========

    function _validateOrderInputs(
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 deadline,
        address currency0,
        address currency1
    ) internal view {
        if (!(targetPrices.length == targetAmounts.length && targetPrices.length > 0 && targetPrices.length <= 10)) revert InvalidArrays();
        if (deadline <= block.timestamp) revert ExpiredDeadline();
        if (currency0 == currency1) revert SameCurrencies();
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
        if (length == 0) revert EmptyArrays();
        unchecked {
            for (uint256 i; i < length; ++i) {
                uint256 amount = amounts[i];
                total += amount;
            }
        }
        if (total == 0) revert InvalidTotal();
    }

    /**
     * @notice Ensure pool is initialized and has liquidity from batch order deposits
     */
    function _ensurePoolInitialized(PoolKey memory key) internal {
        PoolId poolId = key.toId();
        
        // Check if pool is already initialized by checking sqrtPriceX96
        (uint160 currentPrice, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        if (currentPrice > 0) {
            // Pool is already initialized
            return;
        } else {
            revert();
        }
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
        uint32 slippage,
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
            //  the user pass it because accumulated 3% is alot 
            // the market in his peak can reach 10% and user is oki with this 
            maxSlippageBps: slippage,  // Fixed 3% slippage
            // @note we dont need this ig ?  
            bestPriceTimeout: 0,  // No timeout
            ticksLength: uint16(targetTicks.length),
            zeroForOne: zeroForOne,
            isActive: true,
            // @audit buggy but how we should handle this as this is a batch 
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
            if (msg.value < totalAmount + estimatedGasFee) revert InsufficientETHForOrderPlusGas();
            if (msg.value > totalAmount + estimatedGasFee) {
                (bool success, ) = payable(msg.sender).call{value: msg.value - totalAmount - estimatedGasFee}("");
                require(success, "Failed transaction");
            }
        } else {
            // ERC20 case: require ETH for gas fee separately
            if (msg.value < estimatedGasFee) revert InsufficientETHForGasFee();
            if (msg.value > estimatedGasFee) {
                (bool success,) = payable(msg.sender).call{value: msg.value - estimatedGasFee}("");
                require(success, "Failes transaction");
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

    function _transfer(uint256 batchOrderId, uint256 outputAmount) internal {
        BatchInfo storage batch = batchOrders[batchOrderId];
        Currency outputToken = batch.zeroForOne ? batch.poolKey.currency1 : batch.poolKey.currency0;
        
        
        outputToken.transfer(msg.sender, outputAmount);
    }
    
 
  
    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        return 60; // Default
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
        // @note what is this ?? 
        uint128 liquidityDelta = uint128(amount / 100); // Conservative amount
        if (liquidityDelta == 0) liquidityDelta = 1000;
        
        // Create ModifyLiquidityParams struct
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityDelta)),
            salt: bytes32(uint256((block.timestamp)))
        });
        
        // Add liquidity to the pool
        (BalanceDelta callerDelta, ) = poolManager.modifyLiquidity(key, params, "");
        
        return abi.encode(callerDelta);
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
     * @notice Execute limit orders in the specified range
     */
    function _executeLimitOrdersInRange(
        PoolKey calldata key,
        int24 currentTick,
        int24 targetTick,
        bool zeroForOne,
        uint256 maxAmountToExecute
    ) internal {
        PoolId poolId = key.toId();
        uint256 remainingAmount = maxAmountToExecute;
        bool limitOrderDirection = !zeroForOne; // Opposite direction to the market swap

        if (zeroForOne) {
            // Market swap is selling token0, execute buy limit orders
            for (int24 tick = currentTick; tick >= targetTick && remainingAmount > 0; tick -= key.tickSpacing) {
                uint256 availableAmount = pendingBatchOrders[poolId][tick][limitOrderDirection];
                if (availableAmount > 0) {
                    uint256 executeAmount = _min(availableAmount, remainingAmount);
                    _executeLimitOrdersAtTick(poolId, tick, limitOrderDirection, executeAmount);
                    remainingAmount -= executeAmount;
                }
            }
        } else {
            // Market swap is buying token0, execute sell limit orders  
            for (int24 tick = currentTick; tick <= targetTick && remainingAmount > 0; tick += key.tickSpacing) {
                uint256 availableAmount = pendingBatchOrders[poolId][tick][limitOrderDirection];
                if (availableAmount > 0) {
                    uint256 executeAmount = _min(availableAmount, remainingAmount);
                    _executeLimitOrdersAtTick(poolId, tick, limitOrderDirection, executeAmount);
                    remainingAmount -= executeAmount;
                }
            }
        }
    }

    /**
     * @notice Execute limit orders at a specific tick
     */
    function _executeLimitOrdersAtTick(
        PoolId poolId,
        int24 tick,
        bool zeroForOne,
        uint256 amountToExecute
    ) internal {
        // Reduce pending amount
        pendingBatchOrders[poolId][tick][zeroForOne] -= amountToExecute;
        
        // Find and update relevant batch orders
        uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
        uint256 remainingToExecute = amountToExecute;
        
        for (uint256 i = 0; i < batchIds.length && remainingToExecute > 0; i++) {
            uint256 batchId = batchIds[i];
            BatchInfo storage batch = batchOrders[batchId];
            
            if (!batch.isActive) continue;
            
            // Find this tick in the batch's target ticks
            for (uint256 j = 0; j < batch.ticksLength; j++) {
                if (batchTargetTicks[batchId][j] == tick) {
                    uint256 batchAmountAtTick = batchTargetAmounts[batchId][j];
                    uint256 executeFromBatch = _min(batchAmountAtTick, remainingToExecute);
                    
                    // Update batch state
                    claimableOutputTokens[batchId] += executeFromBatch;
                    remainingToExecute -= executeFromBatch;
                    
                    break;
                }
            }
        }
        
        // Clean up if tick is now empty
        if (pendingBatchOrders[poolId][tick][zeroForOne] == 0) {
            delete tickToBatchIds[poolId][tick][zeroForOne];
        } 
    }

    /**
     * @notice Create a BeforeSwapDelta representing limit order execution
     */
    function _createBeforeSwapDelta(bool zeroForOne, uint256 amount) internal pure returns (BeforeSwapDelta) {
        if (zeroForOne) {
            // Market swap wants to sell token0, limit orders provide token1
            // The hook provides token1 output, so amount1 is negative (flowing out)
            // The hook takes token0 input, so amount0 is positive (flowing in)
            return toBeforeSwapDelta(int128(int256(amount)), -int128(int256(amount)));
        } else {
            // Market swap wants to buy token0, limit orders provide token0  
            // The hook provides token0 output, so amount0 is negative (flowing out)
            // The hook takes token1 input, so amount1 is positive (flowing in)
            return toBeforeSwapDelta(-int128(int256(amount)), int128(int256(amount)));
        }
    }

    /**
     * @notice Utility function to get minimum of two values
     */
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
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
        if (gasRefundProcessed[batchId]) revert RefundAlreadyProcessed();
        if (batchOrders[batchId].isActive) revert BatchStillActive();
        
        uint256 preCollectedGas = preCollectedGasFees[batchId];
        uint256 totalActualGas = actualGasCosts[batchId];
        
        if (preCollectedGas > totalActualGas) {
            uint256 refundAmount = preCollectedGas - totalActualGas;
            gasRefundProcessed[batchId] = true;
            
            address user = batchOrders[batchId].user;
            (bool success,) = payable(user).call{value: refundAmount}("");
            require(success, "Failed Transaction");
            
            emit GasFeeRefunded(batchId, user, refundAmount);
        } else {
            gasRefundProcessed[batchId] = true;
            // Emit event to signal processing even when no refund is due
            emit GasFeeRefunded(batchId, batchOrders[batchId].user, 0);
        }
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


    // ========== GETTER VIEW FUNCTIONS ==========
    
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
    
    /**
     * @notice External function to safely get current tick (used for try-catch)
     */
    function getPoolCurrentTick(PoolId poolId) external view returns (int24) {
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        return currentTick;
    }
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
        BatchInfo storage batch = batchOrders[batchId];
        if (batch.user == address(0)) revert InvalidBatch();
        
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
        if (batch.user == address(0)) revert InvalidBatch();
        
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
    // ========== FALLBACKS ==========
    receive() external payable {}
    fallback() external payable {}
}
