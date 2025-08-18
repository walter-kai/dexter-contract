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
 * @dev Refactored to eliminate duplicate code and reduce contract size
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
    
    // Simplified batch info struct
    struct BatchInfo {
        address user;
        PoolKey poolKey;
        int24[] targetTicks;
        uint256[] targetAmounts;
        bool zeroForOne;
        uint256 totalAmount;
        uint256 expirationTime;
        bool isActive;
        uint256 maxSlippageBps;
        uint256 minOutputAmount;
        uint256 bestPriceTimeout;
    }
    
    mapping(uint256 => BatchInfo) public batchOrders;
    uint256 public nextBatchOrderId = 1;

    // Gas price tracking (simplified)
    uint128 public movingAverageGasPrice;
    uint104 public movingAverageGasPriceCount;
    
    // Best execution queue
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

    // ========== MODIFIERS ==========
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier validBatchOrder(uint256 batchId) {
        require(batchId > 0 && batchId < nextBatchOrderId, "Invalid batch ID");
        require(batchOrders[batchId].isActive, "Order not active");
        _;
    }

    // ========== CONSTRUCTOR ==========
    
    constructor(IPoolManager _poolManager, address _feeRecipient) 
        BaseHook(_poolManager) 
    {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        owner = msg.sender;
        FEE_RECIPIENT = _feeRecipient;
    }

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Universal batch order creation function
     * @dev Single entry point for all batch order variations
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
            currency0, currency1, fee, zeroForOne,
            targetPrices, targetAmounts, deadline,
            maxSlippageBps, minOutputAmount, bestPriceTimeout
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
        
        // Update gas tracking
        _updateGasPrice();
        
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
        
        emit BatchOrderCreatedOptimized(batchId, msg.sender, totalAmount);
        
        return batchId;
    }

    /**
     * @notice Cancel batch order
     */
    function cancelBatchOrder(uint256 batchOrderId) external validBatchOrder(batchOrderId) {
        BatchInfo storage batch = batchOrders[batchOrderId];
        require(batch.user == msg.sender, "Not authorized");
        
        // Get refund amount
        uint256 claimBalance = balanceOf[msg.sender][batchOrderId];
        require(claimBalance > 0, "Nothing to cancel");

        // Clean up storage
        _cleanupBatchOrder(batchOrderId);
        
        // Mark inactive
        batch.isActive = false;
        
        // Burn claim tokens and refund
        _burn(msg.sender, address(uint160(batchOrderId)), claimBalance);
        claimTokensSupply[batchOrderId] = 0;
        
        // Transfer refund
        Currency token = batch.zeroForOne ? batch.poolKey.currency0 : batch.poolKey.currency1;
        token.transfer(msg.sender, claimBalance);

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
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata) 
        internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = _getDynamicFee();
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata) 
        internal override returns (bytes4, int128) {
        _updateGasPrice();
        
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
        require(targetPrices.length == targetAmounts.length && targetPrices.length > 0 && targetPrices.length <= 10, "Invalid arrays");
        require(deadline > block.timestamp, "Invalid deadline");
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

    function _pricesToTicks(uint256[] memory prices) internal pure returns (int24[] memory ticks) {
        ticks = new int24[](prices.length);
        for (uint256 i = 0; i < prices.length; i++) {
            ticks[i] = TickMath.getTickAtSqrtPrice(uint160(prices[i]));
        }
    }

    function _sumAmounts(uint256[] memory amounts) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] > 0, "Invalid amount");
            total += amounts[i];
        }
        require(total > 0, "Invalid total");
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
        
        batchOrders[batchId] = BatchInfo({
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
            bestPriceTimeout: bestPriceTimeout
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
        for (uint256 i = 0; i < batch.targetTicks.length; i++) {
            pendingBatchOrders[poolId][batch.targetTicks[i]][batch.zeroForOne] -= batch.targetAmounts[i];
            _removeBatchIdFromTick(poolId, batch.targetTicks[i], batch.zeroForOne, batchOrderId);
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
            uint256 batchAmount = _getBatchAmountAtTick(batch, tick);
            uint256 batchOutput = (outputAmount * batchAmount) / inputAmount;
            
            claimableOutputTokens[batchId] += batchOutput;
            emit BatchLevelExecutedOptimized(batchId, uint256(uint24(tick)), batchAmount);
        }

        // Clear pending orders
        pendingBatchOrders[poolId][tick][zeroForOne] = 0;
    }

    function _getBatchAmountAtTick(BatchInfo storage batch, int24 tick) internal view returns (uint256) {
        for (uint256 i = 0; i < batch.targetTicks.length; i++) {
            if (batch.targetTicks[i] == tick) {
                return batch.targetAmounts[i];
            }
        }
        return 0;
    }

    function _updateGasPrice() internal {
        uint128 gasPrice = uint128(tx.gasprice);
        if (movingAverageGasPriceCount == 0) {
            movingAverageGasPrice = gasPrice;
        } else {
            movingAverageGasPrice = ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);
        }
        movingAverageGasPriceCount++;
        emit GasPriceTrackedOptimized(gasPrice, movingAverageGasPrice, movingAverageGasPriceCount);
    }

    function _getDynamicFee() internal view returns (uint24) {
        if (movingAverageGasPriceCount == 0) return BASE_FEE;
        
        uint128 gasPrice = uint128(tx.gasprice);
        if (gasPrice > (movingAverageGasPrice * 11) / 10) return BASE_FEE / 2;
        if (gasPrice < (movingAverageGasPrice * 9) / 10) return BASE_FEE * 2;
        return BASE_FEE;
    }

    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
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

    // ========== INTERFACE COMPLIANCE STUBS ==========

    function createBatchOrder(BatchParams calldata params) external payable returns (uint256 batchId) {
        return _createBatchOrderInternal(
            params.currency0, params.currency1, 3000, params.zeroForOne,
            params.targetPrices, params.targetAmounts, params.expirationTime,
            300, 0, params.bestPriceTimeout
        );
    }

    function executeBatchLevel(uint256 /* batchId */, uint256 /* priceLevel */) external view onlyOwner returns (bool isFullyExecuted) {
        // Simplified manual execution stub
        return true;
    }

    function getBatchOrder(uint256 batchId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256[] memory targetPrices, uint256[] memory targetAmounts, 
        bool isActive, bool isFullyExecuted
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        // Convert ticks back to prices
        uint256[] memory prices = new uint256[](batch.targetTicks.length);
        for (uint256 i = 0; i < batch.targetTicks.length; i++) {
            prices[i] = uint256(TickMath.getSqrtPriceAtTick(batch.targetTicks[i]));
        }
        return (
            batch.user,
            Currency.unwrap(batch.poolKey.currency0),
            Currency.unwrap(batch.poolKey.currency1),
            batch.totalAmount,
            0, // executedAmount - TODO
            prices,
            batch.targetAmounts,
            batch.isActive,
            false // isFullyExecuted - TODO
        );
    }

    function getBatchOrders(uint256) external pure returns (uint256[] memory orderIds) {
        return new uint256[](0);
    }

    function getBatchStatistics() external view returns (uint256 totalBatches) {
        return nextBatchOrderId - 1;
    }

    function getExecutedLevels(uint256 batchId) external view returns (uint256 executedLevels, bool[] memory levelStatus) {
        BatchInfo storage batch = batchOrders[batchId];
        return (0, new bool[](batch.targetTicks.length));
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner, amount);
        }
    }

    // ========== VIEW FUNCTIONS ==========

    function getBatchOrderDetails(uint256 batchId) external view returns (
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
        BatchInfo storage batch = batchOrders[batchId];
        // Convert ticks back to prices
        uint256[] memory prices = new uint256[](batch.targetTicks.length);
        for (uint256 i = 0; i < batch.targetTicks.length; i++) {
            prices[i] = uint256(TickMath.getSqrtPriceAtTick(batch.targetTicks[i]));
        }
        return (
            batch.user,
            Currency.unwrap(batch.poolKey.currency0),
            Currency.unwrap(batch.poolKey.currency1),
            batch.totalAmount,
            0, // executedAmount - TODO: calculate
            prices,
            batch.targetAmounts,
            batch.expirationTime,
            batch.isActive,
            false, // isFullyExecuted - TODO: calculate
            0, // executedLevels - TODO: calculate
            batch.zeroForOne
        );
    }

    function getGasPriceStats() external view returns (uint128, uint128, uint104) {
        return (uint128(tx.gasprice), movingAverageGasPrice, movingAverageGasPriceCount);
    }

    function getCurrentDynamicFee() external view returns (uint24) {
        return _getDynamicFee();
    }

    // ========== FALLBACKS ==========

    receive() external payable {}
    fallback() external payable {}
}
