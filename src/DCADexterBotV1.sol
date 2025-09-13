    error InsufficientETHForOrderPlusGas();
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  ----------  imports  ----------  */
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDCADexterBotV1} from "./interfaces/IDCADexterBotV1.sol";
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
    mapping(PoolId => mapping(int24 => mapping(bool => uint256))) public pendingBatchOrders;
    mapping(uint256 => uint256) public claimableOutputTokens;
    mapping(uint256 => uint256) public claimTokensSupply;
    mapping(PoolId => mapping(int24 => mapping(bool => uint256[]))) internal tickToBatchIds;

    // DCA state tracking
    mapping(uint256 => uint256) public dcaAccumulatedInput; // Total input amount accumulated
    mapping(uint256 => uint256) public dcaAccumulatedOutput; // Total output amount accumulated  
    mapping(uint256 => uint256) public dcaCurrentLevel; // Current DCA level (0 = initial swap done)
    mapping(uint256 => int24) public dcaTakeProfitTick; // Current take profit tick

    struct BatchInfo {
        address user;
        uint96 totalAmount;
        PoolKey poolKey;
        uint64 expirationTime;
        uint32 maxSlippageBps;
        uint32 takeProfitPercent; // NEW - take profit %
        uint16 ticksLength;
        uint8 maxSwapOrders; // NEW - max DCA levels
        bool zeroForOne;
        bool isActive;
        bool isPerpetual; // NEW - indicates this is a perpetual DCA order
        bool isStalled; // NEW - indicates gas pool is exhausted
        // DCA-specific parameters
        uint32 priceDeviationPercent; // NEW
        uint32 priceDeviationMultiplier; // NEW
        uint256 baseSwapAmount; // NEW - base swap amount
        uint32 swapOrderMultiplier; // NEW
    uint256 gasTank; // NEW - gas tank for DCA executions
    uint32 gasTankPercent; // NEW - percentage of each swap that goes to gas tank
    }

    mapping(uint256 => int24[]) public batchTargetTicks;
    mapping(uint256 => uint256[]) public batchTargetAmounts;
    mapping(uint256 => BatchInfo) public batchOrders;
    uint256 public nextBatchOrderId = 1;

    PoolId[] public allPoolIds;
    mapping(PoolId => PoolKey) public poolIdToKey;
    

    /* ==========================================================
       CONSTANTS – updated to remove BASE_FEE since we use pool fee parameter
       ========================================================== */
    uint256 public constant ESTIMATED_EXECUTION_GAS = 150000;
    uint256 public constant GAS_PRICE_BUFFER_MULTIPLIER = 120;
    uint256 public constant MAX_GAS_FEE_ETH = 0.01 ether;

    /* ==========================================================
       ERRORS – DCA system errors
       ========================================================== */
    error NothingToClaim();
    error InvalidBatchId();
    error OrderNotActive();
    error NotAuthorized();
    error NoTokensToCancel();
    error BatchAlreadyExecutedUseRedeem();
    error InsufficientClaimTokenBalance();
    error InvalidFeeRecipient();
    error InvalidExecutorAddress();
    error ExpiredDeadline();
    error SameCurrencies();
    error InvalidAmount();
    error InvalidBatch();
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
    event DCAOrderCreated(uint256 indexed dcaId, address indexed user, address currency0, address currency1, 
                         uint256 totalAmount, uint32 takeProfitPercent, uint8 maxSwapOrders);
    event DCASwapExecuted(uint256 indexed dcaId, uint256 level, uint256 amountIn, uint256 amountOut, bool direction);
    event DCARestarted(uint256 indexed dcaId, uint256 profitAmount);
    event GasTankContribution(uint256 indexed dcaId, uint256 amount);
    event DCAStalled(uint256 indexed dcaId, uint256 gasTankRemaining);
    event BatchOrderCancelledOptimized(uint256 indexed batchId, address indexed user);
    event TokensRedeemedOptimized(uint256 indexed batchId, address indexed user, uint256 amount);
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);

    modifier validBatchOrder(uint256 batchId) {
        if (!(batchId > 0 && batchId < nextBatchOrderId)) revert InvalidBatchId();
        if (!batchOrders[batchId].isActive) revert OrderNotActive();
        if (batchOrders[batchId].isStalled) revert OrderStalled();
        _;
    }

    constructor(IPoolManager _poolManager, address _feeRecipient, address _executor)
        BaseHook(_poolManager)
    {
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (_executor == address(0)) revert InvalidExecutorAddress();
    }

    /* ==========================================================
       CREATE DCA ORDER – new DCA system
       ========================================================== */
    // New modularized createDCAOrder using PoolParams and DCAParams
    function createDCAOrder(
        IDCADexterBotV1.PoolParams calldata pool,
        IDCADexterBotV1.DCAParams calldata dca,
        uint32 slippage,
        uint256 expirationTime,
        uint256 gasTankAmount,
        uint32 gasTankPercent
    ) external payable virtual returns (uint256 dcaId) {
        return _createDCAOrderInternal(
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
            gasTankAmount,
            gasTankPercent
        );
    }

    function _createDCAOrderInternal(
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
        uint256 gasTankAmount,
        uint32 gasTankPercent
    ) internal returns (uint256 dcaId) {
    _validateDCAInputs(takeProfitPercent, maxSwapOrders, priceDeviationPercent, 
              priceDeviationMultiplier, swapOrderAmount, swapOrderMultiplier, 
              expirationTime, currency0, currency1, gasTankAmount, gasTankPercent);
        
        PoolKey memory key = _createPoolKey(currency0, currency1, fee);
        _ensurePoolInitialized(key);
        
        // Calculate only the first DCA level for now - progressive creation
        (int24[] memory targetTicks, uint256[] memory targetAmounts, uint256 totalAmount) = 
            _calculateInitialDCALevel(key, zeroForOne, priceDeviationPercent, 
                               priceDeviationMultiplier, swapOrderAmount, swapOrderMultiplier);

    dcaId = _createDCABatch(key, targetTicks, targetAmounts, totalAmount,
                   zeroForOne, slippage, expirationTime, takeProfitPercent, maxSwapOrders,
                               priceDeviationPercent, priceDeviationMultiplier, 
                               swapOrderAmount, swapOrderMultiplier, gasTankAmount, gasTankPercent);

        _handleTokenDeposit(key, zeroForOne, totalAmount, gasTankAmount);

        // Start initial buy swap immediately at swapOrderAmount
        _initiateFirstDCASwap(dcaId);

        emit DCAOrderCreated(dcaId, msg.sender, currency0, currency1, totalAmount, 
                           takeProfitPercent, maxSwapOrders);
        return dcaId;
    }
         
    /* ==========================================================
       CANCEL / REDEEM FUNCTIONS
       ========================================================== */
    /// Cancel the DCA order completely.
    /// - Cancels ALL pending buy levels for this DCA.
    /// - Cancels the pending take-profit sell order (if any).
    /// - Refunds all unspent input tokens to the user.
    /// - Burns the user's claim tokens and deactivates the order.
    function cancelDCAOrder(uint256 dcaOrderId) external validBatchOrder(dcaOrderId) {
        BatchInfo storage batch = batchOrders[dcaOrderId];
        if (batch.user != msg.sender) revert NotAuthorized();

        PoolId poolId = batch.poolKey.toId();
        uint256 totalPendingInput; // total unspent input to refund

        // Cancel all pending buy orders (input side)
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 tick = batchTargetTicks[dcaOrderId][i];
            uint256 pendingAtTick = pendingBatchOrders[poolId][tick][batch.zeroForOne];
            if (pendingAtTick > 0) {
                totalPendingInput += pendingAtTick;
                pendingBatchOrders[poolId][tick][batch.zeroForOne] = 0;
                _removeBatchIdFromTick(poolId, tick, batch.zeroForOne, dcaOrderId);
            }
        }

        // Cancel pending take-profit order if it exists (opposite direction)
        if (dcaTakeProfitTick[dcaOrderId] != 0) {
            _cancelTakeProfitOrder(dcaOrderId);
        }

        if (totalPendingInput == 0) revert BatchAlreadyExecutedUseRedeem();

        // Burn all claim tokens the user holds for this DCA (full cancellation semantics)
        uint256 userClaimBalance = balanceOf[msg.sender][dcaOrderId];
        if (userClaimBalance == 0) revert NoTokensToCancel();
        _burn(msg.sender, address(uint160(dcaOrderId)), userClaimBalance);
        if (claimTokensSupply[dcaOrderId] >= userClaimBalance) {
            claimTokensSupply[dcaOrderId] -= userClaimBalance;
        } else {
            claimTokensSupply[dcaOrderId] = 0;
        }

        // Mark order inactive
        batch.isActive = false;

        // Refund unspent input tokens
        Currency inputCurrency = batch.zeroForOne ? batch.poolKey.currency0 : batch.poolKey.currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: totalPendingInput}("");
            require(success, "ETH send failed");
        } else {
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(msg.sender, totalPendingInput);
        }

        // Refund remaining gas pool
        uint256 gasTankRefund = batch.gasTank;
        if (gasTankRefund > 0) {
            batch.gasTank = 0;
            (bool success, ) = payable(msg.sender).call{value: gasTankRefund}("");
            require(success, "Gas pool refund failed");
        }

        emit BatchOrderCancelledOptimized(dcaOrderId, msg.sender);
    }



    /// Manual sell: Cancel the take-profit order and swap accumulated output at current market price.
    /// Then cancel all pending buy orders and restart the DCA cycle.
    /// This allows users to take profits immediately instead of waiting for the limit order.
    function sellNow(uint256 dcaId) external validBatchOrder(dcaId) {
        BatchInfo storage batch = batchOrders[dcaId];
        if (batch.user != msg.sender) revert NotAuthorized();

        // Must have accumulated output to sell
        uint256 sellAmount = dcaAccumulatedOutput[dcaId];
        require(sellAmount > 0, "Nothing to sell");

        // Determine sell direction (opposite of the original DCA direction)
        bool sellZeroForOne = !batch.zeroForOne;

        // Cancel existing take-profit order first
        if (dcaTakeProfitTick[dcaId] != 0) {
            _cancelTakeProfitOrder(dcaId);
        }

        // Cancel all pending DCA buy orders
        PoolId poolId = batch.poolKey.toId();
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 tick = batchTargetTicks[dcaId][i];
            uint256 pendingAmount = pendingBatchOrders[poolId][tick][batch.zeroForOne];
            
            if (pendingAmount > 0) {
                pendingBatchOrders[poolId][tick][batch.zeroForOne] = 0;
                _removeBatchIdFromTick(poolId, tick, batch.zeroForOne, dcaId);
            }
        }

        // Perform the market sell via a direct swap
        SwapParams memory swapParams = SwapParams({
            zeroForOne: sellZeroForOne,
            amountSpecified: int256(sellAmount),
            sqrtPriceLimitX96: 0 // Market price
        });

        bytes memory data = abi.encode(batch.poolKey, swapParams);
        uint256 amountOut;
        try poolManager.unlock(data) returns (bytes memory result) {
            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            // Compute output based on direction
            amountOut = sellZeroForOne
                ? uint256(int256(-delta.amount1()))
                : uint256(int256(-delta.amount0()));
        } catch {
            revert("Manual sell swap failed");
        }

        // Reset accumulated output since we sold it all
        dcaAccumulatedOutput[dcaId] = 0;

        // Transfer proceeds to the user (in original input currency)
        Currency proceedsToken = batch.zeroForOne ? batch.poolKey.currency0 : batch.poolKey.currency1;
        if (Currency.unwrap(proceedsToken) == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: amountOut}("");
            require(success, "ETH send failed");
        } else {
            IERC20(Currency.unwrap(proceedsToken)).safeTransfer(msg.sender, amountOut);
        }

        // Restart the DCA cycle with profits
        _restartDCAWithProfits(dcaId, amountOut);

        emit DCASwapExecuted(dcaId, 1000, sellAmount, amountOut, sellZeroForOne); // 1000 == manual sell marker
    }

    function redeemProfits(uint256 dcaOrderId, uint256 inputAmountToClaimFor) external {
        // Redeem only accumulated claimable output tokens (profits) proportionally.
        if (claimableOutputTokens[dcaOrderId] == 0) revert NothingToClaim();
        if (balanceOf[msg.sender][dcaOrderId] < inputAmountToClaimFor) revert InsufficientClaimTokenBalance();
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            claimableOutputTokens[dcaOrderId],
            claimTokensSupply[dcaOrderId]
        );
        // Deduct only the profits portion and reduce claim token supply by the input amount
        claimableOutputTokens[dcaOrderId] -= outputAmount;
        claimTokensSupply[dcaOrderId] -= inputAmountToClaimFor;
        _burn(msg.sender, address(uint160(dcaOrderId)), inputAmountToClaimFor);
        _transfer(dcaOrderId, outputAmount);
        emit TokensRedeemedOptimized(dcaOrderId, msg.sender, outputAmount);
    }

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
                PoolKey memory liquidityKey, uint256 amount, bool zeroForOne, string memory batchOperation
            ) {
                if (keccak256(bytes(batchOperation)) == keccak256("ADD_LIQUIDITY"))
                    return _handleLiquidityOperation(liquidityKey, amount, zeroForOne);
            } catch {}
        }
        (PoolKey memory swapKey, SwapParams memory swapParams) =
            abi.decode(data, (PoolKey, SwapParams));
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

    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal pure override returns (bytes4)
    {
        // Remove dynamic fee requirement - use fee from createBatchOrder parameter
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal override returns (bytes4)
    {
    lastTicks[key.toId()] = tick;
    PoolId poolId = key.toId();
    allPoolIds.push(poolId);
    poolIdToKey[poolId] = key;
    emit PoolInitializationTracked(poolId, tick, block.timestamp);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender == address(this))
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        BeforeSwapDelta delta = _processLimitOrdersBeforeSwap(key, params);
        // Use the pool's actual fee instead of overriding
        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal override returns (bytes4, int128)
    {
        if (msg.sender == address(this)) return (BaseHook.afterSwap.selector, 0);
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        lastTicks[key.toId()] = currentTick;
        return (BaseHook.afterSwap.selector, 0);
    }

    /* ==========================================================
       INTERNAL HELPERS
       ========================================================== */
    function _processLimitOrdersBeforeSwap(PoolKey calldata key, SwapParams calldata params)
        internal returns (BeforeSwapDelta)
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

        uint256 swapAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
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
        uint256 gasTankAmount,
        uint32 gasTankPercent
    ) internal view {
        if (takeProfitPercent == 0 || takeProfitPercent > 5000) revert InvalidTakeProfitPercent(); // 0-50%
        if (maxSwapOrders == 0 || maxSwapOrders > 10) revert InvalidMaxSwapOrders(); // 1-10 levels
        if (priceDeviationPercent == 0 || priceDeviationPercent > 2000) revert InvalidPriceDeviation(); // 0-20%
        if (priceDeviationMultiplier < 10 || priceDeviationMultiplier > 100) revert InvalidMultiplier(); // 0.1-10.0
        if (swapOrderAmount == 0) revert InvalidAmount();
        if (swapOrderMultiplier < 10 || swapOrderMultiplier > 100) revert InvalidMultiplier(); // 0.1-10.0
    if (expirationTime <= block.timestamp) revert ExpiredDeadline();
        if (currency0 == currency1) revert SameCurrencies();
        if (gasTankAmount == 0) revert InsufficientGasTank();
        if (gasTankPercent == 0 || gasTankPercent > 1000) revert InvalidMultiplier(); // 0-10%
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
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        
        // Create only the first DCA level
        targetTicks = new int24[](1);
        targetAmounts = new uint256[](1);
        
        // Calculate first level deviation (level 1 = 1 * priceDeviationPercent)
        // priceDeviationPercent is stored as basis points (500 = 5%)
        uint256 level1DeviationBps = uint256(priceDeviationPercent); // Level 1 uses base deviation
        
        // Calculate tick deviation for first level
        int24 tickDeviation = int24(int256(
            (level1DeviationBps * uint256(int256(key.tickSpacing))) / 10000
        ));
        
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

    function _calculateNextDCALevel(
        uint256 dcaId,
        PoolKey memory key
    ) internal view returns (int24 nextTick, uint256 nextAmount) {
        BatchInfo storage batch = batchOrders[dcaId];
        uint256 nextLevel = dcaCurrentLevel[dcaId] + 1;
        
        // Don't exceed max swap orders
        if (nextLevel >= batch.maxSwapOrders) {
            return (0, 0);
        }
        
        // Get current price
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        
        // Calculate deviation for next level (linear scaling)
        // Level N gets N * priceDeviationPercent deviation
        uint256 levelDeviationBps = uint256(batch.priceDeviationPercent) * (nextLevel + 1);
        
        int24 tickDeviation = int24(int256(
            (levelDeviationBps * uint256(int256(key.tickSpacing))) / 10000
        ));
        
        // Set target tick
        if (batch.zeroForOne) {
            nextTick = currentTick - tickDeviation;
        } else {
            nextTick = currentTick + tickDeviation;
        }

        // Calculate amount for next level using exponential multiplier
        uint256 amountLevelMultiplier = _calculateExponentialMultiplier(nextLevel + 1, uint256(batch.swapOrderMultiplier));
        nextAmount = (batch.baseSwapAmount * amountLevelMultiplier) / 10;
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

    function _createPoolKey(address currency0, address currency1, uint24 fee)
        internal view returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee, // Use the fee parameter directly, no dynamic fee flag
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(this))
        });
    }

    function _createDCABatch(
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
        uint256 gasTankAmount,
        uint32 gasTankPercent
    ) internal returns (uint256 dcaId) {
        dcaId = nextBatchOrderId++;
        batchTargetTicks[dcaId] = targetTicks;
        batchTargetAmounts[dcaId] = targetAmounts;

        batchOrders[dcaId] = BatchInfo({
            user: msg.sender,
            totalAmount: uint96(totalAmount),
            poolKey: key,
            expirationTime: uint64(expirationTime),
            maxSlippageBps: slippage,
            takeProfitPercent: takeProfitPercent,
            ticksLength: uint16(targetTicks.length),
            maxSwapOrders: maxSwapOrders,
            zeroForOne: zeroForOne,
            isActive: true,
            isPerpetual: true, // DCA orders are perpetual
            priceDeviationPercent: priceDeviationPercent,
            priceDeviationMultiplier: priceDeviationMultiplier,
            baseSwapAmount: baseSwapAmount,
            swapOrderMultiplier: swapOrderMultiplier,
            gasTank: gasTankAmount * 2, // Allocate 2x gas amount initially (likely to swap again)
            gasTankPercent: gasTankPercent,
            isStalled: false
        });


        // Register pending orders
        PoolId poolId = key.toId();
        for (uint256 i = 0; i < targetTicks.length; i++) {
            pendingBatchOrders[poolId][targetTicks[i]][zeroForOne] += targetAmounts[i];
            tickToBatchIds[poolId][targetTicks[i]][zeroForOne].push(dcaId);
        }
        
        claimTokensSupply[dcaId] = totalAmount;
        _mint(msg.sender, address(uint160(dcaId)), totalAmount);
    }

    function _initiateFirstDCASwap(uint256 dcaId) internal {
        BatchInfo storage batch = batchOrders[dcaId];
        
        // Execute immediate swap at base amount
        SwapParams memory swapParams = SwapParams({
            zeroForOne: batch.zeroForOne,
            amountSpecified: int256(batch.baseSwapAmount),
            sqrtPriceLimitX96: 0 // No price limit for initial swap
        });
        
        bytes memory data = abi.encode(batch.poolKey, swapParams);
        
        try poolManager.unlock(data) returns (bytes memory result) {
            BalanceDelta delta = abi.decode(result, (BalanceDelta));
            uint256 amountOut = batch.zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
            
            // Update DCA tracking
            dcaAccumulatedInput[dcaId] = batch.baseSwapAmount;
            dcaAccumulatedOutput[dcaId] = amountOut;
            dcaCurrentLevel[dcaId] = 0; // Initial swap completed
            
            // Update claimable output tokens with swap result
            claimableOutputTokens[dcaId] += amountOut;
            
            // Create take profit order at calculated margin
            _createTakeProfitOrder(dcaId);
            
            emit DCASwapExecuted(dcaId, 0, batch.baseSwapAmount, amountOut, batch.zeroForOne);
        } catch {
            // If swap fails, just emit with 0 output
            emit DCASwapExecuted(dcaId, 0, batch.baseSwapAmount, 0, batch.zeroForOne);
        }
    }

    function _createTakeProfitOrder(uint256 dcaId) internal {
        BatchInfo storage batch = batchOrders[dcaId];
        PoolId poolId = batch.poolKey.toId();
        
        // Get current tick and calculate take profit tick
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Calculate take profit tick based on percentage
        int24 takeProfitTickOffset = int24(int256(
            (uint256(batch.takeProfitPercent) * uint256(int256(batch.poolKey.tickSpacing))) / 100
        ));
        
        int24 takeProfitTick;
        if (batch.zeroForOne) {
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
        bool takeProfitDirection = !batch.zeroForOne; // Opposite direction
        
        pendingBatchOrders[poolId][takeProfitTick][takeProfitDirection] += takeProfitAmount;
        tickToBatchIds[poolId][takeProfitTick][takeProfitDirection].push(dcaId);
        
        // Update tracking
        dcaTakeProfitTick[dcaId] = takeProfitTick;
    }

    function _cancelTakeProfitOrder(uint256 dcaId) internal {
        BatchInfo storage batch = batchOrders[dcaId];
        PoolId poolId = batch.poolKey.toId();
        int24 oldTakeProfitTick = dcaTakeProfitTick[dcaId];
        
        if (oldTakeProfitTick != 0) {
            bool takeProfitDirection = !batch.zeroForOne;
            
            // Remove from pending orders
            uint256 oldAmount = dcaAccumulatedOutput[dcaId];
            if (pendingBatchOrders[poolId][oldTakeProfitTick][takeProfitDirection] >= oldAmount) {
                pendingBatchOrders[poolId][oldTakeProfitTick][takeProfitDirection] -= oldAmount;
            }
            
            // Remove from tick tracking
            _removeBatchIdFromTick(poolId, oldTakeProfitTick, takeProfitDirection, dcaId);
            
            dcaTakeProfitTick[dcaId] = 0;
        }
    }

    /// Restart the DCA cycle after manual sell by reinvesting profits.
    /// This creates a new initial swap and updates the accumulation tracking.
    function _restartDCAWithProfits(uint256 dcaId, uint256 profitAmount) internal {
        BatchInfo storage batch = batchOrders[dcaId];
        
        // Only restart if this is a perpetual DCA order
        if (!batch.isPerpetual) return;
        
        // Update accumulated input with the profit amount
        dcaAccumulatedInput[dcaId] += profitAmount;
        
        // Reset the current level to restart progression
        dcaCurrentLevel[dcaId] = 0;
        
        // Create the first level with the profit amount
        (int24[] memory newTargetTicks, uint256[] memory newTargetAmounts,) = _calculateInitialDCALevel(
            batch.poolKey,
            batch.zeroForOne,
            batch.priceDeviationPercent,
            batch.priceDeviationMultiplier,
            profitAmount, // Use profit as new base amount
            batch.swapOrderMultiplier
        );
        
        // Add the new level to pending orders
        if (newTargetTicks.length > 0) {
            PoolId poolId = batch.poolKey.toId();
            pendingBatchOrders[poolId][newTargetTicks[0]][batch.zeroForOne] += newTargetAmounts[0];
            tickToBatchIds[poolId][newTargetTicks[0]][batch.zeroForOne].push(dcaId);
            
            // Update batch target arrays
            batchTargetTicks[dcaId].push(newTargetTicks[0]);
            batchTargetAmounts[dcaId].push(newTargetAmounts[0]);
            batch.ticksLength++;
        }
        
        // Create new take profit order based on updated accumulation
        _createTakeProfitOrder(dcaId);
        
        emit DCARestarted(dcaId, profitAmount);
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
        
        // Clean up empty tick mapping
        if (batchIds.length == 0 && pendingBatchOrders[poolId][tick][zeroForOne] == 0) {
            delete tickToBatchIds[poolId][tick][zeroForOne];
        }
    }

    function _ensurePoolInitialized(PoolKey memory key) internal view {
        (uint160 currentPrice, , , ) = StateLibrary.getSlot0(poolManager, key.toId());
        if (currentPrice > 0) return;
        revert();
    }

    function _handleTokenDeposit(PoolKey memory key, bool zeroForOne, uint256 totalAmount, uint256 gasTankAmount) internal {
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        if (sellToken == address(0)) {
            // For ETH swaps, require total amount + 2x gas pool amount
            uint256 requiredETH = totalAmount + (gasTankAmount * 2);
            if (msg.value < requiredETH) revert InsufficientETHForOrderPlusGas();
            if (msg.value > requiredETH) {
                (bool success, ) = payable(msg.sender).call{value: msg.value - requiredETH}("");
                require(success, "ETH refund failed");
            }
        } else {
            // For token swaps, require ETH for 2x gas pool + token amount
            uint256 requiredGas = gasTankAmount * 2;
            if (msg.value < requiredGas) revert InsufficientGasTank();
            if (msg.value > requiredGas) {
                (bool success, ) = payable(msg.sender).call{value: msg.value - requiredGas}("");
                require(success, "ETH refund failed");
            }
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);
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
        return 60;
    }

    function _decodeLiquidityOperation(bytes calldata data)
        external pure returns (PoolKey memory key, uint256 amount, bool zeroForOne, string memory operation)
    {
        return abi.decode(data, (PoolKey, uint256, bool, string));
    }

    function _handleLiquidityOperation(PoolKey memory key, uint256 amount, bool)
        internal returns (bytes memory)
    {
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
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
        (BalanceDelta callerDelta, ) = poolManager.modifyLiquidity(key, params, "");
        return abi.encode(callerDelta);
    }

    function _handleGeneralLiquidityOperation(PoolKey memory key, ModifyLiquidityParams memory params)
        internal returns (bytes memory)
    {
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
        if (delta.amount0() > 0) {
            if (Currency.unwrap(key.currency0) == address(0)) {
                poolManager.settle{value: uint256(int256(delta.amount0()))}();
            } else {
                Currency.wrap(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint256(int256(delta.amount0())));
                poolManager.settle();
            }
        }
        if (delta.amount1() > 0) {
            Currency.wrap(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint256(int256(delta.amount1())));
            poolManager.settle();
        }
        return abi.encode(delta);
    }

    /* ==========================================================
       LIMIT ORDER HELPERS
       ========================================================== */
    function _getTargetTick(uint160 sqrtPriceLimitX96, bool zeroForOne) internal pure returns (int24) {
        if (sqrtPriceLimitX96 == 0)
            return zeroForOne ? TickMath.MIN_TICK : TickMath.MAX_TICK;
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
                uint256 amount = pendingBatchOrders[poolId][tick][false];
                if (amount > 0) { totalAmount += amount; hasOrders = true; }
            }
        } else {
            for (int24 tick = currentTick; tick <= targetTick; tick += tickSpacing) {
                uint256 amount = pendingBatchOrders[poolId][tick][true];
                if (amount > 0) { totalAmount += amount; hasOrders = true; }
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
        uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
        uint256 remainingToExecute = amountToExecute;
        
        for (uint256 i = 0; i < batchIds.length && remainingToExecute > 0; i++) {
            uint256 batchId = batchIds[i];
            BatchInfo storage batch = batchOrders[batchId];
            if (!batch.isActive) continue;
            
            // Check if DCA order has sufficient gas pool for execution
            if (batch.isPerpetual && !batch.isStalled) {
                uint256 estimatedGasCost = 50000; // Approximate gas for DCA execution
                if (batch.gasTank < estimatedGasCost) {
                    // Try to refill gas tank from claimable profits before stalling
                    if (_tryRefillGasTankFromProfits(batchId, estimatedGasCost, zeroForOne)) {
                        // Successfully refilled, continue execution
                    } else {
                        // No profits available, mark as stalled
                        batch.isStalled = true;
                        emit DCAStalled(batchId, batch.gasTank);
                        continue; // Skip execution for stalled orders
                    }
                }
            }
            
            // Check if this is a take profit order execution
            if (dcaTakeProfitTick[batchId] == tick && zeroForOne == (!batch.zeroForOne)) {
                // Take profit hit! Handle restart
                _handleTakeProfitHit(batchId, remainingToExecute);
                continue;
            }
            
            for (uint256 j = 0; j < batch.ticksLength; j++) {
                if (batchTargetTicks[batchId][j] == tick) {
                    uint256 batchAmountAtTick = batchTargetAmounts[batchId][j];
                    uint256 executeFromBatch = _min(batchAmountAtTick, remainingToExecute);
                    claimableOutputTokens[batchId] += executeFromBatch;
                    remainingToExecute -= executeFromBatch;
                    
                    // Deduct gas cost from gas pool before DCA execution
                    if (batch.isPerpetual && executeFromBatch > 0) {
                        uint256 gasCost = 50000; // Approximate gas cost
                        batch.gasTank -= gasCost;
                        _handleDCABuyExecution(batchId, executeFromBatch);
                    }
                    break;
                }
            }
        }
        if (pendingBatchOrders[poolId][tick][zeroForOne] == 0)
            delete tickToBatchIds[poolId][tick][zeroForOne];
    }

    function _createBeforeSwapDelta(bool zeroForOne, uint256 amount)
        internal pure returns (BeforeSwapDelta)
    {
        if (zeroForOne)
            return toBeforeSwapDelta(int128(int256(amount)), -int128(int256(amount)));
        else
            return toBeforeSwapDelta(-int128(int256(amount)), int128(int256(amount)));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _handleDCABuyExecution(uint256 dcaId, uint256 buyAmount) internal {
        BatchInfo storage batch = batchOrders[dcaId];
        
        // Update accumulated position
        dcaAccumulatedInput[dcaId] += buyAmount;
        // Note: accumulated output will be updated when the actual buy swap happens
        
        // Only contribute to gas tank if it's running low (less than 2x estimated gas cost)
        uint256 estimatedGasCost = 50000; // Should match the gas cost used in _executeLimitOrdersAtTick
        uint256 gasThreshold = estimatedGasCost * 2; // Refill when below 2x gas cost
        
        if (batch.gasTank < gasThreshold) {
            uint256 gasContribution = (buyAmount * batch.gasTankPercent) / 10000;
            batch.gasTank += gasContribution;
            emit GasTankContribution(dcaId, gasContribution);
        }
        
        // Increment current level
        dcaCurrentLevel[dcaId]++;
        
        // Create next DCA level if we haven't reached max
        (int24 nextTick, uint256 nextAmount) = _calculateNextDCALevel(dcaId, batch.poolKey);
        if (nextTick != 0 && nextAmount > 0) {
            PoolId poolId = batch.poolKey.toId();
            
            // Add next level to pending orders
            pendingBatchOrders[poolId][nextTick][batch.zeroForOne] += nextAmount;
            tickToBatchIds[poolId][nextTick][batch.zeroForOne].push(dcaId);
            
            // Update batch target arrays to include new level
            batchTargetTicks[dcaId].push(nextTick);
            batchTargetAmounts[dcaId].push(nextAmount);
            batch.ticksLength++;
        }
        
        // Recreate take profit order with updated accumulated position
        _createTakeProfitOrder(dcaId);
        
        emit DCASwapExecuted(dcaId, dcaCurrentLevel[dcaId], buyAmount, 0, batch.zeroForOne);
    }

    /**
     * @dev Attempts to refill gas tank using claimable profits when tank is insufficient
     * @param dcaId The DCA order ID
     * @param requiredGas Minimum gas amount needed
     * @param isForBuyOrder True if this refill is for a buy order (allocate 2x), false for sell order (exact amount)
     * @return success True if gas tank was successfully refilled
     */
    function _tryRefillGasTankFromProfits(uint256 dcaId, uint256 requiredGas, bool isForBuyOrder) internal returns (bool success) {
        BatchInfo storage batch = batchOrders[dcaId];
        uint256 availableProfits = claimableOutputTokens[dcaId];
        
        if (availableProfits == 0) {
            return false; // No profits available
        }
        
        // Calculate how much gas we need based on order type
        uint256 gasNeeded;
        if (isForBuyOrder) {
            // For buy orders, allocate 2x the amount (likely to swap again)
            gasNeeded = requiredGas * 2;
        } else {
            // For sell orders, allocate exact amount needed
            gasNeeded = requiredGas;
        }
        
        // For simplicity, assume 1:1 ratio between profits and ETH value
        // In production, this would need proper price oracle or conversion mechanism
        uint256 profitsValueInETH = availableProfits;
        
        if (profitsValueInETH >= gasNeeded) {
            // Use profits to refill gas tank
            claimableOutputTokens[dcaId] -= gasNeeded;
            batch.gasTank += gasNeeded;
            
            emit GasTankContribution(dcaId, gasNeeded);
            return true;
        } else if (profitsValueInETH > 0) {
            // Use all available profits if less than needed but still something
            claimableOutputTokens[dcaId] = 0;
            batch.gasTank += profitsValueInETH;
            
            emit GasTankContribution(dcaId, profitsValueInETH);
            // Check if partial refill is sufficient
            return batch.gasTank >= requiredGas;
        }
        
        return false; // Insufficient profits to refill
    }

    function _handleTakeProfitHit(uint256 dcaId, uint256 takeProfitAmount) internal {
        BatchInfo storage batch = batchOrders[dcaId];
        PoolId poolId = batch.poolKey.toId();
        
        // Cancel all pending DCA buy orders
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 tick = batchTargetTicks[dcaId][i];
            uint256 pendingAmount = pendingBatchOrders[poolId][tick][batch.zeroForOne];
            
            if (pendingAmount > 0) {
                pendingBatchOrders[poolId][tick][batch.zeroForOne] = 0;
                _removeBatchIdFromTick(poolId, tick, batch.zeroForOne, dcaId);
            }
        }
        
        // Clear take profit order
        _cancelTakeProfitOrder(dcaId);
        
        // Mark as completed for now - restart logic can be added later
        batch.isActive = false;
        
        // Update claimable tokens with take profit execution
        claimableOutputTokens[dcaId] += takeProfitAmount;
        
        emit DCASwapExecuted(dcaId, 999, takeProfitAmount, 0, !batch.zeroForOne); // 999 indicates take profit
    }

    function _calculateEstimatedGasFee() internal view returns (uint256) {
        uint256 estimatedCost = ESTIMATED_EXECUTION_GAS * tx.gasprice;
        estimatedCost = (estimatedCost * GAS_PRICE_BUFFER_MULTIPLIER) / 100;
        if (estimatedCost > MAX_GAS_FEE_ETH) estimatedCost = MAX_GAS_FEE_ETH;
        return estimatedCost;
    }

    /* ==========================================================
       VIEW FUNCTIONS
       ========================================================== */

    // function getGasRefundInfo(uint256 batchId) external view returns (uint256 preCollected, uint256 actualUsed, uint256 refundable, bool processed) {
    //     // Deprecated: Old gas refund system removed
    //     preCollected = 0;
    //     actualUsed = 0;
    //     processed = false;
    //     refundable = 0;
    // }

    function getPoolCurrentTick(PoolId poolId) external view returns (int24) {
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        return currentTick;
    }

    function getAllPools() external view returns (PoolId[] memory poolIds, PoolKey[] memory poolKeys, int24[] memory ticks) {
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

    function getDCAInfo(uint256 dcaId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256 claimableAmount, bool isActive, bool isFullyExecuted,
        uint256 expirationTime, bool zeroForOne, uint256 totalBatches, uint24 currentFee
    ) {
        BatchInfo storage batch = batchOrders[dcaId];
        if (batch.user == address(0)) revert InvalidBatch();
        uint256 execAmount = uint256(batch.totalAmount) - claimTokensSupply[dcaId];
        return (
            batch.user, Currency.unwrap(batch.poolKey.currency0), Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount), execAmount, claimableOutputTokens[dcaId],
            batch.isActive, claimTokensSupply[dcaId] == 0, uint256(batch.expirationTime),
            batch.zeroForOne, nextBatchOrderId - 1, batch.poolKey.fee
        );
    }


    function getDCAInfoExtended(uint256 dcaId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256 claimableAmount, bool isActive, bool isFullyExecuted,
        uint256 expirationTime, bool zeroForOne, uint256 totalBatches, uint24 currentFee,
        uint256 gasTankAmount, uint256 gasTankPercent, bool isStalled
    ) {
        BatchInfo storage batch = batchOrders[dcaId];
        if (batch.user == address(0)) revert InvalidBatch();
        uint256 execAmount = uint256(batch.totalAmount) - claimTokensSupply[dcaId];
        return (
            batch.user, Currency.unwrap(batch.poolKey.currency0), Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount), execAmount, claimableOutputTokens[dcaId], batch.isActive,
            claimTokensSupply[dcaId] == 0, uint256(batch.expirationTime), batch.zeroForOne,
            nextBatchOrderId - 1, batch.poolKey.fee, batch.gasTank, batch.gasTankPercent, batch.isStalled
        );
    }

    function getDCAOrder(uint256 dcaId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256[] memory targetPrices, uint256[] memory targetAmounts,
        bool isActive, bool isFullyExecuted
    ) {
        BatchInfo storage batch = batchOrders[dcaId];
        int24[] memory targetTicks = batchTargetTicks[dcaId];
        uint256[] memory amounts = batchTargetAmounts[dcaId];
        uint256[] memory prices = new uint256[](targetTicks.length);
        for (uint256 i = 0; i < targetTicks.length; i++) {
            prices[i] = TickMath.getSqrtPriceAtTick(targetTicks[i]);
        }
        return (
            batch.user, Currency.unwrap(batch.poolKey.currency0), Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount), uint256(batch.totalAmount) - claimTokensSupply[dcaId],
            prices, amounts, batch.isActive, claimTokensSupply[dcaId] == 0
        );
    }

    /* ==========================================================
       FALLBACKS
       ========================================================== */
    receive() external payable {}
    fallback() external payable {}
}