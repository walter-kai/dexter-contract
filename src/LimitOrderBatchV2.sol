// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*  ----------  imports (unchanged)  ----------  */
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILimitOrderBatchV2} from "./interfaces/ILimitOrderBatchV2.sol";
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


contract LimitOrderBatch is ILimitOrderBatchV2, ERC6909Base, BaseHook, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;
    using LPFeeLibrary for uint24;

    /* ==========================================================
       STORAGE – identical to previous file, only flipEnabled added
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
        uint32 bestPriceTimeout;
        uint16 ticksLength;
        bool zeroForOne;
        bool isActive;
        bool flipEnabled; // NEW – 1 bit
    }

    mapping(uint256 => int24[]) public batchTargetTicks;
    mapping(uint256 => uint256[]) public batchTargetAmounts;
    mapping(uint256 => BatchInfo) public batchOrders;
    uint256 public nextBatchOrderId = 1;

    mapping(PoolId => bool) public poolInitialized;
    PoolId[] public allPoolIds;
    mapping(PoolId => PoolKey) public poolIdToKey;
    mapping(PoolId => uint256) public poolIndex;

    address public immutable FEE_RECIPIENT;
    address public Executor;

    /* ==========================================================
       CONSTANTS – unchanged
       ========================================================== */
    uint24 public constant BASE_FEE = 3000;
    uint256 public constant BASE_PROTOCOL_FEE_BPS = 35;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant ESTIMATED_EXECUTION_GAS = 150000;
    uint256 public constant GAS_PRICE_BUFFER_MULTIPLIER = 120;
    uint256 public constant MAX_GAS_FEE_ETH = 0.01 ether;

    /* ==========================================================
       ERRORS – unchanged list + one new
       ========================================================== */
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
    error NothingToFlip(); // NEW

    /* ==========================================================
       EVENTS – unchanged + flip event
       ========================================================== */
    event BatchOrderCreatedOptimized(uint256 indexed batchId, address indexed user, uint256 totalAmount);
    event BatchOrderCancelledOptimized(uint256 indexed batchId, address indexed user);
    event TokensRedeemedOptimized(uint256 indexed batchId, address indexed user, uint256 amount);
    event GasFeePreCollected(uint256 indexed batchId, uint256 estimatedGasFee);
    event GasFeeRefunded(uint256 indexed batchId, address indexed user, uint256 refundAmount);
    event LiquidityAdded(PoolId indexed poolId, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper);
    event LiquidityAdditionFailed(PoolId indexed poolId, uint256 amount, string reason);
    event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp);
    event BatchFlipped(uint256 indexed batchId, uint256 newTotal, bool newZeroForOne); // NEW

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
        Executor = _executor;
        FEE_RECIPIENT = _feeRecipient;
    }

    /* ==========================================================
       CREATE – signature extended with flipEnabled
       ========================================================== */
    function createBatchOrder(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] calldata targetPrices,
        uint256[] calldata targetAmounts,
        uint32 slippage,
        uint256 deadline,
        bool flipEnabled // NEW
    ) external payable virtual returns (uint256 batchId) {
        return _createBatchOrderInternal(
            currency0, currency1, fee, zeroForOne,
            targetPrices, targetAmounts, slippage, deadline, flipEnabled
        );
    }

    function _createBatchOrderInternal(
        address currency0,
        address currency1,
        uint24 fee,
        bool zeroForOne,
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint32 slippage,
        uint256 deadline,
        bool flipEnabled // NEW
    ) internal returns (uint256 batchId) {
        _validateOrderInputs(targetPrices, targetAmounts, deadline, currency0, currency1);
        PoolKey memory key = _createPoolKey(currency0, currency1, fee);
        _ensurePoolInitialized(key);
        int24[] memory targetTicks = _pricesToTicks(targetPrices);
        uint256 totalAmount = _sumAmounts(targetAmounts);

        batchId = _createBatch(key, targetTicks, targetAmounts, totalAmount,
                               zeroForOne, slippage, deadline, flipEnabled); // CHANGED

        _handleTokenDeposit(key, zeroForOne, totalAmount);

        emit BatchOrderCreated(batchId, msg.sender, currency0, currency1,
                               totalAmount, targetPrices, targetAmounts);
        emit BatchOrderCreatedOptimized(batchId, msg.sender, totalAmount);
        return batchId;
    }
    
    /* ==========================================================
       CANCEL / REDEEM – identical to previous file
       ========================================================== */
    function cancelBatchOrder(uint256 batchOrderId) external validBatchOrder(batchOrderId) {
        /*  identical implementation  */
        BatchInfo storage batch = batchOrders[batchOrderId];
        if (batch.user != msg.sender) revert NotAuthorized();
        uint256 userClaimBalance = balanceOf[msg.sender][batchOrderId];
        if (userClaimBalance == 0) revert NoTokensToCancel();
        PoolId poolId = batch.poolKey.toId();
        uint256 totalPendingAmount;
        for (uint256 i = 0; i < batch.ticksLength; i++) {
            totalPendingAmount += pendingBatchOrders[poolId][batchTargetTicks[batchOrderId][i]][batch.zeroForOne];
        }
        if (totalPendingAmount == 0) revert BatchAlreadyExecutedUseRedeem();
        uint256 cancellableAmount = userClaimBalance * totalPendingAmount / uint256(batch.totalAmount);
        if (cancellableAmount == 0) revert NothingToCancel();
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
        Currency inputCurrency = batch.zeroForOne ? batch.poolKey.currency0 : batch.poolKey.currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: cancellableAmount}("");
            require(success, "ETH send failed");
        } else {
            IERC20(Currency.unwrap(inputCurrency)).safeTransfer(msg.sender, cancellableAmount);
        }
        if (totalPendingAmount == cancellableAmount && !gasRefundProcessed[batchOrderId]) {
            uint256 gasRefund = preCollectedGasFees[batchOrderId];
            if (gasRefund > 0) {
                gasRefundProcessed[batchOrderId] = true;
                (bool success, ) = payable(msg.sender).call{value: gasRefund}("");
                require(success, "ETH refund failed");
                emit GasFeeRefunded(batchOrderId, msg.sender, gasRefund);
            }
        }
        emit BatchOrderCancelledOptimized(batchOrderId, msg.sender);
    }

    function redeemBatchOrder(uint256 batchOrderId, uint256 inputAmountToClaimFor) external {
        if (claimableOutputTokens[batchOrderId] == 0) revert NothingToClaim();
        if (balanceOf[msg.sender][batchOrderId] < inputAmountToClaimFor) revert InsufficientClaimTokenBalance();
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            claimableOutputTokens[batchOrderId],
            claimTokensSupply[batchOrderId]
        );
        claimableOutputTokens[batchOrderId] -= outputAmount;
        claimTokensSupply[batchOrderId] -= inputAmountToClaimFor;
        _burn(msg.sender, address(uint160(batchOrderId)), inputAmountToClaimFor);
        _transfer(batchOrderId, outputAmount);
        emit TokensRedeemedOptimized(batchOrderId, msg.sender, outputAmount);
    }

    /* ==========================================================
       EXECUTE – identical logic until the “fully executed” check
       ========================================================== */
    function executeBatchLevel(uint256 batchId, uint256 levelIndex) external returns (bool isFullyExecuted) {
        BatchInfo storage batch = batchOrders[batchId];
        if (!(batch.isActive && msg.sender == Executor && levelIndex < batch.ticksLength))
            revert InvalidExecution();

        PoolId poolId = batch.poolKey.toId();
        int24 targetTick = batchTargetTicks[batchId][levelIndex];
        uint256 pendingAmount = pendingBatchOrders[poolId][targetTick][batch.zeroForOne];
        if (pendingAmount == 0) revert NoPendingOrders();

        uint256 amountToExecute = batchTargetAmounts[batchId][levelIndex];
        if (pendingAmount < amountToExecute) amountToExecute = pendingAmount;

        SwapParams memory params = SwapParams({
            zeroForOne: batch.zeroForOne,
            amountSpecified: -int256(amountToExecute),
            sqrtPriceLimitX96: batch.zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory result = poolManager.unlock(abi.encode(batch.poolKey, params));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        uint256 outputAmount = batch.zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));

        claimableOutputTokens[batchId] += outputAmount;
        pendingBatchOrders[poolId][targetTick][batch.zeroForOne] -= amountToExecute;

        if (pendingBatchOrders[poolId][targetTick][batch.zeroForOne] == 0)
            _removeBatchIdFromTick(poolId, targetTick, batch.zeroForOne, batchId);

        // ----------  fully executed check  ----------
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

            // NEW – auto-flip if requested
            if (batch.flipEnabled) _flipBatch(batchId);
        }
        return isFullyExecuted;
    }

    /* ==========================================================
       FLIP BATCH – new helper
       ========================================================== */
    function _flipBatch(uint256 batchId) internal {
        BatchInfo storage b = batchOrders[batchId];

        uint256 newTotal = claimableOutputTokens[batchId];
        if (newTotal == 0) revert NothingToFlip();

        // 1. flip direction
        b.zeroForOne = !b.zeroForOne;

        // 2. recycle output → new input supply
        claimTokensSupply[batchId] = newTotal;
        claimableOutputTokens[batchId] = 0;

        // 3. re-register same ticks, new direction, proportional amounts
        PoolId poolId = b.poolKey.toId();
        uint256 oldTotal = uint256(b.totalAmount);
        b.totalAmount = uint96(newTotal);

        for (uint256 i = 0; i < b.ticksLength; ++i) {
            int24 tick = batchTargetTicks[batchId][i];
            uint256 amt = batchTargetAmounts[batchId][i];
            amt = amt * newTotal / oldTotal;
            pendingBatchOrders[poolId][tick][b.zeroForOne] += amt;
            tickToBatchIds[poolId][tick][b.zeroForOne].push(batchId);
        }

        // 4. re-activate
        b.isActive = true;

        emit BatchFlipped(batchId, newTotal, b.zeroForOne);
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

    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal pure override returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal override returns (bytes4)
    {
        lastTicks[key.toId()] = tick;
        PoolId poolId = key.toId();
        poolInitialized[poolId] = true;
        poolIndex[poolId] = allPoolIds.length;
        allPoolIds.push(poolId);
        poolIdToKey[poolId] = key;
        emit PoolInitializationTracked(poolId, tick, block.timestamp);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender == address(this))
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        BeforeSwapDelta delta = _processLimitOrdersBeforeSwap(key, params);
        uint24 fee = BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, delta, fee);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
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

    function _validateOrderInputs(
        uint256[] memory targetPrices,
        uint256[] memory targetAmounts,
        uint256 deadline,
        address currency0,
        address currency1
    ) internal view {
        if (!(targetPrices.length == targetAmounts.length && targetPrices.length > 0 && targetPrices.length <= 10))
            revert InvalidArrays();
        if (deadline <= block.timestamp) revert ExpiredDeadline();
        if (currency0 == currency1) revert SameCurrencies();
    }

    function _createPoolKey(address currency0, address currency1, uint24 fee)
        internal view returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee | 0x800000,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(this))
        });
    }

    function _pricesToTicks(uint256[] memory prices) internal pure returns (int24[] memory ticks) {
        uint256 length = prices.length;
        ticks = new int24[](length);
        unchecked {
            for (uint256 i; i < length; ++i) ticks[i] = TickMath.getTickAtSqrtPrice(uint160(prices[i]));
        }
    }

    function _sumAmounts(uint256[] memory amounts) internal pure returns (uint256 total) {
        uint256 length = amounts.length;
        if (length == 0) revert EmptyArrays();
        unchecked {
            for (uint256 i; i < length; ++i) total += amounts[i];
        }
        if (total == 0) revert InvalidTotal();
    }

    function _ensurePoolInitialized(PoolKey memory key) internal {
        (uint160 currentPrice, , , ) = StateLibrary.getSlot0(poolManager, key.toId());
        if (currentPrice > 0) return;
        revert();
    }

    function _createBatch(
        PoolKey memory key,
        int24[] memory targetTicks,
        uint256[] memory targetAmounts,
        uint256 totalAmount,
        bool zeroForOne,
        uint32 slippage,
        uint256 deadline,
        bool flipEnabled // NEW
    ) internal returns (uint256 batchId) {
        batchId = nextBatchOrderId++;
        batchTargetTicks[batchId] = targetTicks;
        batchTargetAmounts[batchId] = targetAmounts;

        batchOrders[batchId] = BatchInfo({
            user: msg.sender,
            totalAmount: uint96(totalAmount),
            poolKey: key,
            expirationTime: uint64(deadline),
            maxSlippageBps: slippage,
            bestPriceTimeout: 0,
            ticksLength: uint16(targetTicks.length),
            zeroForOne: zeroForOne,
            isActive: true,
            flipEnabled: flipEnabled // NEW
        });

        PoolId poolId = key.toId();
        for (uint256 i = 0; i < targetTicks.length; i++) {
            pendingBatchOrders[poolId][targetTicks[i]][zeroForOne] += targetAmounts[i];
            tickToBatchIds[poolId][targetTicks[i]][zeroForOne].push(batchId);
        }
        claimTokensSupply[batchId] = totalAmount;
        _mint(msg.sender, address(uint160(batchId)), totalAmount);
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
        return 60;
    }

    function _decodeLiquidityOperation(bytes calldata data)
        external pure returns (PoolKey memory key, uint256 amount, bool zeroForOne, string memory operation)
    {
        return abi.decode(data, (PoolKey, uint256, bool, string));
    }

    function _handleLiquidityOperation(PoolKey memory key, uint256 amount, bool zeroForOne)
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

    function getBatchInfo(uint256 batchId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256 claimableAmount, bool isActive, bool isFullyExecuted,
        uint256 expirationTime, bool zeroForOne, uint256 totalBatches, uint24 currentFee
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        if (batch.user == address(0)) revert InvalidBatch();
        uint256 execAmount = uint256(batch.totalAmount) - claimTokensSupply[batchId];
        return (
            batch.user, Currency.unwrap(batch.poolKey.currency0), Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount), execAmount, claimableOutputTokens[batchId],
            batch.isActive, claimTokensSupply[batchId] == 0, uint256(batch.expirationTime),
            batch.zeroForOne, nextBatchOrderId - 1, BASE_FEE
        );
    }

    function getBatchInfoExtended(uint256 batchId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256 claimableAmount, bool isActive, bool isFullyExecuted,
        uint256 expirationTime, bool zeroForOne, uint256 totalBatches, uint24 currentFee,
        uint256 preCollectedGasFee, uint256 actualGasCost, uint256 gasRefundable
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        if (batch.user == address(0)) revert InvalidBatch();
        uint256 execAmount = uint256(batch.totalAmount) - claimTokensSupply[batchId];
        uint256 refundable = (preCollectedGasFees[batchId] > actualGasCosts[batchId] && !gasRefundProcessed[batchId])
            ? preCollectedGasFees[batchId] - actualGasCosts[batchId]
            : 0;
        return (
            batch.user, Currency.unwrap(batch.poolKey.currency0), Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount), execAmount, claimableOutputTokens[batchId], batch.isActive,
            claimTokensSupply[batchId] == 0, uint256(batch.expirationTime), batch.zeroForOne,
            nextBatchOrderId - 1, BASE_FEE, preCollectedGasFees[batchId], actualGasCosts[batchId], refundable
        );
    }

    function getBatchOrder(uint256 batchId) external view returns (
        address user, address currency0, address currency1, uint256 totalAmount,
        uint256 executedAmount, uint256[] memory targetPrices, uint256[] memory targetAmounts,
        bool isActive, bool isFullyExecuted
    ) {
        BatchInfo storage batch = batchOrders[batchId];
        int24[] memory targetTicks = batchTargetTicks[batchId];
        uint256[] memory amounts = batchTargetAmounts[batchId];
        uint256[] memory prices = new uint256[](targetTicks.length);
        for (uint256 i = 0; i < targetTicks.length; i++) {
            prices[i] = TickMath.getSqrtPriceAtTick(targetTicks[i]);
        }
        return (
            batch.user, Currency.unwrap(batch.poolKey.currency0), Currency.unwrap(batch.poolKey.currency1),
            uint256(batch.totalAmount), uint256(batch.totalAmount) - claimTokensSupply[batchId],
            prices, amounts, batch.isActive, claimTokensSupply[batchId] == 0
        );
    }

    /* ==========================================================
       FALLBACKS
       ========================================================== */
    receive() external payable {}
    fallback() external payable {}
}