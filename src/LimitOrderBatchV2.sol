// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

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
    using FixedPointMathLib for uint256;
    using LPFeeLibrary for uint24;

    // ========== STORAGE ==========
    // Core storage
    mapping(PoolId => int24) public lastTicks;
    mapping(PoolId => mapping(int24 => mapping(bool => uint256))) public pendingBatchOrders;
    mapping(uint256 => uint256) public claimableOutputTokens;
    mapping(uint256 => uint256) public claimTokensSupply;
    mapping(PoolId => mapping(int24 => mapping(bool => uint256[]))) internal tickToBatchIds;

    // Batch order storage
    struct BatchInfo {
        address user;
        uint96 totalAmount;
        PoolKey poolKey;
        uint64 expirationTime;
        uint32 maxSlippageBps;
        uint32 bestPriceTimeout;
        uint16 ticksLength;
        bool zeroForOne;
        bool isActive;
        uint256 minOutputAmount;
    }

    mapping(uint256 => int24[]) public batchTargetTicks;
    mapping(uint256 => uint256[]) public batchTargetAmounts;
    mapping(uint256 => BatchInfo) public batchOrders;
    uint256 public nextBatchOrderId = 1;

    // Pool tracking
    mapping(PoolId => bool) public poolInitialized;
    PoolId[] public allPoolIds;
    mapping(PoolId => PoolKey) public poolIdToKey;
    mapping(PoolId => uint256) public poolIndex;

    // Gas fee management
    mapping(uint256 => uint256) public preCollectedGasFees;
    mapping(uint256 => uint256) public actualGasCosts;
    mapping(uint256 => bool) public gasRefundProcessed;

    // Constants
    uint24 public constant BASE_FEE = 3000; // 0.3%
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint256 public constant BASE_PROTOCOL_FEE_BPS = 35; // 0.35%
    uint256 public constant FEE_BASIS_POINTS = 35;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;

    // Gas estimation constants
    uint256 public constant ESTIMATED_EXECUTION_GAS = 150000;
    uint256 public constant GAS_PRICE_BUFFER_MULTIPLIER = 120;
    uint256 public constant MAX_GAS_FEE_ETH = 0.01 ether;

    address public immutable FEE_RECIPIENT;
    address public owner;

    // ========== EVENTS ==========
    event LimitOrderPlaced(
        PoolId indexed poolId,
        int24 indexed tick,
        bool zeroForOne,
        uint256 amount,
        address indexed user
    );

    event LimitOrderExecuted(
        PoolId indexed poolId,
        int24 indexed tick,
        bool zeroForOne,
        uint256 amount,
        address indexed user
    );

    event BatchOrderCreated(uint256 indexed batchId, address indexed user, uint256 totalAmount);
    event BatchLevelExecuted(uint256 indexed batchId, int24 indexed tick, uint256 amount);
    event BatchOrderCancelled(uint256 indexed batchId, address indexed user);
    event TokensRedeemed(uint256 indexed batchId, address indexed user, uint256 amount);

    event GasFeePreCollected(uint256 indexed batchId, uint256 estimatedGasFee);
    event GasFeeConsumed(uint256 indexed batchId, uint256 actualGasCost, uint256 protocolFee);
    event GasFeeRefunded(uint256 indexed batchId, address indexed user, uint256 refundAmount);

    event LiquidityAdded(PoolId indexed poolId, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper);
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);
    event LiquidityAdditionFailed(PoolId indexed poolId, uint256 amount, string reason);

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
        _ensurePoolInitialized(key);
        int24[] memory targetTicks = _pricesToTicks(targetPrices);
        uint256 totalAmount = _sumAmounts(targetAmounts);
        batchId = _createBatch(key, targetTicks, targetAmounts, totalAmount, zeroForOne, deadline);
        _handleTokenDeposit(key, zeroForOne, totalAmount);
        _addLiquidityFromDeposit(key, zeroForOne, totalAmount);
        emit BatchOrderCreated(batchId, msg.sender, totalAmount);
        return batchId;
    }

    function cancelBatchOrder(uint256 batchOrderId) external validBatchOrder(batchOrderId) {
        BatchInfo storage batch = batchOrders[batchOrderId];
        require(batch.user == msg.sender, "Not authorized");
        require(balanceOf[msg.sender][batchOrderId] > 0, "No tokens to cancel");

        uint256 userClaimBalance = balanceOf[msg.sender][batchOrderId];
        uint256 totalPendingAmount = _calculateTotalPendingAmount(batchOrderId);
        require(totalPendingAmount > 0, "Batch already executed, use redeem instead");

        uint256 cancellableAmount = userClaimBalance * totalPendingAmount / uint256(batch.totalAmount);
        require(cancellableAmount > 0, "Nothing to cancel");

        _burn(msg.sender, address(uint160(batchOrderId)), cancellableAmount);
        _cancelPendingOrders(batchOrderId, cancellableAmount);

        claimTokensSupply[batchOrderId] -= cancellableAmount;
        if (totalPendingAmount == cancellableAmount) batch.isActive = false;

        if (preCollectedGasFees[batchOrderId] > actualGasCosts[batchOrderId] && !gasRefundProcessed[batchOrderId]) {
            uint256 refundAmount = preCollectedGasFees[batchOrderId] - actualGasCosts[batchOrderId];
            payable(msg.sender).transfer(refundAmount);
            emit GasFeeRefunded(batchOrderId, msg.sender, refundAmount);
        }

        emit BatchOrderCancelled(batchOrderId, msg.sender);
    }

    function redeemBatchOrder(uint256 batchOrderId, uint256 inputAmountToClaimFor) external {
        require(claimableOutputTokens[batchOrderId] > 0, "Nothing to claim");
        require(balanceOf[msg.sender][batchOrderId] >= inputAmountToClaimFor, "Insufficient balance");

        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            claimableOutputTokens[batchOrderId],
            claimTokensSupply[batchOrderId]
        );

        claimableOutputTokens[batchOrderId] -= outputAmount;
        claimTokensSupply[batchOrderId] -= inputAmountToClaimFor;
        _burn(msg.sender, address(uint160(batchOrderId)), inputAmountToClaimFor);

        _transferWithFee(batchOrderId, outputAmount);
        emit TokensRedeemed(batchOrderId, msg.sender, outputAmount);
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
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address /* sender */, PoolKey calldata /* key */, uint160 /* sqrtPriceX96 */) internal pure override returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        uint8 protocolFee,
        uint8 hookFee
    ) internal override returns (bytes4) {
        lastTicks[key.toId()] = tick;
        
        // Simple pool initialization tracking
        PoolId poolId = key.toId();
        if (!poolInitialized[poolId]) {
            poolInitialized[poolId] = true;
            allPoolIds.push(poolId);
            poolIdToKey[poolId] = key;
            poolIndex[poolId] = allPoolIds.length - 1;
            emit PoolInitializationTracked(poolId, tick, block.timestamp);
        }
        
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata) 
        internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (sender == address(this)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE);
        }

        int24 currentTick = _getCurrentTick(key);
        int24 targetTick = _getTargetTick(params.sqrtPriceLimitX96, params.zeroForOne);
        
        // Process limit orders that can satisfy the swap
        BeforeSwapDelta delta = _processLimitOrdersBeforeSwap(key, params);
        
        // Use fixed fee for simplified version
        uint24 fee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, delta, fee);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata) 
        internal override returns (bytes4, int128) {
        if (sender == address(this)) return (BaseHook.afterSwap.selector, 0);
        _handleAMMSettlement(key, params, delta);
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        lastTicks[key.toId()] = currentTick;
        return (BaseHook.afterSwap.selector, 0);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (string memory operationType) = abi.decode(data, (string));
        if (keccak256(abi.encodePacked(operationType)) == keccak256(abi.encodePacked("general_liquidity"))) {
            (, PoolKey memory key, ModifyLiquidityParams memory liquidityParams) = abi.decode(data, (string, PoolKey, ModifyLiquidityParams));
            return _handleGeneralLiquidityOperation(key, liquidityParams);
        }
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
            return poolManager.unlock(data);
        }
    }

    // ========== UTILITY FUNCTIONS ==========
    function _addLiquidityFromDeposit(PoolKey memory key, bool zeroForOne, uint256 totalAmount) internal {
        if (totalAmount < 1000) return;
        
        uint256 liquidityAmount = totalAmount / 4;
        if (liquidityAmount == 0) return;
        
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -887272,
            tickUpper: 887272,
            liquidityDelta: int256(uint256(liquidityAmount))
        });
        
        try poolManager.modifyLiquidity(key, params, "") {
            emit LiquidityAdded(key.toId(), liquidityAmount, liquidityAmount, params.tickLower, params.tickUpper);
        } catch {
            emit LiquidityAdditionFailed(key.toId(), liquidityAmount, "Failed to add liquidity");
        }
    }

    function _handleGeneralLiquidityOperation(
        PoolKey memory key,
        ModifyLiquidityParams memory params
    ) internal returns (bytes memory) {
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
        return abi.encode(delta);
    }

    function _handleLiquidityOperation(
        PoolKey memory key,
        uint256 amount,
        bool zeroForOne
    ) internal returns (bytes memory) {
        int24 tickSpacing = key.tickSpacing;
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: currentTick - (100 * tickSpacing),
            tickUpper: currentTick + (100 * tickSpacing),
            liquidityDelta: int256(uint256(amount))
        });
        
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
        return abi.encode(delta);
    }

    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        return 60;
    }

    function _calculateEstimatedGasFee() internal view returns (uint256) {
        uint256 estimatedCost = ESTIMATED_EXECUTION_GAS * tx.gasprice;
        estimatedCost = (estimatedCost * GAS_PRICE_BUFFER_MULTIPLIER) / 100;
        
        if (estimatedCost > MAX_GAS_FEE_ETH) {
            return MAX_GAS_FEE_ETH;
        }
        
        return estimatedCost;
    }

    function _getTargetTick(uint160 sqrtPriceLimitX96, bool zeroForOne) internal pure returns (int24) {
        if (sqrtPriceLimitX96 == 0) {
            return zeroForOne ? TickMath.MIN_TICK + 1 : TickMath.MAX_TICK - 1;
        }
        return TickMath.getTickAtSqrtPrice(sqrtPriceLimitX96);
    }

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
            fee: fee | 0x800000,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(this))
        });
    }

    function _pricesToTicks(uint256[] memory prices) internal pure returns (int24[] memory) {
        uint256 length = prices.length;
        int24[] memory ticks = new int24[](length);
        unchecked {
            for (uint256 i; i < length; ++i) {
                ticks[i] = TickMath.getTickAtSqrtPrice(uint160(prices[i]));
            }
        }
        return ticks;
    }

    function _sumAmounts(uint256[] memory amounts) internal pure returns (uint256) {
        uint256 length = amounts.length;
        require(length > 0, "Empty arrays");
        uint256 totalSum = 0;
        unchecked {
            for (uint256 i; i < length; ++i) {
                uint256 amount = amounts[i];
                require(amount > 0, "Invalid amount");
                totalSum += amount;
            }
        }
        require(totalSum > 0, "Invalid total");
        return totalSum;
    }

    function _getCurrentTick(PoolKey memory key) internal view returns (int24) {
        (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        return tick;
    }

    function _ensurePoolInitialized(PoolKey memory key) internal {
        PoolId poolId = key.toId();
        (uint160 currentPrice, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        if (currentPrice > 0) return;
        poolManager.initialize(key, TickMath.SQRT_RATIO_X96);
    }

    function _handleTokenDeposit(PoolKey memory key, bool zeroForOne, uint256 totalAmount) internal {
        uint256 estimatedGasFee = _calculateEstimatedGasFee();
        uint256 batchId = nextBatchOrderId - 1;
        preCollectedGasFees[batchId] = estimatedGasFee;
        if (Currency.unwrap(zeroForOne ? key.currency0 : key.currency1) == address(0)) {
            require(msg.value >= totalAmount + estimatedGasFee, "Insufficient ETH");
            if (msg.value > totalAmount + estimatedGasFee) {
                payable(msg.sender).transfer(msg.value - totalAmount - estimatedGasFee);
            }
        } else {
            IERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1)).safeTransferFrom(msg.sender, address(this), totalAmount);
            require(msg.value >= estimatedGasFee, "Insufficient ETH for gas fee");
            if (msg.value > estimatedGasFee) {
                payable(msg.sender).transfer(msg.value - estimatedGasFee);
            }
        }
        emit GasFeePreCollected(batchId, estimatedGasFee);
    }

    function _createBatch(
        PoolKey memory key,
        int24[] memory targetTicks,
        uint256[] memory targetAmounts,
        uint256 totalAmount,
        bool zeroForOne,
        uint256 deadline
    ) internal returns (uint256) {
        uint256 batchId = nextBatchOrderId++;
        batchTargetTicks[batchId] = targetTicks;
        batchTargetAmounts[batchId] = targetAmounts;
        batchOrders[batchId] = BatchInfo({
            user: msg.sender,
            totalAmount: uint96(totalAmount),
            poolKey: key,
            expirationTime: uint64(deadline),
            maxSlippageBps: 300,
            bestPriceTimeout: 0,
            ticksLength: uint16(targetTicks.length),
            zeroForOne: zeroForOne,
            isActive: true,
            minOutputAmount: 0
        });

        PoolId poolId = key.toId();
        for (uint256 i = 0; i < targetTicks.length; i++) {
            pendingBatchOrders[poolId][targetTicks[i]][zeroForOne] += targetAmounts[i];
            tickToBatchIds[poolId][targetTicks[i]][zeroForOne].push(batchId);
        }
        claimTokensSupply[batchId] = totalAmount;
        _mint(msg.sender, address(uint160(batchId)), totalAmount);
        return batchId;
    }

    function _cancelPendingOrders(uint256 batchId, uint256 cancellableAmount) internal {
        BatchInfo storage batch = batchOrders[batchId];
        PoolId poolId = batch.poolKey.toId();

        uint256 totalPendingAmount = _calculateTotalPendingAmount(batchId);
        uint256 amountPerLevel = cancellableAmount / totalPendingAmount;

        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 tick = batchTargetTicks[batchId][i];
            uint256 levelPending = pendingBatchOrders[poolId][tick][batch.zeroForOne];
            if (levelPending > 0) {
                uint256 levelCancellation = amountPerLevel * levelPending;
                pendingBatchOrders[poolId][tick][batch.zeroForOne] -= levelCancellation;
                if (pendingBatchOrders[poolId][tick][batch.zeroForOne] == 0) {
                    _removeBatchIdFromTick(poolId, tick, batch.zeroForOne, batchId);
                }
            }
        }
    }

    function _calculateTotalPendingAmount(uint256 batchId) internal view returns (uint256) {
        BatchInfo storage batch = batchOrders[batchId];
        PoolId poolId = batch.poolKey.toId();
        uint256 total = 0;
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            total += pendingBatchOrders[poolId][batchTargetTicks[batchId][i]][batch.zeroForOne];
        }
        return total;
    }

    function _removeBatchIdFromTick(PoolId poolId, int24 tick, bool zeroForOne, uint256 batchId) internal {
        uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
        for (uint256 i = 0; i < batchIds.length; i++) {
            if (batchIds[i] == batchId) {
                batchIds[i] = batchIds[batchIds.length - 1];
                batchIds.pop();
                break;
            }
        }
    }

    function _transferWithFee(uint256 batchId, uint256 outputAmount) internal {
        BatchInfo storage batch = batchOrders[batchId];
        Currency outputToken = batch.zeroForOne ? batch.poolKey.currency1 : batch.poolKey.currency0;
        outputToken.transfer(msg.sender, outputAmount);
    }

    function _processLimitOrdersBeforeSwap(PoolKey calldata key, SwapParams calldata params) internal returns (BeforeSwapDelta) {
        PoolId poolId = key.toId();
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        int24 targetTick = _getTargetTick(params.sqrtPriceLimitX96, params.zeroForOne);
        uint256 totalAmount = _findLimitOrdersInRange(poolId, currentTick, targetTick, params.zeroForOne);
        if (totalAmount == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;
        return _createBeforeSwapDelta(params.zeroForOne, totalAmount);
    }

    function _findLimitOrdersInRange(
        PoolKey calldata key,
        int24 currentTick,
        int24 targetTick,
        bool zeroForOne
    ) internal view returns (uint256) {
        PoolId poolId = key.toId();
        uint256 totalAmount = 0;
        bool ascending = targetTick > currentTick;
        int24 spacing = key.tickSpacing;
        if (ascending) {
            for (int24 tick = currentTick; tick <= targetTick; tick += spacing) {
                totalAmount += pendingBatchOrders[poolId][tick][!zeroForOne];
            }
        } else {
            for (int24 tick = currentTick; tick >= targetTick; tick -= spacing) {
                totalAmount += pendingBatchOrders[poolId][tick][!zeroForOne];
            }
        }
        return totalAmount;
    }

    function _executeLimitOrdersInRange(
        PoolKey calldata key,
        int24 currentTick,
        int24 targetTick,
        bool zeroForOne,
        uint256 maxAmountToExecute
    ) internal {
        PoolId poolId = key.toId();
        uint256 remainingAmount = maxAmountToExecute;
        bool limitOrderDirection = !zeroForOne;
        if (zeroForOne) {
            for (int24 tick = currentTick; tick >= targetTick && remainingAmount > 0; tick -= key.tickSpacing) {
                uint256 availableAmount = pendingBatchOrders[poolId][tick][limitOrderDirection];
                if (availableAmount > 0) {
                    uint256 executeAmount = _min(availableAmount, remainingAmount);
                    _executeLimitOrdersAtTick(poolId, tick, limitOrderDirection, executeAmount);
                    remainingAmount -= executeAmount;
                }
            }
        } else {
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

    function _executeLimitOrdersAtTick(
        PoolId poolId,
        int24 tick,
        bool zeroForOne,
        uint256 amountToExecute
    ) internal {
        pendingBatchOrders[poolId][tick][zeroForOne] -= amountToExecute;
        if (pendingBatchOrders[poolId][tick][zeroForOne] == 0) {
            delete tickToBatchIds[poolId][tick][zeroForOne];
        }
        uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
        uint256 remainingToExecute = amountToExecute;
        for (uint256 i = 0; i < batchIds.length && remainingToExecute > 0; i++) {
            uint256 batchId = batchIds[i];
            BatchInfo storage batch = batchOrders[batchId];
            uint256 batchAmountAtTick = _getBatchAmountAtTick(batchId, tick);
            uint256 executeFromBatch = _min(batchAmountAtTick, remainingToExecute);
            claimableOutputTokens[batchId] += executeFromBatch;
            remainingToExecute -= executeFromBatch;
        }
        emit BatchLevelExecuted(nextBatchOrderId - 1, tick, amountToExecute);
    }

    function _getBatchAmountAtTick(uint256 batchId, int24 tick) internal view returns (uint256) {
        uint256 ticksLength = batchOrders[batchId].ticksLength;
        for (uint256 i = 0; i < ticksLength; i++) {
            if (batchTargetTicks[batchId][i] == tick) {
                return batchTargetAmounts[batchId][i];
            }
        }
        return 0;
    }

    function _createBeforeSwapDelta(bool zeroForOne, uint256 amount) internal pure returns (BeforeSwapDelta) {
        if (zeroForOne) {
            return toBeforeSwapDelta(int128(int256(amount)), -int128(int256(amount)));
        } else {
            return toBeforeSwapDelta(-int128(int256(amount)), int128(int256(amount)));
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _handleAMMSettlement(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta) internal {
        if (Currency.unwrap(key.currency0) == address(0)) {
            if (delta.amount0() > 0) {
                payable(address(poolManager)).transfer(uint256(int256(delta.amount0())));
            }
        } else {
            IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint256(int256(delta.amount0())));
        }
        if (Currency.unwrap(key.currency1) == address(0)) {
            if (delta.amount1() > 0) {
                payable(address(poolManager)).transfer(uint256(int256(delta.amount1())));
            }
        } else {
            IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint256(int256(delta.amount1())));
        }
    }

    function _trackPoolInitialization(PoolId poolId, int24 initialTick) internal {
        if (poolInitialized[poolId]) return;
        poolInitialized[poolId] = true;
        poolIndex[poolId] = allPoolIds.length;
        allPoolIds.push(poolId);
        poolIdToKey[poolId] = key;
        emit PoolInitializationTracked(poolId, initialTick, block.timestamp);
    }

    function _handleLiquidityFromDeposit(PoolKey memory key, bool zeroForOne, uint256 totalAmount) internal {
        if (totalAmount < 1000) return;
        uint256 liquidityAmount = totalAmount / 4;
        if (liquidityAmount == 0) liquidityAmount = 1000;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: int256(uint256(liquidityAmount)),
            salt: bytes32(uint256(block.timestamp))
        });
        poolManager.unlock(abi.encode("general_liquidity", key, params));
        emit LiquidityAdded(key.toId(), liquidityAmount, liquidityAmount, -600, 600);
    }

    function _calculateDynamicProtocolFee(
        uint256 batchId,
        uint256 outputAmount,
        uint256 actualGasCost
    ) internal view returns (uint256) {
        uint256 baseProtocolFee = (outputAmount * BASE_PROTOCOL_FEE_BPS) / BASIS_POINTS_DENOMINATOR;
        uint256 dynamicGasOverhead = actualGasCosts[batchId] - preCollectedGasFees[batchId];
        if (dynamicGasOverhead > 0) {
            return baseProtocolFee + dynamicGasOverhead;
        }
        return baseProtocolFee;
    }
    function processGasRefund(uint256 batchId) external onlyOwner {
        require(!gasRefundProcessed[batchId], "Refund already processed");
        require(!batchOrders[batchId].isActive, "Batch still active");
        uint256 preCollectedGas = preCollectedGasFees[batchId];
        uint256 actualGas = actualGasCosts[batchId];
        if (preCollectedGas > actualGas) {
            uint256 refundAmount = preCollectedGas - actualGas;
            gasRefundProcessed[batchId] = true;
            payable(FEE_RECIPIENT).transfer(refundAmount);
            emit GasFeeRefunded(batchId, FEE_RECIPIENT, refundAmount);
        } else {
            gasRefundProcessed[batchId] = true;
        }
    }

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
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: int256(amount0 + amount1),
            salt: bytes32(0)
        });
        poolManager.unlock(abi.encode("general_liquidity", key, params));
        emit LiquidityAdded(key.toId(), amount0, amount1, -600, 600);
    }

    receive() external payable {}
    fallback() external payable {}
}