// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  ----------  imports (unchanged)  ----------  */
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILimitOrderBatchV3} from "./interfaces/ILimitOrderBatchV3.sol";
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


contract LimitOrderBatch is ILimitOrderBatchV3, ERC6909Base, BaseHook, IUnlockCallback {
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

    mapping(uint256 => uint256) public preCollectedGasFees;
    mapping(uint256 => uint256) public actualGasCosts;
    mapping(uint256 => bool) public gasRefundProcessed;

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
        // DCA-specific parameters
        uint32 priceDeviationPercent; // NEW
        uint32 priceDeviationMultiplier; // NEW
        uint256 baseSwapAmount; // NEW - base swap amount
        uint32 swapOrderMultiplier; // NEW
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
    error NothingToCancel();
    error InsufficientClaimTokenBalance();
    error InsufficientETHForOrderPlusGas();
    error InsufficientETHForGasFee();
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

    /* ==========================================================
       EVENTS – DCA system events
       ========================================================== */
    event DCAOrderCreated(uint256 indexed dcaId, address indexed user, address currency0, address currency1, 
                         uint256 totalAmount, uint32 takeProfitPercent, uint8 maxSwapOrders);
    event DCASwapExecuted(uint256 indexed dcaId, uint256 level, uint256 amountIn, uint256 amountOut, bool direction);
    event BatchOrderCancelledOptimized(uint256 indexed batchId, address indexed user);
    event TokensRedeemedOptimized(uint256 indexed batchId, address indexed user, uint256 amount);
    event GasFeePreCollected(uint256 indexed batchId, uint256 estimatedGasFee);
    event GasFeeRefunded(uint256 indexed batchId, address indexed user, uint256 refundAmount);
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);

    modifier validBatchOrder(uint256 batchId) {
        if (!(batchId > 0 && batchId < nextBatchOrderId)) revert InvalidBatchId();
        if (!batchOrders[batchId].isActive) revert OrderNotActive();
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
        ILimitOrderBatchV3.PoolParams calldata pool,
        ILimitOrderBatchV3.DCAParams calldata dca,
        uint32 slippage,
        uint256 expirationTime
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
            expirationTime
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
    uint256 expirationTime
    ) internal returns (uint256 dcaId) {
    _validateDCAInputs(takeProfitPercent, maxSwapOrders, priceDeviationPercent, 
              priceDeviationMultiplier, swapOrderAmount, swapOrderMultiplier, 
              expirationTime, currency0, currency1);
        
        PoolKey memory key = _createPoolKey(currency0, currency1, fee);
        _ensurePoolInitialized(key);
        
        // Calculate DCA levels and amounts
        (int24[] memory targetTicks, uint256[] memory targetAmounts, uint256 totalAmount) = 
            _calculateDCALevels(key, zeroForOne, maxSwapOrders, priceDeviationPercent, 
                               priceDeviationMultiplier, swapOrderAmount, swapOrderMultiplier);

    dcaId = _createDCABatch(key, targetTicks, targetAmounts, totalAmount,
                   zeroForOne, slippage, expirationTime, takeProfitPercent, maxSwapOrders,
                               priceDeviationPercent, priceDeviationMultiplier, 
                               swapOrderAmount, swapOrderMultiplier);

        _handleTokenDeposit(key, zeroForOne, totalAmount);

        // TODO: Start initial buy swap immediately at swapOrderAmount
        _initiateFirstDCASwap(dcaId);

        emit DCAOrderCreated(dcaId, msg.sender, currency0, currency1, totalAmount, 
                           takeProfitPercent, maxSwapOrders);
        return dcaId;
    }
         
    /* ==========================================================
       CANCEL / REDEEM – identical to previous file
       ========================================================== */
    function cancelDCAOrder(uint256 dcaOrderId) external validBatchOrder(dcaOrderId) {
        /*  identical implementation  */
        BatchInfo storage batch = batchOrders[dcaOrderId];
        if (batch.user != msg.sender) revert NotAuthorized();
        uint256 userClaimBalance = balanceOf[msg.sender][dcaOrderId];
        if (userClaimBalance == 0) revert NoTokensToCancel();
        PoolId poolId = batch.poolKey.toId();
        uint256 totalPendingAmount;
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            totalPendingAmount += pendingBatchOrders[poolId][batchTargetTicks[dcaOrderId][i]][batch.zeroForOne];
        }
        if (totalPendingAmount == 0) revert BatchAlreadyExecutedUseRedeem();
        uint256 cancellableAmount = userClaimBalance * totalPendingAmount / uint256(batch.totalAmount);
        if (cancellableAmount == 0) revert NothingToCancel();
        _burn(msg.sender, address(uint160(dcaOrderId)), cancellableAmount);
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            int24 targetTick = batchTargetTicks[dcaOrderId][i];
            uint256 levelPending = pendingBatchOrders[poolId][targetTick][batch.zeroForOne];
            if (levelPending > 0) {
                uint256 levelCancellation = cancellableAmount * levelPending / totalPendingAmount;
                pendingBatchOrders[poolId][targetTick][batch.zeroForOne] -= levelCancellation;
            }
        }
        claimTokensSupply[dcaOrderId] -= cancellableAmount;
        if (totalPendingAmount == cancellableAmount) batch.isActive = false;
        Currency inputCurrency = batch.zeroForOne ? batch.poolKey.currency0 : batch.poolKey.currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: cancellableAmount}("");
            require(success, "ETH send failed");
        } else {
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(msg.sender, cancellableAmount);
        }
        if (totalPendingAmount == cancellableAmount && !gasRefundProcessed[dcaOrderId]) {
            uint256 gasRefund = preCollectedGasFees[dcaOrderId];
            if (gasRefund > 0) {
                gasRefundProcessed[dcaOrderId] = true;
                (bool success, ) = payable(msg.sender).call{value: gasRefund}("");
                require(success, "ETH refund failed");
                emit GasFeeRefunded(dcaOrderId, msg.sender, gasRefund);
            }
        }
        emit BatchOrderCancelledOptimized(dcaOrderId, msg.sender);
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
       CALLBACK + HOOKS – identical to previous file
       ========================================================== */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // same decode logic as before
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
       INTERNAL HELPERS – identical to previous file
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
        address currency1
    ) internal view {
        if (takeProfitPercent == 0 || takeProfitPercent > 5000) revert InvalidTakeProfitPercent(); // 0-50%
        if (maxSwapOrders == 0 || maxSwapOrders > 10) revert InvalidMaxSwapOrders(); // 1-10 levels
        if (priceDeviationPercent == 0 || priceDeviationPercent > 2000) revert InvalidPriceDeviation(); // 0-20%
        if (priceDeviationMultiplier < 10 || priceDeviationMultiplier > 100) revert InvalidMultiplier(); // 0.1-10.0
        if (swapOrderAmount == 0) revert InvalidAmount();
        if (swapOrderMultiplier < 10 || swapOrderMultiplier > 100) revert InvalidMultiplier(); // 0.1-10.0
    if (expirationTime <= block.timestamp) revert ExpiredDeadline();
        if (currency0 == currency1) revert SameCurrencies();
    }

    function _calculateDCALevels(
        PoolKey memory key,
        bool zeroForOne,
        uint8 maxSwapOrders,
        uint32 priceDeviationPercent,
        uint32 priceDeviationMultiplier,
        uint256 baseSwapAmount,
        uint32 swapOrderMultiplier
    ) internal view returns (int24[] memory targetTicks, uint256[] memory targetAmounts, uint256 totalAmount) {
        // Get current price
        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        
        targetTicks = new int24[](maxSwapOrders);
        targetAmounts = new uint256[](maxSwapOrders);
        totalAmount = 0;

        // Convert multipliers from basis points to actual multipliers
        uint256 deviationMultiplier = uint256(priceDeviationMultiplier); // 10-100 (0.1-10.0)
        uint256 amountMultiplier = uint256(swapOrderMultiplier); // 10-100 (0.1-10.0)

        for (uint8 i = 0; i < maxSwapOrders; i++) {
            // Calculate price deviation with logarithmic spacing
            // Higher levels get exponentially larger spacing
            uint256 levelMultiplier = _calculateLogarithmicMultiplier(i + 1, deviationMultiplier);
            
            // Calculate tick deviation
            int24 tickDeviation = int24(int256(
                (uint256(priceDeviationPercent) * levelMultiplier * uint256(int256(key.tickSpacing))) / (10000 * 10)
            ));
            
            // Set target tick based on direction
            if (zeroForOne) {
                // Selling: set buy levels below current price
                targetTicks[i] = currentTick - tickDeviation;
            } else {
                // Buying: set sell levels above current price  
                targetTicks[i] = currentTick + tickDeviation;
            }

            // Calculate amount with logarithmic multiplier effect
            // Higher levels get exponentially larger amounts
            uint256 amountLevelMultiplier = _calculateLogarithmicMultiplier(i + 1, amountMultiplier);
            targetAmounts[i] = (baseSwapAmount * amountLevelMultiplier) / 10;
            
            totalAmount += targetAmounts[i];
        }
    }

    function _calculateLogarithmicMultiplier(uint256 level, uint256 baseMultiplier) internal pure returns (uint256) {
        // Logarithmic scaling: effect increases at higher levels
        // Formula: 10 + (baseMultiplier - 10) * (1 + log2(level))
        // This ensures multiplier is always >= 1.0 and increases logarithmically
        
        uint256 logLevel = 0;
        uint256 tempLevel = level;
        
        // Simple log2 calculation
        while (tempLevel > 1) {
            logLevel++;
            tempLevel >>= 1;
        }
        
        // Calculate final multiplier
        uint256 multiplier = 10 + ((baseMultiplier - 10) * (10 + logLevel * 5)) / 10;
        return multiplier;
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
        uint32 swapOrderMultiplier
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
            swapOrderMultiplier: swapOrderMultiplier
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
        // TODO: Implement immediate first swap at base swap amount
        // This should execute the first DCA level immediately
        BatchInfo storage batch = batchOrders[dcaId];
        
        // For now, just emit an event - actual swap implementation would go here
        emit DCASwapExecuted(dcaId, 0, batch.baseSwapAmount, 0, batch.zeroForOne);
    }

    // Removed unused helpers: _pricesToTicks, _sumAmounts

    function _ensurePoolInitialized(PoolKey memory key) internal view {
        (uint160 currentPrice, , , ) = StateLibrary.getSlot0(poolManager, key.toId());
        if (currentPrice > 0) return;
        revert();
    }

    function _handleTokenDeposit(PoolKey memory key, bool zeroForOne, uint256 totalAmount) internal {
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        uint256 estimatedGasFee = _calculateEstimatedGasFee();
        uint256 batchId = nextBatchOrderId - 1;
        preCollectedGasFees[batchId] = estimatedGasFee;

        if (sellToken == address(0)) {
            if (msg.value < totalAmount + estimatedGasFee) revert InsufficientETHForOrderPlusGas();
            if (msg.value > totalAmount + estimatedGasFee) {
                (bool success, ) = payable(msg.sender).call{value: msg.value - totalAmount - estimatedGasFee}("");
                require(success, "ETH refund failed");
            }
        } else {
            if (msg.value < estimatedGasFee) revert InsufficientETHForGasFee();
            if (msg.value > estimatedGasFee) {
                (bool success, ) = payable(msg.sender).call{value: msg.value - estimatedGasFee}("");
                require(success, "ETH refund failed");
            }
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);
        }
        emit GasFeePreCollected(batchId, estimatedGasFee);
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
       LIMIT ORDER HELPERS – unchanged
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
            for (uint256 j = 0; j < batch.ticksLength; j++) {
                if (batchTargetTicks[batchId][j] == tick) {
                    uint256 batchAmountAtTick = batchTargetAmounts[batchId][j];
                    uint256 executeFromBatch = _min(batchAmountAtTick, remainingToExecute);
                    claimableOutputTokens[batchId] += executeFromBatch;
                    remainingToExecute -= executeFromBatch;
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

    function _calculateEstimatedGasFee() internal view returns (uint256) {
        uint256 estimatedCost = ESTIMATED_EXECUTION_GAS * tx.gasprice;
        estimatedCost = (estimatedCost * GAS_PRICE_BUFFER_MULTIPLIER) / 100;
        if (estimatedCost > MAX_GAS_FEE_ETH) estimatedCost = MAX_GAS_FEE_ETH;
        return estimatedCost;
    }

    /* ==========================================================
       VIEW FUNCTIONS – unchanged
       ========================================================== */
    function getGasRefundInfo(uint256 batchId) external view returns (uint256 preCollected, uint256 actualUsed, uint256 refundable, bool processed) {
        preCollected = preCollectedGasFees[batchId];
        actualUsed = actualGasCosts[batchId];
        processed = gasRefundProcessed[batchId];
        refundable = (preCollected > actualUsed && !processed) ? preCollected - actualUsed : 0;
    }

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
        uint256 preCollectedGasFee, uint256 actualGasCost, uint256 gasRefundable
    ) {
        BatchInfo storage batch = batchOrders[dcaId];
        if (batch.user == address(0)) revert InvalidBatch();
        uint256 execAmount = uint256(batch.totalAmount) - claimTokensSupply[dcaId];
        uint256 refundable = (preCollectedGasFees[dcaId] > actualGasCosts[dcaId] && !gasRefundProcessed[dcaId])
            ? preCollectedGasFees[dcaId] - actualGasCosts[dcaId]
            : 0;
        return (
            batch.user, Currency.unwrap(batch.poolKey.currency0), Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount), execAmount, claimableOutputTokens[dcaId], batch.isActive,
            claimTokensSupply[dcaId] == 0, uint256(batch.expirationTime), batch.zeroForOne,
            nextBatchOrderId - 1, batch.poolKey.fee, preCollectedGasFees[dcaId], actualGasCosts[dcaId], refundable
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