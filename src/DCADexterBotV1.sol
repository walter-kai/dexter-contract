error InsufficientETHForOrderPlusGas();
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

/*  ----------  imports  ----------  */
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDCADexterBotV1} from "./interfaces/IDCADexterBotV1.sol";
import {ERC6909Base} from "./base/ERC6909Base.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
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

contract DCADexterBotV1 is IDCADexterBotV1, ERC6909Base, BaseHook, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    /* ==========================================================
       STORAGE – DCA system storage + previous storage
       ========================================================== */
    mapping(PoolId => int24) public lastTicks;
    mapping(PoolId => mapping(int24 => mapping(bool => uint256))) public pendingOrders;
    mapping(uint256 => uint256) public claimableOutputTokens;
    mapping(uint256 => uint256) public claimTokensSupply;
    mapping(PoolId => mapping(int24 => mapping(bool => uint256[]))) internal tickToOrderIds;

    // DCA state tracking
    mapping(uint256 => uint256) public dcaAccumulatedInput; // Total input amount accumulated
    mapping(uint256 => uint256) public dcaAccumulatedOutput; // Total output amount accumulated
    mapping(uint256 => uint256) public dcaCurrentLevel; // Current DCA level (0 = initial swap done)
    mapping(uint256 => int24) public dcaTakeProfitTick; // Current take profit tick

    // Gas management system
    uint256 public gasTank; // Central gas pool for executions

    struct OrderInfo {
        address user;
        uint96 totalAmount;
        PoolKey poolKey;
        uint64 expirationTime;
        uint32 maxSlippageBps;
        uint32 takeProfitPercent; // Take profit %
        uint16 ticksLength;
        uint8 maxSwapOrders; // Max DCA levels
        bool zeroForOne;
        IDCADexterBotV1.OrderStatus status; // Combined status instead of separate isActive/isStalled flags
        bool isPerpetual; // Perpetual DCA order
        // DCA-specific parameters
        uint32 priceDeviationPercent;
        uint32 priceDeviationMultiplier;
        uint256 baseSwapAmount;
        uint32 swapOrderMultiplier; // NEW
        uint256 gasAllocated; // Total gas for strategy execution
        uint256 gasUsed; // Gas consumed by swaps
        uint256 gasBorrowedFromTank; // Gas borrowed from central tank
    }

    mapping(uint256 => int24[]) public orderTargetTicks;
    mapping(uint256 => uint256[]) public orderTargetAmounts;
    mapping(uint256 => OrderInfo) public orders;
    uint256 public nextOrderId = 1;

    PoolId[] public allPoolIds;
    mapping(PoolId => PoolKey) public poolIdToKey;

    /* ==========================================================
       CONSTANTS – updated to remove BASE_FEE since we use pool fee parameter
       ========================================================== */

    /* ==========================================================
       ERRORS – DCA system errors
       ========================================================== */
    error NothingToClaim();
    error InvalidOrderId();
    error OrderNotActive();
    error NotAuthorized();
    error NoTokensToCancel();
    error OrderAlreadyExecutedUseRedeem();
    error InsufficientClaimTokenBalance();
    error InvalidFeeRecipient();
    error InvalidExecutorAddress();
    error ExpiredDeadline();
    error SameCurrencies();
    error InvalidAmount();
    error InvalidOrder();
    // DCA-specific errors
    error InvalidTakeProfitPercent();
    error InvalidMaxSwapOrders();
    error InvalidPriceDeviation();
    error InvalidMultiplier();
    error InsufficientGasTank();
    error OrderStalled();

    /* ==========================================================
       EVENTS – DCA system events
       ========================================================== */
    event DCAStrategyCreated(
        uint256 indexed dcaId,
        address indexed user,
        address currency0,
        address currency1,
        uint256 totalAmount,
        uint32 takeProfitPercent,
        uint8 maxSwapOrders
    );
    event DCASwapExecuted(uint256 indexed dcaId, uint256 level, uint256 amountIn, uint256 amountOut, bool direction);
    event DCARestarted(uint256 indexed dcaId, uint256 profitAmount);
    event OrderCancelledOptimized(uint256 indexed orderId, address indexed user);
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);

    modifier validOrder(uint256 orderId) {
        if (!(orderId > 0 && orderId < nextOrderId)) revert InvalidOrderId();
        if (orders[orderId].status != IDCADexterBotV1.OrderStatus.ACTIVE) revert OrderNotActive();
        _;
    }

    constructor(IPoolManager _poolManager, address _feeRecipient, address _executor) BaseHook(_poolManager) {
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (_executor == address(0)) revert InvalidExecutorAddress();
    }

    /* ==========================================================
       CREATE DCA STRATEGY – new DCA system
       ========================================================== */
    // New modularized createDCAStrategy using PoolParams and DCAParams
    function createDCAStrategy(
        IDCADexterBotV1.PoolParams calldata pool,
        IDCADexterBotV1.DCAParams calldata dca,
        uint32 slippage,
        uint256 expirationTime
    ) external payable virtual returns (uint256 dcaId) {
        // Calculate gas internally based on strategy parameters
        uint256 gasBaseAmount = _calculateSwapGasCost();

        return _createDCAStrategyInternal(
            pool.currency0,
            pool.currency1,
            pool.fee,
            dca.zeroForOne,
            dca.takeProfitPercent,
            dca.maxSwapOrders,
            dca.priceDeviationPercent,
            dca.priceDeviationMultiplier,
            dca.swapOrderAmount,
            dca.swapOrderMultiplier,
            slippage,
            expirationTime,
            gasBaseAmount
        );
    }

    function _createDCAStrategyInternal(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint32 takeProfitPercent,
        uint8 maxSwapOrders,
        uint32 priceDeviationPercent,
        uint32 priceDeviationMultiplier,
        uint256 swapOrderAmount,
        uint32 swapOrderMultiplier,
        uint32 slippage,
        uint256 expirationTime,
        uint256 gasBaseAmount
    ) internal returns (uint256 dcaId) {
        _validateDCAInputs(
            takeProfitPercent,
            maxSwapOrders,
            priceDeviationPercent,
            priceDeviationMultiplier,
            swapOrderAmount,
            swapOrderMultiplier,
            expirationTime,
            currency0,
            currency1,
            gasBaseAmount
        );

        // Calculate total estimated gas for entire strategy
        uint256 totalEstimatedGas = _calculateTotalStrategyGas(gasBaseAmount, maxSwapOrders);

        PoolKey memory key = _createPoolKey(currency0, currency1, fee);
        _ensurePoolInitialized(key);

        // Calculate first DCA level - progressive creation
        (int24[] memory targetTicks, uint256[] memory targetAmounts, uint256 totalAmount) = _calculateInitialDCALevel(
            key, zeroForOne, priceDeviationPercent, priceDeviationMultiplier, swapOrderAmount, swapOrderMultiplier
        );

        dcaId = _createDCAStrategy(
            key,
            targetTicks,
            targetAmounts,
            totalAmount,
            zeroForOne,
            slippage,
            expirationTime,
            takeProfitPercent,
            maxSwapOrders,
            priceDeviationPercent,
            priceDeviationMultiplier,
            swapOrderAmount,
            swapOrderMultiplier,
            totalEstimatedGas
        );

        _handleTokenDeposit(key, zeroForOne, totalAmount, totalEstimatedGas);

        // Start initial buy swap immediately at swapOrderAmount
        _initiateFirstDCASwap(dcaId);

        emit DCAStrategyCreated(dcaId, msg.sender, currency0, currency1, totalAmount, takeProfitPercent, maxSwapOrders);
        return dcaId;
    }

    /* ==========================================================
       CANCEL / REDEEM FUNCTIONS
       ========================================================== */
    /// Cancel the DCA strategy completely.
    /// - Cancels ALL pending buy orders for this DCA strategy.
    /// - Cancels the pending take-profit sell order (if any).
    /// - Refunds all unspent input tokens to the user.
    /// - Burns the user's claim tokens and deactivates the strategy.
    function cancelDCAStrategy(uint256 dcaOrderId) external validOrder(dcaOrderId) {
        OrderInfo storage order = orders[dcaOrderId];
        if (order.user != msg.sender) revert NotAuthorized();

        PoolId poolId = order.poolKey.toId();
        uint256 totalPendingInput; // total unspent input to refund

        // Cancel all pending buy orders (input side)
        for (uint256 i = 0; i < order.ticksLength; i++) {
            int24 tick = orderTargetTicks[dcaOrderId][i];
            uint256 pendingAtTick = pendingOrders[poolId][tick][order.zeroForOne];
            if (pendingAtTick > 0) {
                totalPendingInput += pendingAtTick;
                pendingOrders[poolId][tick][order.zeroForOne] = 0;
                _removeOrderIdFromTick(poolId, tick, order.zeroForOne, dcaOrderId);
            }
        }

        // Cancel pending take-profit order if exists
        if (dcaTakeProfitTick[dcaOrderId] != 0) {
            _cancelTakeProfitOrder(dcaOrderId);
        }

        if (totalPendingInput == 0) revert OrderAlreadyExecutedUseRedeem();

        // Burn all claim tokens the user holds for this DCA (full cancellation semantics)
        uint256 userClaimBalance = balanceOf[msg.sender][dcaOrderId];
        if (userClaimBalance == 0) revert NoTokensToCancel();
        _burn(msg.sender, address(uint160(dcaOrderId)), userClaimBalance);
        if (claimTokensSupply[dcaOrderId] >= userClaimBalance) {
            claimTokensSupply[dcaOrderId] -= userClaimBalance;
        } else {
            claimTokensSupply[dcaOrderId] = 0;
        }

        // Mark order as cancelled
        order.status = IDCADexterBotV1.OrderStatus.CANCELLED;

        // Refund unspent input tokens with gas settlement
        uint256 adjustedRefund = _settleGasAccounting(dcaOrderId, totalPendingInput);
        Currency inputCurrency = order.zeroForOne ? order.poolKey.currency0 : order.poolKey.currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            (bool success,) = payable(msg.sender).call{value: adjustedRefund}("");
            require(success, "ETH send failed");
        } else {
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(msg.sender, adjustedRefund);
        }

        // Gas settlement handled above

        emit OrderCancelledOptimized(dcaOrderId, msg.sender);
    }

    /// Manual sell: Cancel the take-profit order and swap accumulated output at current market price.
    /// Then cancel all pending buy orders and restart the DCA cycle.
    /// This allows users to take profits immediately instead of waiting for the limit order.
    function sellNow(uint256 dcaId) external validOrder(dcaId) {
        OrderInfo storage order = orders[dcaId];
        if (order.user != msg.sender) revert NotAuthorized();

        // Must have accumulated output to sell
        uint256 sellAmount = dcaAccumulatedOutput[dcaId];
        require(sellAmount > 0, "Nothing to sell");

        // Determine sell direction (opposite of the original DCA direction)
        bool sellZeroForOne = !order.zeroForOne;

        // Cancel existing take-profit order
        if (dcaTakeProfitTick[dcaId] != 0) {
            _cancelTakeProfitOrder(dcaId);
        }

        // Cancel all pending DCA buy orders
        PoolId poolId = order.poolKey.toId();
        for (uint256 i = 0; i < order.ticksLength; i++) {
            int24 tick = orderTargetTicks[dcaId][i];
            uint256 pendingAmount = pendingOrders[poolId][tick][order.zeroForOne];

            if (pendingAmount > 0) {
                pendingOrders[poolId][tick][order.zeroForOne] = 0;
                _removeOrderIdFromTick(poolId, tick, order.zeroForOne, dcaId);
            }
        }

        // Perform the market sell via a direct swap
        SwapParams memory swapParams = SwapParams({
            zeroForOne: sellZeroForOne,
            amountSpecified: int256(sellAmount),
            sqrtPriceLimitX96: 0 // Market price
        });

        bytes memory data = abi.encode(order.poolKey, swapParams);
        uint256 amountOut;
        try poolManager.unlock(data) returns (bytes memory result) {
            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            // Compute output based on direction
            amountOut = sellZeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        } catch {
            revert("Manual sell swap failed");
        }

        // Reset accumulated output since we sold it all
        dcaAccumulatedOutput[dcaId] = 0;

        // Transfer proceeds with gas settlement
        uint256 adjustedProceeds = _settleGasAccounting(dcaId, amountOut);
        Currency proceedsToken = order.zeroForOne ? order.poolKey.currency0 : order.poolKey.currency1;
        if (Currency.unwrap(proceedsToken) == address(0)) {
            (bool success,) = payable(msg.sender).call{value: adjustedProceeds}("");
            require(success, "ETH send failed");
        } else {
            IERC20(Currency.unwrap(proceedsToken)).safeTransfer(msg.sender, adjustedProceeds);
        }

        // Restart the DCA cycle with profits
        _restartDCAWithProfits(dcaId, amountOut);

        emit DCASwapExecuted(dcaId, 1000, sellAmount, amountOut, sellZeroForOne); // 1000 == manual sell marker
    }

    // `redeemProfits` removed: profits are now recorded internally as `claimableOutputTokens` and may be
    // converted to on-chain proceeds via `sellNow`/take-profit execution. Integrations should rely on
    // emitted events (`DCARestarted`, `DCASwapExecuted`) to observe profit settlement and reinvestment.

    /* ==========================================================
       CALLBACK + HOOKS
       ========================================================== */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (data.length > 64) {
            (string memory operationType) = abi.decode(data, (string));
            if (keccak256(bytes(operationType)) == keccak256("general_liquidity")) {
                (, PoolKey memory key, ModifyLiquidityParams memory params) =
                    abi.decode(data, (string, PoolKey, ModifyLiquidityParams));
                return _handleGeneralLiquidityOperation(key, params);
            }
            try this._decodeLiquidityOperation(data) returns (
                PoolKey memory liquidityKey, uint256 amount, bool zeroForOne, string memory orderOperation
            ) {
                if (keccak256(bytes(orderOperation)) == keccak256("ADD_LIQUIDITY")) {
                    return _handleLiquidityOperation(liquidityKey, amount, zeroForOne);
                }
            } catch {}
        }
        (PoolKey memory swapKey, SwapParams memory swapParams) = abi.decode(data, (PoolKey, SwapParams));
        BalanceDelta delta = poolManager.swap(swapKey, swapParams, "");
        return abi.encode(delta);
    }

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

    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        // Remove dynamic fee requirement - use fee from createOrder parameter
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        lastTicks[key.toId()] = tick;
        PoolId poolId = key.toId();
        allPoolIds.push(poolId);
        poolIdToKey[poolId] = key;
        emit PoolInitializationTracked(poolId, tick, block.timestamp);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender == address(this)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        BeforeSwapDelta delta = _processLimitOrdersBeforeSwap(key, params);
        // Use the pool's actual fee instead of overriding
        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (msg.sender == address(this)) return (BaseHook.afterSwap.selector, 0);

        // Update last tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        lastTicks[key.toId()] = currentTick;

        // Gas managed internally through gasTank

        return (BaseHook.afterSwap.selector, 0);
    }

    /* ==========================================================
       INTERNAL HELPERS
       ========================================================== */
    function _processLimitOrdersBeforeSwap(PoolKey calldata key, SwapParams calldata params)
        internal
        returns (BeforeSwapDelta)
    {
        int24 currentTick;
        try this.getPoolCurrentTick(key.toId()) returns (int24 tick) {
            currentTick = tick;
        } catch {
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }
        int24 targetTick = _getTargetTick(params.sqrtPriceLimitX96, params.zeroForOne);
        (uint256 totalLimitOrderAmount, bool hasOrders) =
            _findLimitOrdersInRange(key.toId(), currentTick, targetTick, params.zeroForOne, key.tickSpacing);
        if (!hasOrders || totalLimitOrderAmount == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        uint256 swapAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 limitOrderFulfillment = _min(totalLimitOrderAmount, swapAmount);
        if (limitOrderFulfillment == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        _executeLimitOrdersInRange(key, currentTick, targetTick, params.zeroForOne, limitOrderFulfillment);
        return _createBeforeSwapDelta(params.zeroForOne, limitOrderFulfillment);
    }

    function _validateDCAInputs(
        uint32 takeProfitPercent,
        uint8 maxSwapOrders,
        uint32 priceDeviationPercent,
        uint32 priceDeviationMultiplier,
        uint256 swapOrderAmount,
        uint32 swapOrderMultiplier,
        uint256 expirationTime,
        address currency0,
        address currency1,
        uint256 gasBaseAmount
    ) internal view {
        if (takeProfitPercent == 0 || takeProfitPercent > 5000) revert InvalidTakeProfitPercent(); // 0-50%
        if (maxSwapOrders == 0 || maxSwapOrders > 10) revert InvalidMaxSwapOrders(); // 1-10 levels
        if (priceDeviationPercent == 0 || priceDeviationPercent > 2000) revert InvalidPriceDeviation(); // 0-20%
        if (priceDeviationMultiplier < 10 || priceDeviationMultiplier > 100) revert InvalidMultiplier(); // 0.1-10.0
        if (swapOrderAmount == 0) revert InvalidAmount();
        if (swapOrderMultiplier < 10 || swapOrderMultiplier > 100) revert InvalidMultiplier(); // 0.1-10.0
        if (expirationTime <= block.timestamp) revert ExpiredDeadline();
        if (currency0 == currency1) revert SameCurrencies();
        if (gasBaseAmount == 0) revert InsufficientGasTank();
    }

    function _calculateTotalStrategyGas(uint256 gasBaseAmount, uint8 maxSwapOrders) internal pure returns (uint256) {
        return (gasBaseAmount * (2 + maxSwapOrders) * 120) / 100; // 20% buffer included
    }

    function _calculateSwapGasCost() internal view returns (uint256) {
        return 150000 * tx.gasprice; // ESTIMATED_EXECUTION_GAS inlined
    }

    // Deduct gas using pre-allocation first, then gasTank
    function _deductGasForOrder(uint256 dcaId, uint256 gasCost) internal returns (bool success) {
        OrderInfo storage order = orders[dcaId];

        // Check if pre-allocation covers this gas cost
        if (order.gasUsed + gasCost <= order.gasAllocated) {
            order.gasUsed += gasCost;
            return true;
        }

        // Pre-allocation insufficient - borrow from gasTank
        uint256 shortfall = (order.gasUsed + gasCost) - order.gasAllocated;

        if (gasTank >= shortfall) {
            gasTank -= shortfall;
            order.gasUsed += gasCost;
            order.gasBorrowedFromTank += shortfall;
            return true;
        }

        return false;
    }

    // Reverse gas deduction when a swap fails
    function _reverseGasDeduction(uint256 dcaId, uint256 gasCost) internal {
        OrderInfo storage order = orders[dcaId];

        // If gas was borrowed from tank, reduce the borrowed amount
        if (order.gasBorrowedFromTank > 0) {
            uint256 borrowedToReverse = gasCost > order.gasBorrowedFromTank ? order.gasBorrowedFromTank : gasCost;
            gasTank += borrowedToReverse;
            order.gasBorrowedFromTank -= borrowedToReverse;
            gasCost -= borrowedToReverse;
        }

        order.gasUsed -= gasCost;
    }

    function _calculateInitialDCALevel(
        PoolKey memory key,
        bool zeroForOne,
        uint32 priceDeviationPercent,
        uint32 priceDeviationMultiplier,
        uint256 baseSwapAmount,
        uint32 swapOrderMultiplier
    ) internal view returns (int24[] memory targetTicks, uint256[] memory targetAmounts, uint256 totalAmount) {
        // Get current price
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());

        // Create only the first DCA level
        targetTicks = new int24[](1);
        targetAmounts = new uint256[](1);

        // Calculate first level deviation (level 1 = 1 * priceDeviationPercent)
        // priceDeviationPercent is stored as basis points (500 = 5%)
        // @note CHANGED THIS from
        // uint256 level1DeviationBps = uint256(priceDeviationPercent);
        uint256 level1DeviationBps = (uint256(priceDeviationPercent) * uint256(priceDeviationMultiplier)) / 10; // Level 1 uses base deviation

        // Calculate tick deviation for first level
        int24 tickDeviation = int24(int256((level1DeviationBps * uint256(int256(key.tickSpacing))) / 10000));

        // Set target tick based on direction
        if (zeroForOne) {
            // Selling: set first buy level below current price
            targetTicks[0] = currentTick - tickDeviation;
        } else {
            // Buying: set first sell level above current price
            targetTicks[0] = currentTick + tickDeviation;
        }

        // Calculate amount for first level using exponential multiplier
        // Level 1: base * multiplier^1
        uint256 amountLevelMultiplier = _calculateExponentialMultiplier(1, uint256(swapOrderMultiplier));
        targetAmounts[0] = (baseSwapAmount * amountLevelMultiplier) / 10;

        totalAmount = baseSwapAmount + targetAmounts[0]; // Initial swap + first DCA level
    }

    function _calculateNextDCALevel(uint256 dcaId, PoolKey memory key)
        internal
        view
        returns (int24 nextTick, uint256 nextAmount)
    {
        OrderInfo storage order = orders[dcaId];
        uint256 nextLevel = dcaCurrentLevel[dcaId] + 1;

        // Don't exceed max swap orders
        if (nextLevel >= order.maxSwapOrders) {
            return (0, 0);
        }

        // Get current price
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());

        // Calculate deviation for next level (linear scaling)
        // Level N gets N * priceDeviationPercent deviation
        uint256 levelDeviationBps = uint256(order.priceDeviationPercent) * (nextLevel + 1);

        int24 tickDeviation = int24(int256((levelDeviationBps * uint256(int256(key.tickSpacing))) / 10000));

        // Set target tick
        if (order.zeroForOne) {
            nextTick = currentTick - tickDeviation;
        } else {
            nextTick = currentTick + tickDeviation;
        }

        // Calculate amount for next level using exponential multiplier
        uint256 amountLevelMultiplier =
            _calculateExponentialMultiplier(nextLevel + 1, uint256(order.swapOrderMultiplier));
        nextAmount = (order.baseSwapAmount * amountLevelMultiplier) / 10;
    }

    function _calculateExponentialMultiplier(uint256 level, uint256 baseMultiplier) internal pure returns (uint256) {
        // Exponential scaling: multiplier = baseMultiplier^level
        // baseMultiplier is stored as e.g. 20 for 2.0x
        // Level 1: 2^1 = 2, Level 2: 2^2 = 4, Level 3: 2^3 = 8
        // We scale by 10, so: Level 1: 20, Level 2: 40, Level 3: 80

        if (level == 0) return 10; // 1.0x for level 0

        uint256 result = baseMultiplier; // Start with base (e.g. 20 for 2.0x)
        for (uint256 i = 1; i < level; i++) {
            result = (result * baseMultiplier) / 10; // Multiply by base, keeping scale
        }
        return result;
    }

    function _createPoolKey(address currency0, address currency1, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee, // Use the fee parameter directly, no dynamic fee flag
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(this))
        });
    }

    function _createDCAStrategy(
        PoolKey memory key,
        int24[] memory targetTicks,
        uint256[] memory targetAmounts,
        uint256 totalAmount,
        bool zeroForOne,
        uint32 slippage,
        uint256 expirationTime,
        uint32 takeProfitPercent,
        uint8 maxSwapOrders,
        uint32 priceDeviationPercent,
        uint32 priceDeviationMultiplier,
        uint256 baseSwapAmount,
        uint32 swapOrderMultiplier,
        uint256 gasAllocated
    ) internal returns (uint256 dcaId) {
        dcaId = nextOrderId++;
        orderTargetTicks[dcaId] = targetTicks;
        orderTargetAmounts[dcaId] = targetAmounts;

        orders[dcaId] = OrderInfo({
            user: msg.sender,
            totalAmount: uint96(totalAmount),
            poolKey: key,
            expirationTime: uint64(expirationTime),
            maxSlippageBps: slippage,
            takeProfitPercent: takeProfitPercent,
            ticksLength: uint16(targetTicks.length),
            maxSwapOrders: maxSwapOrders,
            zeroForOne: zeroForOne,
            status: IDCADexterBotV1.OrderStatus.ACTIVE,
            isPerpetual: true, // DCA orders are perpetual
            priceDeviationPercent: priceDeviationPercent,
            priceDeviationMultiplier: priceDeviationMultiplier,
            baseSwapAmount: baseSwapAmount,
            swapOrderMultiplier: swapOrderMultiplier,
            gasAllocated: gasAllocated,
            gasUsed: 0, // Track actual gas consumption
            gasBorrowedFromTank: 0 // Track gas borrowed from central tank when allocation insufficient
        });

        // Allocate gas for this strategy to the central gas tank
        gasTank += gasAllocated;

        // Register pending orders
        PoolId poolId = key.toId();
        for (uint256 i = 0; i < targetTicks.length; i++) {
            pendingOrders[poolId][targetTicks[i]][zeroForOne] += targetAmounts[i];
            tickToOrderIds[poolId][targetTicks[i]][zeroForOne].push(dcaId);
        }

        claimTokensSupply[dcaId] = totalAmount;
        _mint(msg.sender, address(uint160(dcaId)), totalAmount);
    }

    function _initiateFirstDCASwap(uint256 dcaId) internal {
        OrderInfo storage order = orders[dcaId];

        // Use pre-allocation first, fallback to gasTank if needed
        uint256 swapGasCost = _calculateSwapGasCost();
        if (!_deductGasForOrder(dcaId, swapGasCost)) {
            order.status = IDCADexterBotV1.OrderStatus.STALLED;
            return; // Cannot execute without gas
        }

        // Execute immediate swap at base amount
        SwapParams memory swapParams = SwapParams({
            zeroForOne: order.zeroForOne,
            amountSpecified: int256(order.baseSwapAmount),
            sqrtPriceLimitX96: 0 // No price limit for initial swap
        });

        bytes memory data = abi.encode(order.poolKey, swapParams);

        try poolManager.unlock(data) returns (bytes memory result) {
            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            uint256 amountOut = order.zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));

            // Update DCA tracking
            dcaAccumulatedInput[dcaId] = order.baseSwapAmount;
            dcaAccumulatedOutput[dcaId] = amountOut;
            dcaCurrentLevel[dcaId] = 0; // Initial swap completed

            // Update claimable output tokens with swap result
            claimableOutputTokens[dcaId] += amountOut;

            // Create take profit order at calculated margin
            _createTakeProfitOrder(dcaId);

            emit DCASwapExecuted(dcaId, 0, order.baseSwapAmount, amountOut, order.zeroForOne);
        } catch {
            // If swap fails, reverse gas deduction properly
            _reverseGasDeduction(dcaId, swapGasCost);
            emit DCASwapExecuted(dcaId, 0, order.baseSwapAmount, 0, order.zeroForOne);
        }
    }

    function _createTakeProfitOrder(uint256 dcaId) internal {
        OrderInfo storage order = orders[dcaId];
        PoolId poolId = order.poolKey.toId();

        // Get current tick and calculate take profit tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Calculate take profit tick based on percentage
        int24 takeProfitTickOffset =
            int24(int256((uint256(order.takeProfitPercent) * uint256(int256(order.poolKey.tickSpacing))) / 100));

        int24 takeProfitTick;
        if (order.zeroForOne) {
            // If we're selling token0 for token1, take profit by selling token1 back for token0
            takeProfitTick = currentTick - takeProfitTickOffset;
        } else {
            // If we're buying token0 with token1, take profit by selling token0 for token1
            takeProfitTick = currentTick + takeProfitTickOffset;
        }

        // Cancel previous take profit order if exists
        if (dcaTakeProfitTick[dcaId] != 0) {
            _cancelTakeProfitOrder(dcaId);
        }

        // Create new take profit order with accumulated output
        uint256 takeProfitAmount = dcaAccumulatedOutput[dcaId];
        bool takeProfitDirection = !order.zeroForOne; // Opposite direction

        pendingOrders[poolId][takeProfitTick][takeProfitDirection] += takeProfitAmount;
        tickToOrderIds[poolId][takeProfitTick][takeProfitDirection].push(dcaId);

        // Update tracking
        dcaTakeProfitTick[dcaId] = takeProfitTick;
    }

    function _cancelTakeProfitOrder(uint256 dcaId) internal {
        OrderInfo storage order = orders[dcaId];
        PoolId poolId = order.poolKey.toId();
        int24 oldTakeProfitTick = dcaTakeProfitTick[dcaId];

        if (oldTakeProfitTick != 0) {
            bool takeProfitDirection = !order.zeroForOne;

            // Remove from pending orders
            uint256 oldAmount = dcaAccumulatedOutput[dcaId];
            if (pendingOrders[poolId][oldTakeProfitTick][takeProfitDirection] >= oldAmount) {
                pendingOrders[poolId][oldTakeProfitTick][takeProfitDirection] -= oldAmount;
            }

            // Remove from tick tracking
            _removeOrderIdFromTick(poolId, oldTakeProfitTick, takeProfitDirection, dcaId);

            dcaTakeProfitTick[dcaId] = 0;
        }
    }

    /// Restart the DCA cycle after manual sell by reinvesting profits.
    /// This creates a new initial swap and updates the accumulation tracking.
    function _restartDCAWithProfits(uint256 dcaId, uint256 profitAmount) internal {
        OrderInfo storage order = orders[dcaId];

        // Only restart if this is a perpetual DCA order
        if (!order.isPerpetual) return;

        // Update accumulated input with the profit amount
        dcaAccumulatedInput[dcaId] += profitAmount;

        // Reset the current level to restart progression
        dcaCurrentLevel[dcaId] = 0;

        // Create the first level with the profit amount
        (int24[] memory newTargetTicks, uint256[] memory newTargetAmounts,) = _calculateInitialDCALevel(
            order.poolKey,
            order.zeroForOne,
            order.priceDeviationPercent,
            order.priceDeviationMultiplier,
            profitAmount, // Use profit as new base amount
            order.swapOrderMultiplier
        );

        // Add the new level to pending orders
        if (newTargetTicks.length > 0) {
            PoolId poolId = order.poolKey.toId();
            pendingOrders[poolId][newTargetTicks[0]][order.zeroForOne] += newTargetAmounts[0];
            tickToOrderIds[poolId][newTargetTicks[0]][order.zeroForOne].push(dcaId);

            // Update order target arrays
            orderTargetTicks[dcaId].push(newTargetTicks[0]);
            orderTargetAmounts[dcaId].push(newTargetAmounts[0]);
            order.ticksLength++;
        }

        // Create new take profit order based on updated accumulation
        _createTakeProfitOrder(dcaId);

        emit DCARestarted(dcaId, profitAmount);
    }

    function _removeOrderIdFromTick(PoolId poolId, int24 tick, bool zeroForOne, uint256 orderId) internal {
        uint256[] storage orderIds = tickToOrderIds[poolId][tick][zeroForOne];
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (orderIds[i] == orderId) {
                orderIds[i] = orderIds[orderIds.length - 1];
                orderIds.pop();
                break;
            }
        }

        // Clean up empty tick mapping
        if (orderIds.length == 0 && pendingOrders[poolId][tick][zeroForOne] == 0) {
            delete tickToOrderIds[poolId][tick][zeroForOne];
        }
    }

    function _ensurePoolInitialized(PoolKey memory key) internal view {
        (uint160 currentPrice,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (currentPrice > 0) return;
        revert();
    }

    function _handleTokenDeposit(PoolKey memory key, bool zeroForOne, uint256 totalAmount, uint256 gasAllocation)
        internal
    {
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        if (sellToken == address(0)) {
            // For ETH swaps, require total amount + gas allocation
            uint256 requiredETH = totalAmount + gasAllocation;
            if (msg.value < requiredETH) revert InsufficientETHForOrderPlusGas();
            if (msg.value > requiredETH) {
                (bool success,) = payable(msg.sender).call{value: msg.value - requiredETH}("");
                require(success, "ETH refund failed");
            }
            // Gas is already allocated to gasTank in _createDCAStrategy
        } else {
            // For token swaps, require ETH for gas allocation + token amount
            if (msg.value < gasAllocation) revert InsufficientGasTank();
            if (msg.value > gasAllocation) {
                (bool success,) = payable(msg.sender).call{value: msg.value - gasAllocation}("");
                require(success, "ETH refund failed");
            }
            // Gas is already allocated to gasTank in _createDCAStrategy
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        }
    }

    function _transfer(uint256 orderId, uint256 outputAmount) internal {
        OrderInfo storage order = orders[orderId];
        Currency outputToken = order.zeroForOne ? order.poolKey.currency1 : order.poolKey.currency0;
        outputToken.transfer(msg.sender, outputAmount);
    }

    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        return 60;
    }

    function _decodeLiquidityOperation(bytes calldata data)
        external
        pure
        returns (PoolKey memory key, uint256 amount, bool zeroForOne, string memory operation)
    {
        return abi.decode(data, (PoolKey, uint256, bool, string));
    }

    function _handleLiquidityOperation(PoolKey memory key, uint256 amount, bool) internal returns (bytes memory) {
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (currentTick - (100 * tickSpacing)) / tickSpacing * tickSpacing;
        int24 tickUpper = (currentTick + (100 * tickSpacing)) / tickSpacing * tickSpacing;
        uint128 liquidityDelta = uint128(amount / 100);
        if (liquidityDelta == 0) liquidityDelta = 1000;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityDelta)),
            salt: bytes32(uint256(block.timestamp))
        });
        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(key, params, "");
        return abi.encode(callerDelta);
    }

    function _handleGeneralLiquidityOperation(PoolKey memory key, ModifyLiquidityParams memory params)
        internal
        returns (bytes memory)
    {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        if (delta.amount0() > 0) {
            if (Currency.unwrap(key.currency0) == address(0)) {
                poolManager.settle{value: uint256(int256(delta.amount0()))}();
            } else {
                Currency.wrap(Currency.unwrap(key.currency0)).transfer(
                    address(poolManager), uint256(int256(delta.amount0()))
                );
                poolManager.settle();
            }
        }
        if (delta.amount1() > 0) {
            Currency.wrap(Currency.unwrap(key.currency1)).transfer(
                address(poolManager), uint256(int256(delta.amount1()))
            );
            poolManager.settle();
        }
        return abi.encode(delta);
    }

    /* ==========================================================
       LIMIT ORDER HELPERS
       ========================================================== */
    function _getTargetTick(uint160 sqrtPriceLimitX96, bool zeroForOne) internal pure returns (int24) {
        if (sqrtPriceLimitX96 == 0) {
            return zeroForOne ? TickMath.MIN_TICK : TickMath.MAX_TICK;
        }
        return TickMath.getTickAtSqrtPrice(sqrtPriceLimitX96);
    }

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
            for (int24 tick = currentTick; tick >= targetTick; tick -= tickSpacing) {
                uint256 amount = pendingOrders[poolId][tick][false];
                if (amount > 0) {
                    totalAmount += amount;
                    hasOrders = true;
                }
            }
        } else {
            for (int24 tick = currentTick; tick <= targetTick; tick += tickSpacing) {
                uint256 amount = pendingOrders[poolId][tick][true];
                if (amount > 0) {
                    totalAmount += amount;
                    hasOrders = true;
                }
            }
        }
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
                uint256 availableAmount = pendingOrders[poolId][tick][limitOrderDirection];
                if (availableAmount > 0) {
                    uint256 executeAmount = _min(availableAmount, remainingAmount);
                    _executeLimitOrdersAtTick(poolId, tick, limitOrderDirection, executeAmount);
                    remainingAmount -= executeAmount;
                }
            }
        } else {
            for (int24 tick = currentTick; tick <= targetTick && remainingAmount > 0; tick += key.tickSpacing) {
                uint256 availableAmount = pendingOrders[poolId][tick][limitOrderDirection];
                if (availableAmount > 0) {
                    uint256 executeAmount = _min(availableAmount, remainingAmount);
                    _executeLimitOrdersAtTick(poolId, tick, limitOrderDirection, executeAmount);
                    remainingAmount -= executeAmount;
                }
            }
        }
    }

    function _executeLimitOrdersAtTick(PoolId poolId, int24 tick, bool zeroForOne, uint256 amountToExecute) internal {
        pendingOrders[poolId][tick][zeroForOne] -= amountToExecute;
        uint256[] storage orderIds = tickToOrderIds[poolId][tick][zeroForOne];
        uint256 remainingToExecute = amountToExecute;

        for (uint256 i = 0; i < orderIds.length && remainingToExecute > 0; i++) {
            uint256 orderId = orderIds[i];
            OrderInfo storage order = orders[orderId];
            if (order.status != IDCADexterBotV1.OrderStatus.ACTIVE) continue;

            // Check if order can afford gas (allocation + tank availability)
            if (order.isPerpetual && order.status == IDCADexterBotV1.OrderStatus.ACTIVE) {
                uint256 estimatedGasCost = _calculateSwapGasCost();
                uint256 remainingAllocation =
                    order.gasAllocated > order.gasUsed ? order.gasAllocated - order.gasUsed : 0;
                uint256 shortfall = estimatedGasCost > remainingAllocation ? estimatedGasCost - remainingAllocation : 0;

                if (shortfall > 0 && gasTank < shortfall) {
                    order.status = IDCADexterBotV1.OrderStatus.STALLED;
                    continue;
                }
            }

            // Check if this is a take profit order execution
            if (dcaTakeProfitTick[orderId] == tick && zeroForOne == (!order.zeroForOne)) {
                // Take profit hit! Handle restart
                _handleTakeProfitHit(orderId, remainingToExecute);
                continue;
            }

            for (uint256 j = 0; j < order.ticksLength; j++) {
                if (orderTargetTicks[orderId][j] == tick) {
                    uint256 orderAmountAtTick = orderTargetAmounts[orderId][j];
                    uint256 executeFromOrder = _min(orderAmountAtTick, remainingToExecute);
                    claimableOutputTokens[orderId] += executeFromOrder;
                    remainingToExecute -= executeFromOrder;

                    // Use pre-allocation first, fallback to gasTank if needed
                    uint256 limitOrderGasCost = _calculateSwapGasCost();
                    if (!_deductGasForOrder(orderId, limitOrderGasCost)) {
                        order.status = IDCADexterBotV1.OrderStatus.STALLED;
                        continue;
                    }

                    // Execute DCA processing
                    if (order.isPerpetual && executeFromOrder > 0) {
                        _handleDCAExecution(orderId, executeFromOrder);
                    }
                    break;
                }
            }
        }
        if (pendingOrders[poolId][tick][zeroForOne] == 0) {
            delete tickToOrderIds[poolId][tick][zeroForOne];
        }
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

    function _handleDCAExecution(uint256 dcaId, uint256 buyAmount) internal {
        OrderInfo storage order = orders[dcaId];

        // Update accumulated position
        dcaAccumulatedInput[dcaId] += buyAmount;
        // Note: accumulated output will be updated when the actual buy swap happens

        // Increment current level
        dcaCurrentLevel[dcaId]++;

        // Create next DCA level if we haven't reached max
        (int24 nextTick, uint256 nextAmount) = _calculateNextDCALevel(dcaId, order.poolKey);
        if (nextTick != 0 && nextAmount > 0) {
            PoolId poolId = order.poolKey.toId();

            // Add next level to pending orders
            pendingOrders[poolId][nextTick][order.zeroForOne] += nextAmount;
            tickToOrderIds[poolId][nextTick][order.zeroForOne].push(dcaId);

            // Update order target arrays to include new level
            orderTargetTicks[dcaId].push(nextTick);
            orderTargetAmounts[dcaId].push(nextAmount);
            order.ticksLength++;
        }

        // Recreate take profit order with updated accumulated position
        _createTakeProfitOrder(dcaId);

        emit DCASwapExecuted(dcaId, dcaCurrentLevel[dcaId], buyAmount, 0, order.zeroForOne);
    }

    // Settle gas accounting when order completes
    function _settleGasAccounting(uint256 dcaId, uint256 profitAmount) internal returns (uint256 adjustedAmount) {
        OrderInfo storage order = orders[dcaId];
        uint256 remainingProfit = profitAmount;

        // First, repay any gas borrowed from tank
        if (order.gasBorrowedFromTank > 0) {
            if (remainingProfit >= order.gasBorrowedFromTank) {
                gasTank += order.gasBorrowedFromTank;
                remainingProfit -= order.gasBorrowedFromTank;
                order.gasBorrowedFromTank = 0;
            } else {
                gasTank += remainingProfit;
                order.gasBorrowedFromTank -= remainingProfit;
                remainingProfit = 0;
            }
        }

        // Then handle gas allocation accounting
        if (order.gasUsed <= order.gasAllocated) {
            // Under-used gas: refund excess to profit
            uint256 gasRefund = order.gasAllocated - order.gasUsed;
            gasTank -= gasRefund; // Remove unused allocation from tank
            adjustedAmount = remainingProfit + gasRefund;
        } else {
            // Over-used gas: deduct deficit from profit
            uint256 gasDeficit = order.gasUsed - order.gasAllocated;
            if (remainingProfit >= gasDeficit) {
                adjustedAmount = remainingProfit - gasDeficit;
                gasTank += gasDeficit; // User pays back the deficit
            } else {
                // Profit insufficient to cover deficit - user pays what they can
                gasTank += remainingProfit;
                adjustedAmount = 0;
            }
        }

        return adjustedAmount;
    }

    function _handleTakeProfitHit(uint256 dcaId, uint256 takeProfitAmount) internal {
        OrderInfo storage order = orders[dcaId];
        PoolId poolId = order.poolKey.toId();

        // Cancel all pending DCA buy orders
        for (uint256 i = 0; i < order.ticksLength; i++) {
            int24 tick = orderTargetTicks[dcaId][i];
            uint256 pendingAmount = pendingOrders[poolId][tick][order.zeroForOne];

            if (pendingAmount > 0) {
                pendingOrders[poolId][tick][order.zeroForOne] = 0;
                _removeOrderIdFromTick(poolId, tick, order.zeroForOne, dcaId);
            }
        }

        // Clear take profit order
        _cancelTakeProfitOrder(dcaId);

        // Mark as completed - take profit was hit
        order.status = IDCADexterBotV1.OrderStatus.COMPLETED;

        // Update claimable tokens with take profit execution
        claimableOutputTokens[dcaId] += takeProfitAmount;

        emit DCASwapExecuted(dcaId, 999, takeProfitAmount, 0, !order.zeroForOne); // 999 indicates take profit
    }

    function _calculateEstimatedGasFee() internal view returns (uint256) {
        uint256 estimatedCost = 150000 * tx.gasprice; // ESTIMATED_EXECUTION_GAS inlined
        estimatedCost = (estimatedCost * 120) / 100; // GAS_PRICE_BUFFER_MULTIPLIER inlined
        if (estimatedCost > 0.01 ether) estimatedCost = 0.01 ether; // MAX_GAS_FEE_ETH inlined
        return estimatedCost;
    }

    /* ==========================================================
       VIEW FUNCTIONS
       ========================================================== */

    // function getGasRefundInfo(uint256 orderId) external view returns (uint256 preCollected, uint256 actualUsed, uint256 refundable, bool processed) {
    //     // Deprecated: Old gas refund system removed
    //     preCollected = 0;
    //     actualUsed = 0;
    //     processed = false;
    //     refundable = 0;
    // }

    function getPoolCurrentTick(PoolId poolId) external view returns (int24) {
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        return currentTick;
    }

    function getAllPools()
        external
        view
        returns (PoolId[] memory poolIds, PoolKey[] memory poolKeys, int24[] memory ticks)
    {
        uint256 length = allPoolIds.length;
        poolIds = new PoolId[](length);
        poolKeys = new PoolKey[](length);
        ticks = new int24[](length);
        for (uint256 i = 0; i < length; i++) {
            poolIds[i] = allPoolIds[i];
            poolKeys[i] = poolIdToKey[allPoolIds[i]];
            ticks[i] = lastTicks[allPoolIds[i]];
        }
    }

    function getPoolCount() external view returns (uint256) {
        return allPoolIds.length;
    }

    function getDCAInfo(uint256 dcaId)
        external
        view
        returns (
            address user,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256 claimableAmount,
            IDCADexterBotV1.OrderStatus status,
            bool isFullyExecuted,
            uint256 expirationTime,
            bool zeroForOne,
            uint256 totalOrders,
            uint24 currentFee
        )
    {
        OrderInfo storage order = orders[dcaId];
        if (order.user == address(0)) revert InvalidOrder();
        uint256 execAmount = uint256(order.totalAmount) - claimTokensSupply[dcaId];
        return (
            order.user,
            Currency.unwrap(order.poolKey.currency0),
            Currency.unwrap(order.poolKey.currency1),
            uint256(order.totalAmount),
            execAmount,
            claimableOutputTokens[dcaId],
            order.status,
            claimTokensSupply[dcaId] == 0,
            uint256(order.expirationTime),
            order.zeroForOne,
            nextOrderId - 1,
            order.poolKey.fee
        );
    }

    function getDCAInfoExtended(uint256 dcaId)
        external
        view
        returns (
            address user,
            address currency0,
            address currency1,
            uint256 totalAmount,
            uint256 executedAmount,
            uint256 claimableAmount,
            IDCADexterBotV1.OrderStatus status,
            bool isFullyExecuted,
            uint256 expirationTime,
            bool zeroForOne,
            uint256 totalOrders,
            uint24 currentFee,
            uint256 gasAllocated,
            uint256 gasUsed,
            uint256 gasBorrowedFromTank
        )
    {
        OrderInfo storage order = orders[dcaId];
        if (order.user == address(0)) revert InvalidOrder();
        uint256 execAmount = uint256(order.totalAmount) - claimTokensSupply[dcaId];
        return (
            order.user,
            Currency.unwrap(order.poolKey.currency0),
            Currency.unwrap(order.poolKey.currency1),
            uint256(order.totalAmount),
            execAmount,
            claimableOutputTokens[dcaId],
            order.status,
            claimTokensSupply[dcaId] == 0,
            uint256(order.expirationTime),
            order.zeroForOne,
            nextOrderId - 1,
            order.poolKey.fee,
            order.gasAllocated,
            order.gasUsed,
            order.gasBorrowedFromTank
        );
    }

    function getDCAOrder(uint256 dcaId)
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
            IDCADexterBotV1.OrderStatus status,
            bool isFullyExecuted
        )
    {
        OrderInfo storage order = orders[dcaId];
        int24[] memory targetTicks = orderTargetTicks[dcaId];
        uint256[] memory amounts = orderTargetAmounts[dcaId];
        uint256[] memory prices = new uint256[](targetTicks.length);
        for (uint256 i = 0; i < targetTicks.length; i++) {
            prices[i] = TickMath.getSqrtPriceAtTick(targetTicks[i]);
        }
        return (
            order.user,
            Currency.unwrap(order.poolKey.currency0),
            Currency.unwrap(order.poolKey.currency1),
            uint256(order.totalAmount),
            uint256(order.totalAmount) - claimTokensSupply[dcaId],
            prices,
            amounts,
            order.status,
            claimTokensSupply[dcaId] == 0
        );
    }

    /* ==========================================================
       FALLBACKS
       ========================================================== */
    receive() external payable {}
    fallback() external payable {}
}
