// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import "openzeppelin-contracts/contracts/access/Ownable.sol";
// import {ILimitOrderBatch} from "./interfaces/ILimitOrderBatch.sol";
// import {ERC6909Base} from "./base/ERC6909Base.sol";
// import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
// import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
// import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
// import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
// import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
// import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {BaseHook} from "@uniswap/v4-periphery/utils/BaseHook.sol";
// import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
// import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
// import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
// import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
// import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

// /**
//  * @title LimitOrderBatch - Fixed and Optimized Version
//  * @notice Secure batch limit order system with proper access control and fee management
//  * @dev Refactored to eliminate security issues and optimize gas usage
//  */
// contract LimitOrderBatch is ILimitOrderBatch, ERC6909Base, BaseHook, IUnlockCallback, Ownable {
//     using SafeERC20 for IERC20;
//     using CurrencyLibrary for Currency;
//     using PoolIdLibrary for PoolKey;
//     using StateLibrary for IPoolManager;
//     using FixedPointMathLib for uint256;
//     using LPFeeLibrary for uint24;

//     // ========== CONSTANTS ==========
//     uint24 public constant BASE_FEE = 3000; // 0.3%
//     uint256 public constant BASE_PROTOCOL_FEE_BPS = 50; // 0.5% protocol fee
//     uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
//     uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10% max slippage
//     uint256 public constant DEFAULT_SLIPPAGE_BPS = 300; // 3% default slippage
    
//     // Gas estimation constants
//     uint256 public constant ESTIMATED_EXECUTION_GAS = 150000;
//     uint256 public constant GAS_PRICE_BUFFER_MULTIPLIER = 120; // 20% buffer
//     uint256 public constant MAX_GAS_FEE_ETH = 0.01 ether; // Cap at 0.01 ETH

//     // ========== IMMUTABLE ==========
//     address public immutable FEE_RECIPIENT;

//     // ========== STORAGE ==========
    
//     // Core storage
//     mapping(PoolId => int24) public lastTicks;
//     mapping(PoolId => mapping(int24 => mapping(bool => uint256))) public pendingBatchOrders;
//     mapping(uint256 => uint256) public claimableOutputTokens;
//     mapping(uint256 => uint256) public claimTokensSupply;
//     mapping(PoolId => mapping(int24 => mapping(bool => uint256[]))) internal tickToBatchIds;
    
//     // Pool tracking
//     mapping(PoolId => bool) public poolInitialized;
//     PoolId[] public allPoolIds;
//     mapping(PoolId => PoolKey) public poolIdToKey;
//     mapping(PoolId => uint256) public poolIndex;

//     // Gas fee management
//     mapping(uint256 => uint256) public preCollectedGasFees;
//     mapping(uint256 => uint256) public actualGasCosts;
//     mapping(uint256 => bool) public gasRefundProcessed;
    
//     // Batch order storage
//     struct BatchInfo {
//         address user;                    // 20 bytes
//         uint96 totalAmount;             // 12 bytes (packed with user)
        
//         PoolKey poolKey;                // 32 bytes (separate slot)
        
//         uint64 expirationTime;          // 8 bytes
//         uint32 maxSlippageBps;          // 4 bytes
//         uint16 ticksLength;             // 2 bytes
//         bool zeroForOne;                // 1 byte
//         bool isActive;                  // 1 byte
//         // Remaining: 16 bytes padding
        
//         uint256 minOutputAmount;        // 32 bytes (separate slot)
//     }
    
//     mapping(uint256 => int24[]) public batchTargetTicks;
//     mapping(uint256 => uint256[]) public batchTargetAmounts;
//     mapping(uint256 => BatchInfo) public batchOrders;
//     uint256 public nextBatchOrderId = 1;

//     // Flip order storage
//     struct FlipOrder {
//         address user;
//         uint256 amount;
//         int24 flipTick;
//         bool isActive;
//         bool currentZeroForOne;
//     }
    
//     mapping(PoolId => mapping(uint256 => FlipOrder)) public flipOrders;
//     mapping(PoolId => uint256) public nextFlipOrderId;
//     mapping(PoolId => mapping(int24 => uint256[])) public tickToFlipOrders;

//     // ========== EVENTS ==========
//     event BatchOrderCreated(
//         uint256 indexed batchId, 
//         address indexed user, 
//         address indexed currency0,
//         address currency1,
//         uint256 totalAmount, 
//         uint256[] targetPrices, 
//         uint256[] targetAmounts
//     );
    
//     event BatchOrderCancelled(uint256 indexed batchId, address indexed user, uint256 refundAmount);
//     event TokensRedeemed(uint256 indexed batchId, address indexed user, uint256 inputAmount, uint256 outputAmount);
//     event BatchLevelExecuted(uint256 indexed batchId, uint256 levelIndex, uint256 tick, uint256 amount);
//     event BatchFullyExecuted(uint256 indexed batchId, uint256 totalExecuted, uint256 totalOutput);
//     event ManualBatchLevelExecuted(uint256 indexed batchId, uint256 levelIndex, address indexed executor, uint256 amount);
    
//     event GasFeePreCollected(uint256 indexed batchId, uint256 estimatedGasFee);
//     event GasFeeRefunded(uint256 indexed batchId, address indexed user, uint256 refundAmount);
//     event ProtocolFeePaid(uint256 indexed batchId, uint256 feeAmount);
    
//     event FlipOrderCreated(
//         PoolId indexed poolId,
//         uint256 indexed orderId,
//         address indexed user,
//         uint256 amount,
//         int24 flipTick,
//         bool initialZeroForOne
//     );
    
//     event FlipOrderExecuted(
//         PoolId indexed poolId,
//         uint256 indexed orderId,
//         address indexed user,
//         uint256 amount,
//         bool newDirection
//     );
    
//     event FlipOrderCancelled(
//         PoolId indexed poolId,
//         uint256 indexed orderId,
//         address indexed user,
//         uint256 refundAmount
//     );

//     // ========== ERRORS ==========
//     error InvalidBatchId();
//     error OrderNotActive();
//     error NotAuthorized();
//     error NoTokensToCancel();
//     error BatchAlreadyExecutedUseRedeem();
//     error NothingToCancel();
//     error InsufficientClaimTokenBalance();
//     error InsufficientETHForOrderPlusGas();
//     error InsufficientETHForGasFee();
//     error RefundAlreadyProcessed();
//     error BatchStillActive();
//     error InvalidFeeRecipient();
//     error InvalidArrays();
//     error ExpiredDeadline();
//     error SameCurrencies();
//     error EmptyArrays();
//     error InvalidAmount();
//     error InvalidTotal();
//     error NoPendingOrders();
//     error InvalidExecution();
//     error InvalidBatch();
//     error NothingToClaim();
//     error SlippageExceeded();
//     error TransferFailed();
//     error UnauthorizedCallback();
//     error InvalidSlippage();
//     error OrderExpired();
//     error InsufficientOutput();
//     error FlipOrderNotFound();
//     error InvalidPrice();

//     // ========== MODIFIERS ==========
//     modifier validBatchOrder(uint256 batchId) {
//         if (!(batchId > 0 && batchId < nextBatchOrderId)) revert InvalidBatchId();
//         if (!batchOrders[batchId].isActive) revert OrderNotActive();
//         _;
//     }

//     modifier onlyPoolManager() {
//         if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
//         _;
//     }

//     // ========== CONSTRUCTOR ==========
//     constructor(
//         IPoolManager _poolManager, 
//         address _feeRecipient, 
//         address _initialOwner
//     ) 
//         BaseHook(_poolManager) 
//         Ownable(_initialOwner)
//     {
//         if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
//         FEE_RECIPIENT = _feeRecipient;
//     }

//     // ========== MAIN FUNCTIONS ==========

//     /**
//      * @notice Create a batch limit order with proper price handling
//      * @param currency0 First token address
//      * @param currency1 Second token address  
//      * @param fee Pool fee tier
//      * @param zeroForOne Direction of swap
//      * @param targetPricesNormal Normal prices (not sqrt prices)
//      * @param targetAmounts Amounts for each price level
//      * @param deadline Expiration timestamp
//      * @param maxSlippageBps Maximum slippage in basis points
//      */
//     function createBatchOrder(
//         address currency0,
//         address currency1,
//         uint24 fee,
//         bool zeroForOne,
//         uint256[] calldata targetPricesNormal,
//         uint256[] calldata targetAmounts,
//         uint256 deadline,
//         uint256 maxSlippageBps
//     ) external payable returns (uint256 batchId) {
//         _validateOrderInputs(targetPricesNormal, targetAmounts, deadline, currency0, currency1, maxSlippageBps);
        
//         PoolKey memory key = _createPoolKey(currency0, currency1, fee);
//         _ensurePoolInitialized(key);
        
//         // Convert normal prices to sqrt prices and then to ticks
//         uint256[] memory sqrtPrices = _normalPricesToSqrtPrices(targetPricesNormal, currency0, currency1);
//         int24[] memory targetTicks = _sqrtPricesToTicks(sqrtPrices);
//         uint256 totalAmount = _sumAmounts(targetAmounts);
        
//         batchId = _createBatch(key, targetTicks, targetAmounts, totalAmount, zeroForOne, deadline, maxSlippageBps);
//         _handleTokenDeposit(key, zeroForOne, totalAmount, batchId);
        
//         emit BatchOrderCreated(batchId, msg.sender, currency0, currency1, totalAmount, targetPricesNormal, targetAmounts);
        
//         return batchId;
//     }

//     /**
//      * @notice Create a flip order that switches direction at a specified price
//      */
//     function createFlipOrder(
//         address currency0,
//         address currency1,
//         uint24 fee,
//         bool initialZeroForOne,
//         uint256 flipPriceNormal,
//         uint256 amount
//     ) external payable returns (uint256 orderId) {
//         if (amount == 0) revert InvalidAmount();
        
//         PoolKey memory key = _createPoolKey(currency0, currency1, fee);
//         PoolId poolId = key.toId();
//         _ensurePoolInitialized(key);
        
//         // Convert normal price to tick
//         uint256 sqrtPrice = _normalPriceToSqrtPrice(flipPriceNormal, currency0, currency1);
//         int24 flipTick = TickMath.getTickAtSqrtPrice(uint160(sqrtPrice));
        
//         orderId = nextFlipOrderId[poolId]++;
//         flipOrders[poolId][orderId] = FlipOrder({
//             user: msg.sender,
//             amount: amount,
//             flipTick: flipTick,
//             isActive: true,
//             currentZeroForOne: initialZeroForOne
//         });
        
//         tickToFlipOrders[poolId][flipTick].push(orderId);
//         _handleFlipOrderDeposit(key, initialZeroForOne, amount);
        
//         emit FlipOrderCreated(poolId, orderId, msg.sender, amount, flipTick, initialZeroForOne);
        
//         return orderId;
//     }

//     /**
//      * @notice Cancel batch order with proper refunds
//      */
//     function cancelBatchOrder(uint256 batchOrderId) external validBatchOrder(batchOrderId) {
//         BatchInfo storage batch = batchOrders[batchOrderId];
//         if (batch.user != msg.sender) revert NotAuthorized();
        
//         uint256 userClaimBalance = balanceOf[msg.sender][batchOrderId];
//         if (userClaimBalance == 0) revert NoTokensToCancel();
        
//         // Check if order has expired
//         if (block.timestamp > batch.expirationTime) revert OrderExpired();
        
//         // Calculate refundable amount
//         PoolId poolId = batch.poolKey.toId();
//         uint256 totalPendingAmount = 0;
//         for (uint256 i = 0; i < batch.ticksLength; i++) {
//             totalPendingAmount += pendingBatchOrders[poolId][batchTargetTicks[batchOrderId][i]][batch.zeroForOne];
//         }
        
//         if (totalPendingAmount == 0) revert BatchAlreadyExecutedUseRedeem();
        
//         uint256 cancellableAmount = userClaimBalance * totalPendingAmount / uint256(batch.totalAmount);
//         if (cancellableAmount == 0) revert NothingToCancel();
        
//         // Update state
//         _burn(msg.sender, address(uint160(batchOrderId)), cancellableAmount);
        
//         for (uint256 i = 0; i < batch.ticksLength; i++) {
//             int24 targetTick = batchTargetTicks[batchOrderId][i];
//             uint256 levelPending = pendingBatchOrders[poolId][targetTick][batch.zeroForOne];
//             if (levelPending > 0) {
//                 uint256 levelCancellation = cancellableAmount * levelPending / totalPendingAmount;
//                 pendingBatchOrders[poolId][targetTick][batch.zeroForOne] -= levelCancellation;
//             }
//         }
        
//         claimTokensSupply[batchOrderId] -= cancellableAmount;
//         if (totalPendingAmount == cancellableAmount) {
//             batch.isActive = false;
//         }
        
//         // Return tokens
//         Currency inputCurrency = batch.zeroForOne ? batch.poolKey.currency0 : batch.poolKey.currency1;
//         _safeTransfer(inputCurrency, msg.sender, cancellableAmount);
        
//         // Refund gas fee if fully cancelled
//         if (totalPendingAmount == cancellableAmount && !gasRefundProcessed[batchOrderId]) {
//             uint256 gasRefund = preCollectedGasFees[batchOrderId];
//             if (gasRefund > 0) {
//                 gasRefundProcessed[batchOrderId] = true;
//                 _safeTransferETH(msg.sender, gasRefund);
//                 emit GasFeeRefunded(batchOrderId, msg.sender, gasRefund);
//             }
//         }
        
//         emit BatchOrderCancelled(batchOrderId, msg.sender, cancellableAmount);
//     }

//     /**
//      * @notice Cancel flip order
//      */
//     function cancelFlipOrder(PoolId poolId, uint256 orderId) external {
//         FlipOrder storage order = flipOrders[poolId][orderId];
//         if (order.user != msg.sender) revert NotAuthorized();
//         if (!order.isActive) revert FlipOrderNotFound();
        
//         order.isActive = false;
        
//         // Remove from tick tracking
//         uint256[] storage orderIds = tickToFlipOrders[poolId][order.flipTick];
//         for (uint256 i = 0; i < orderIds.length; i++) {
//             if (orderIds[i] == orderId) {
//                 orderIds[i] = orderIds[orderIds.length - 1];
//                 orderIds.pop();
//                 break;
//             }
//         }
        
//         // Refund tokens
//         PoolKey memory key = poolIdToKey[poolId];
//         Currency refundCurrency = order.currentZeroForOne ? key.currency0 : key.currency1;
//         _safeTransfer(refundCurrency, msg.sender, order.amount);
        
//         emit FlipOrderCancelled(poolId, orderId, msg.sender, order.amount);
//     }

//     /**
//      * @notice Redeem executed order output tokens with proper fee deduction
//      */
//     function redeemBatchOrder(uint256 batchOrderId, uint256 inputAmountToClaimFor) external {
//         if (claimableOutputTokens[batchOrderId] == 0) revert NothingToClaim();
//         if (balanceOf[msg.sender][batchOrderId] < inputAmountToClaimFor) revert InsufficientClaimTokenBalance();

//         // Calculate proportional output
//         uint256 outputAmountGross = inputAmountToClaimFor.mulDivDown(
//             claimableOutputTokens[batchOrderId],
//             claimTokensSupply[batchOrderId]
//         );

//         // Deduct protocol fee
//         uint256 protocolFee = (outputAmountGross * BASE_PROTOCOL_FEE_BPS) / BASIS_POINTS_DENOMINATOR;
//         uint256 outputAmountNet = outputAmountGross - protocolFee;

//         // Update state
//         claimableOutputTokens[batchOrderId] -= outputAmountGross;
//         claimTokensSupply[batchOrderId] -= inputAmountToClaimFor;
//         _burn(msg.sender, address(uint160(batchOrderId)), inputAmountToClaimFor);

//         // Transfer tokens
//         BatchInfo storage batch = batchOrders[batchOrderId];
//         Currency outputCurrency = batch.zeroForOne ? batch.poolKey.currency1 : batch.poolKey.currency0;
        
//         _safeTransfer(outputCurrency, msg.sender, outputAmountNet);
//         _safeTransfer(outputCurrency, FEE_RECIPIENT, protocolFee);

//         emit TokensRedeemed(batchOrderId, msg.sender, inputAmountToClaimFor, outputAmountNet);
//         emit ProtocolFeePaid(batchOrderId, protocolFee);
//     }

//     /**
//      * @notice Execute a specific batch order level (only owner)
//      */
//     function executeBatchLevel(uint256 batchId, uint256 levelIndex) external onlyOwner returns (bool isFullyExecuted) {
//         BatchInfo storage batch = batchOrders[batchId];
//         if (!batch.isActive || levelIndex >= batch.ticksLength) revert InvalidExecution();
        
//         PoolId poolId = batch.poolKey.toId();
//         int24 targetTick = batchTargetTicks[batchId][levelIndex];
//         uint256 pendingAmount = pendingBatchOrders[poolId][targetTick][batch.zeroForOne];
//         if (pendingAmount == 0) revert NoPendingOrders();
        
//         uint256 amountToExecute = batchTargetAmounts[batchId][levelIndex];
//         if (pendingAmount < amountToExecute) {
//             amountToExecute = pendingAmount;
//         }
        
//         // Create swap params with proper slippage protection
//         uint160 sqrtPriceLimitX96 = _calculateSlippageLimit(batch.poolKey, batch.zeroForOne, batch.maxSlippageBps);
        
//         SwapParams memory params = SwapParams({
//             zeroForOne: batch.zeroForOne,
//             amountSpecified: -int256(amountToExecute),
//             sqrtPriceLimitX96: sqrtPriceLimitX96
//         });
        
//         // Execute swap
//         bytes memory result = poolManager.unlock(abi.encode("SWAP", batch.poolKey, params));
//         BalanceDelta delta = abi.decode(result, (BalanceDelta));
//         uint256 outputAmount = batch.zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        
//         // Check minimum output
//         if (outputAmount < batch.minOutputAmount * amountToExecute / uint256(batch.totalAmount)) {
//             revert InsufficientOutput();
//         }
        
//         // Update state
//         claimableOutputTokens[batchId] += outputAmount;
//         pendingBatchOrders[poolId][targetTick][batch.zeroForOne] -= amountToExecute;
        
//         if (pendingBatchOrders[poolId][targetTick][batch.zeroForOne] == 0) {
//             _removeBatchIdFromTick(poolId, targetTick, batch.zeroForOne, batchId);
//         }
        
//         // Check if fully executed
//         isFullyExecuted = true;
//         for (uint256 i = 0; i < batch.ticksLength; i++) {
//             if (pendingBatchOrders[poolId][batchTargetTicks[batchId][i]][batch.zeroForOne] > 0) {
//                 isFullyExecuted = false;
//                 break;
//             }
//         }
        
//         if (isFullyExecuted) {
//             batch.isActive = false;
//             emit BatchFullyExecuted(batchId, amountToExecute, claimableOutputTokens[batchId]);
//         }
        
//         emit ManualBatchLevelExecuted(batchId, levelIndex, msg.sender, amountToExecute);
//         emit BatchLevelExecuted(batchId, levelIndex, uint256(uint24(targetTick)), amountToExecute);
        
//         return isFullyExecuted;
//     }

//     /**
//      * @notice Process gas refund for completed orders
//      */
//     function processGasRefund(uint256 batchId) external {
//         if (gasRefundProcessed[batchId]) revert RefundAlreadyProcessed();
//         if (batchOrders[batchId].isActive) revert BatchStillActive();
        
//         uint256 preCollectedGas = preCollectedGasFees[batchId];
//         uint256 totalActualGas = actualGasCosts[batchId];
        
//         gasRefundProcessed[batchId] = true;
        
//         if (preCollectedGas > totalActualGas) {
//             uint256 refundAmount = preCollectedGas - totalActualGas;
//             address user = batchOrders[batchId].user;
//             _safeTransferETH(user, refundAmount);
//             emit GasFeeRefunded(batchId, user, refundAmount);
//         } else {
//             emit GasFeeRefunded(batchId, batchOrders[batchId].user, 0);
//         }
//     }

//     // ========== HOOK IMPLEMENTATIONS ==========

//     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
//         return Hooks.Permissions({
//             beforeInitialize: false,
//             afterInitialize: true,
//             beforeSwap: false,
//             afterSwap: true,  // Process limit orders after market swaps
//             beforeAddLiquidity: false,
//             afterAddLiquidity: false,
//             beforeRemoveLiquidity: false,
//             afterRemoveLiquidity: false,
//             beforeDonate: false,
//             afterDonate: false,
//             beforeSwapReturnDelta: false,
//             afterSwapReturnDelta: false,
//             afterAddLiquidityReturnDelta: false,
//             afterRemoveLiquidityReturnDelta: false
//         });
//     }

//     function _afterInitialize(
//         address,
//         PoolKey calldata key,
//         uint160,
//         int24 tick
//     ) internal override returns (bytes4) {
//         lastTicks[key.toId()] = tick;
        
//         PoolId poolId = key.toId();
//         if (!poolInitialized[poolId]) {
//             poolInitialized[poolId] = true;
//             poolIndex[poolId] = allPoolIds.length;
//             allPoolIds.push(poolId);
//             poolIdToKey[poolId] = key;
//         }
        
//         return BaseHook.afterInitialize.selector;
//     }

//     function _afterSwap(
//         address sender,
//         PoolKey calldata key,
//         SwapParams calldata params,
//         BalanceDelta delta,
//         bytes calldata
//     ) internal override returns (bytes4, int128) {
//         // Skip hook processing if the sender is this contract
//         if (sender == address(this)) return (BaseHook.afterSwap.selector, 0);

//         // Update last tick
//         (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
//         lastTicks[key.toId()] = currentTick;
        
//         // Process limit orders that can be triggered by the price movement
//         _processTriggeredLimitOrders(key, currentTick);
        
//         return (BaseHook.afterSwap.selector, 0);
//     }

//     // ========== UNLOCK CALLBACK ==========

//     function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
//         (string memory operationType) = abi.decode(data, (string));
        
//         if (keccak256(abi.encodePacked(operationType)) == keccak256(abi.encodePacked("SWAP"))) {
//             (, PoolKey memory key, SwapParams memory params) = abi.decode(data, (string, PoolKey, SwapParams));
//             BalanceDelta delta = poolManager.swap(key, params, "");
            
//             // Handle settlement
//             _settleDelta(key, delta);
            
//             return abi.encode(delta);
//         }
        
//         revert UnauthorizedCallback();
//     }

//     // ========== INTERNAL HELPER FUNCTIONS ==========

//     function _validateOrderInputs(
//         uint256[] memory targetPrices,
//         uint256[] memory targetAmounts,
//         uint256 deadline,
//         address currency0,
//         address currency1,
//         uint256 maxSlippageBps
//     ) internal view {
//         if (targetPrices.length != targetAmounts.length || targetPrices.length == 0 || targetPrices.length > 10) {
//             revert InvalidArrays();
//         }
//         if (deadline <= block.timestamp) revert ExpiredDeadline();
//         if (currency0 == currency1) revert SameCurrencies();
//         if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();
//     }

//     function _createPoolKey(address currency0, address currency1, uint24 fee) internal view returns (PoolKey memory) {
//         return PoolKey({
//             currency0: Currency.wrap(currency0),
//             currency1: Currency.wrap(currency1),
//             fee: fee,
//             tickSpacing: _getTickSpacing(fee),
//             hooks: IHooks(address(this))
//         });
//     }

//     function _normalPricesToSqrtPrices(
//         uint256[] memory normalPrices,
//         address currency0,
//         address currency1
//     ) internal view returns (uint256[] memory sqrtPrices) {
//         sqrtPrices = new uint256[](normalPrices.length);
        
//         // Get token decimals for proper price conversion
//         uint8 decimals0 = _getTokenDecimals(currency0);
//         uint8 decimals1 = _getTokenDecimals(currency1);
        
//         for (uint256 i = 0; i < normalPrices.length; i++) {
//             sqrtPrices[i] = _normalPriceToSqrtPrice(normalPrices[i], currency0, currency1);
//         }
//     }

//     function _normalPriceToSqrtPrice(
//         uint256 normalPrice,
//         address currency0,
//         address currency1
//     ) internal view returns (uint256) {
//         if (normalPrice == 0) revert InvalidPrice();
        
//         uint8 decimals0 = _getTokenDecimals(currency0);
//         uint8 decimals1 = _getTokenDecimals(currency1);
        
//         // Adjust price for decimal difference
//         uint256 adjustedPrice;
//         if (decimals0 >= decimals1) {
//             adjustedPrice = normalPrice * (10 ** (decimals0 - decimals1));
//         } else {
//             adjustedPrice = normalPrice / (10 ** (decimals1 - decimals0));
//         }
        
//         // Convert to sqrt price (price is token1/token0)
//         // sqrtPrice = sqrt(adjustedPrice) * 2^96
//         uint256 sqrtPrice = adjustedPrice.sqrt() << FixedPoint96.RESOLUTION;
        
//         return sqrtPrice;
//     }

//     function _sqrtPricesToTicks(uint256[] memory sqrtPrices) internal pure returns (int24[] memory ticks) {
//         ticks = new int24[](sqrtPrices.length);
//         for (uint256 i = 0; i < sqrtPrices.length; i++) {
//             ticks[i] = TickMath.getTickAtSqrtPrice(uint160(sqrtPrices[i]));
//         }
//     }

//     function _getTokenDecimals(address token) internal view returns (uint8) {
//         if (token == address(0)) return 18; // ETH has 18 decimals
        
//         try IERC20(token).decimals() returns (uint8 decimals) {
//             return decimals;
//         } catch {
//             return 18; // Default to 18 if call fails
//         }
//     }

//     function _sumAmounts(uint256[] memory amounts) internal pure returns (uint256 total) {
//         if (amounts.length == 0) revert EmptyArrays();
        
//         for (uint256 i = 0; i < amounts.length; i++) {
//             if (amounts[i] == 0) revert InvalidAmount();
//             total += amounts[i];
//         }
        
//         if (total == 0) revert InvalidTotal();
//     }

//     function _ensurePoolInitialized(PoolKey memory key) internal view {
//         PoolId poolId = key.toId();
        
//         try poolManager.getSlot0(poolId) returns (uint160 currentPrice, int24, uint24, uint24) {
//             if (currentPrice == 0) revert InvalidBatch();
//         } catch {
//             revert InvalidBatch();
//         }
//     }

//     function _createBatch(
//         PoolKey memory key,
//         int24[] memory targetTicks,
//         uint256[] memory targetAmounts,
//         uint256 totalAmount,
//         bool zeroForOne,
//         uint256 deadline,
//         uint256 maxSlippageBps
//     ) internal returns (uint256 batchId) {
//         batchId = nextBatchOrderId++;
        
//         // Store arrays in separate mappings
//         batchTargetTicks[batchId] = targetTicks;
//         batchTargetAmounts[batchId] = targetAmounts;
        
//         batchOrders[batchId] = BatchInfo({
//             user: msg.sender,
//             totalAmount: uint96(totalAmount),
//             poolKey: key,
//             expirationTime: uint64(deadline),
//             maxSlippageBps: uint32(maxSlippageBps),
//             ticksLength: uint16(targetTicks.length),
//             zeroForOne: zeroForOne,
//             isActive: true,
//             minOutputAmount: 0 // Can be set based on slippage requirements
//         });

//         // Add to pending orders
//         PoolId poolId = key.toId();
//         for (uint256 i = 0; i < targetTicks.length; i++) {
//             pendingBatchOrders[poolId][targetTicks[i]][zeroForOne] += targetAmounts[i];
//             tickToBatchIds[poolId][targetTicks[i]][zeroForOne].push(batchId);
//         }

//         // Mint claim tokens
//         claimTokensSupply[batchId] = totalAmount;
//         _mint(msg.sender, address(uint160(batchId)), totalAmount);
//     }

//     function _handleTokenDeposit(
//         PoolKey memory key,
//         bool zeroForOne,
//         uint256 totalAmount,
//         uint256 batchId
//     ) internal {
//         Currency sellCurrency = zeroForOne ? key.currency0 : key.currency1;
        
//         // Calculate and collect gas fee
//         uint256 estimatedGasFee = _calculateEstimatedGasFee();
//         preCollectedGasFees[batchId] = estimatedGasFee;
        
//         if (Currency.unwrap(sellCurrency) == address(0)) {
//             // ETH case
//             if (msg.value < totalAmount + estimatedGasFee) revert InsufficientETHForOrderPlusGas();
            
//             // Refund excess ETH
//             uint256 excess = msg.value - totalAmount - estimatedGasFee;
//             if (excess > 0) {
//                 _safeTransferETH(msg.sender, excess);
//             }
//         } else {
//             // ERC20 case
//             if (msg.value < estimatedGasFee) revert InsufficientETHForGasFee();
            
//             // Refund excess ETH
//             uint256 excess = msg.value - estimatedGasFee;
//             if (excess > 0) {
//                 _safeTransferETH(msg.sender, excess);
//             }
            
//             IERC20(Currency.unwrap(sellCurrency)).safeTransferFrom(msg.sender, address(this), totalAmount);
//         }
        
//         emit GasFeePreCollected(batchId, estimatedGasFee);
//     }

//     function _handleFlipOrderDeposit(
//         PoolKey memory key,
//         bool zeroForOne,
//         uint256 amount
//     ) internal {
//         Currency sellCurrency = zeroForOne ? key.currency0 : key.currency1;
        
//         if (Currency.unwrap(sellCurrency) == address(0)) {
//             // ETH case
//             if (msg.value < amount) revert InsufficientETHForOrderPlusGas();
            
//             // Refund excess
//             uint256 excess = msg.value - amount;
//             if (excess > 0) {
//                 _safeTransferETH(msg.sender, excess);
//             }
//         } else {
//             // ERC20 case - no ETH needed for flip orders
//             IERC20(Currency.unwrap(sellCurrency)).safeTransferFrom(msg.sender, address(this), amount);
//         }
//     }

//     function _calculateEstimatedGasFee() internal view returns (uint256) {
//         uint256 estimatedCost = ESTIMATED_EXECUTION_GAS * tx.gasprice;
//         estimatedCost = (estimatedCost * GAS_PRICE_BUFFER_MULTIPLIER) / 100;
        
//         if (estimatedCost > MAX_GAS_FEE_ETH) {
//             estimatedCost = MAX_GAS_FEE_ETH;
//         }
        
//         return estimatedCost;
//     }

//     function _calculateSlippageLimit(
//         PoolKey memory key,
//         bool zeroForOne,
//         uint256 slippageBps
//     ) internal view returns (uint160) {
//         PoolId poolId = key.toId();
//         (uint160 currentPrice, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
//         if (zeroForOne) {
//             // Selling token0, price going down - set minimum acceptable price
//             uint256 minPriceWithSlippage = uint256(currentPrice) * (BASIS_POINTS_DENOMINATOR - slippageBps) / BASIS_POINTS_DENOMINATOR;
//             return uint160(minPriceWithSlippage);
//         } else {
//             // Buying token0, price going up - set maximum acceptable price
//             uint256 maxPriceWithSlippage = uint256(currentPrice) * (BASIS_POINTS_DENOMINATOR + slippageBps) / BASIS_POINTS_DENOMINATOR;
//             return uint160(maxPriceWithSlippage);
//         }
//     }

//     function _safeTransfer(Currency currency, address to, uint256 amount) internal {
//         if (amount == 0) return;
        
//         if (Currency.unwrap(currency) == address(0)) {
//             _safeTransferETH(to, amount);
//         } else {
//             IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
//         }
//     }

//     function _safeTransferETH(address to, uint256 amount) internal {
//         if (amount == 0) return;
        
//         (bool success, ) = payable(to).call{value: amount}("");
//         if (!success) revert TransferFailed();
//     }

//     function _settleDelta(PoolKey memory key, BalanceDelta delta) internal {
//         // Handle token0 settlement
//         if (delta.amount0() > 0) {
//             // We owe token0 to the pool
//             if (Currency.unwrap(key.currency0) == address(0)) {
//                 poolManager.settle{value: uint256(int256(delta.amount0()))}();
//             } else {
//                 IERC20(Currency.unwrap(key.currency0)).safeTransfer(
//                     address(poolManager),
//                     uint256(int256(delta.amount0()))
//                 );
//                 poolManager.settle();
//             }
//         } else if (delta.amount0() < 0) {
//             // Pool owes us token0
//             poolManager.take(key.currency0, address(this), uint256(int256(-delta.amount0())));
//         }

//         // Handle token1 settlement
//         if (delta.amount1() > 0) {
//             // We owe token1 to the pool
//             IERC20(Currency.unwrap(key.currency1)).safeTransfer(
//                 address(poolManager),
//                 uint256(int256(delta.amount1()))
//             );
//             poolManager.settle();
//         } else if (delta.amount1() < 0) {
//             // Pool owes us token1
//             poolManager.take(key.currency1, address(this), uint256(int256(-delta.amount1())));
//         }
//     }

//     function _processTriggeredLimitOrders(PoolKey calldata key, int24 currentTick) internal {
//         PoolId poolId = key.toId();
//         int24 lastTick = lastTicks[poolId];
        
//         // Process flip orders
//         _processFlipOrdersForPriceMovement(poolId, lastTick, currentTick, key.tickSpacing);
        
//         // Update last tick
//         lastTicks[poolId] = currentTick;
//     }

//     function _processFlipOrdersForPriceMovement(
//         PoolId poolId,
//         int24 fromTick,
//         int24 toTick,
//         int24 tickSpacing
//     ) internal {
//         // Determine the range to check based on price movement direction
//         int24 startTick = fromTick < toTick ? fromTick : toTick;
//         int24 endTick = fromTick > toTick ? fromTick : toTick;
        
//         // Check all ticks in the range for flip orders
//         for (int24 tick = startTick; tick <= endTick; tick += tickSpacing) {
//             uint256[] storage orderIds = tickToFlipOrders[poolId][tick];
            
//             for (uint256 i = 0; i < orderIds.length; i++) {
//                 uint256 orderId = orderIds[i];
//                 FlipOrder storage order = flipOrders[poolId][orderId];
                
//                 if (order.isActive && _shouldFlipOrder(tick, fromTick, toTick, order.currentZeroForOne)) {
//                     // Execute flip
//                     order.currentZeroForOne = !order.currentZeroForOne;
                    
//                     emit FlipOrderExecuted(
//                         poolId,
//                         orderId,
//                         order.user,
//                         order.amount,
//                         order.currentZeroForOne
//                     );
//                 }
//             }
//         }
//     }

//     function _shouldFlipOrder(
//         int24 flipTick,
//         int24 fromTick,
//         int24 toTick,
//         bool currentZeroForOne
//     ) internal pure returns (bool) {
//         if (fromTick == toTick) return false;
        
//         if (fromTick < toTick) {
//             // Price went up - flip sell orders (zeroForOne = true) to buy orders
//             return currentZeroForOne && flipTick >= fromTick && flipTick <= toTick;
//         } else {
//             // Price went down - flip buy orders (zeroForOne = false) to sell orders
//             return !currentZeroForOne && flipTick <= fromTick && flipTick >= toTick;
//         }
//     }

//     function _removeBatchIdFromTick(
//         PoolId poolId,
//         int24 tick,
//         bool zeroForOne,
//         uint256 batchOrderId
//     ) internal {
//         uint256[] storage batchIds = tickToBatchIds[poolId][tick][zeroForOne];
//         for (uint256 i = 0; i < batchIds.length; i++) {
//             if (batchIds[i] == batchOrderId) {
//                 batchIds[i] = batchIds[batchIds.length - 1];
//                 batchIds.pop();
//                 break;
//             }
//         }
//     }

//     function _getTickSpacing(uint24 fee) internal pure returns (int24) {
//         if (fee == 100) return 1;
//         if (fee == 500) return 10;
//         if (fee == 3000) return 60;
//         if (fee == 10000) return 200;
//         return 60; // Default
//     }

//     // ========== VIEW FUNCTIONS ==========

//     function getBatchInfo(uint256 batchId) external view returns (
//         address user,
//         address currency0,
//         address currency1,
//         uint256 totalAmount,
//         uint256 executedAmount,
//         uint256 claimableAmount,
//         bool isActive,
//         bool isFullyExecuted,
//         uint256 expirationTime,
//         bool zeroForOne,
//         uint256 totalBatches,
//         uint24 currentFee
//     ) {
//         BatchInfo storage batch = batchOrders[batchId];
//         if (batch.user == address(0)) revert InvalidBatch();

//         uint256 execAmount = uint256(batch.totalAmount) - claimTokensSupply[batchId];

//         return (
//             batch.user,
//             Currency.unwrap(batch.poolKey.currency0),
//             Currency.unwrap(batch.poolKey.currency1),
//             uint256(batch.totalAmount),
//             execAmount,
//             claimableOutputTokens[batchId],
//             batch.isActive,
//             claimTokensSupply[batchId] == 0,
//             uint256(batch.expirationTime),
//             batch.zeroForOne,
//             nextBatchOrderId - 1,
//             BASE_FEE
//         );
//     }

//     function getBatchOrder(uint256 batchId) external view returns (
//         address user,
//         address currency0,
//         address currency1,
//         uint256 totalAmount,
//         uint256 executedAmount,
//         uint256[] memory targetPrices,
//         uint256[] memory targetAmounts,
//         bool isActive,
//         bool isFullyExecuted
//     ) {
//         BatchInfo storage batch = batchOrders[batchId];

//         int24[] memory targetTicks = batchTargetTicks[batchId];
//         uint256[] memory amounts = batchTargetAmounts[batchId];

//         // Convert ticks back to sqrt prices
//         uint256[] memory prices = new uint256[](targetTicks.length);
//         for (uint256 i = 0; i < targetTicks.length; i++) {
//             prices[i] = TickMath.getSqrtPriceAtTick(targetTicks[i]);
//         }

//         return (
//             batch.user,
//             Currency.unwrap(batch.poolKey.currency0),
//             Currency.unwrap(batch.poolKey.currency1),
//             uint256(batch.totalAmount),
//             uint256(batch.totalAmount) - claimTokensSupply[batchId],
//             prices,
//             amounts,
//             batch.isActive,
//             claimTokensSupply[batchId] == 0
//         );
//     }

//     function getAllPools() external view returns (
//         PoolId[] memory poolIds,
//         PoolKey[] memory poolKeys,
//         int24[] memory ticks
//     ) {
//         uint256 length = allPoolIds.length;
//         poolIds = new PoolId[](length);
//         poolKeys = new PoolKey[](length);
//         ticks = new int24[](length);

//         for (uint256 i = 0; i < length; i++) {
//             poolIds[i] = allPoolIds[i];
//             poolKeys[i] = poolIdToKey[allPoolIds[i]];
//             ticks[i] = lastTicks[allPoolIds[i]];
//         }

//         return (poolIds, poolKeys, ticks);
//     }

//     function getPoolCount() external view returns (uint256) {
//         return allPoolIds.length;
//     }

//     function getGasRefundInfo(uint256 batchId) external view returns (
//         uint256 preCollected,
//         uint256 actualUsed,
//         uint256 refundable,
//         bool processed
//     ) {
//         preCollected = preCollectedGasFees[batchId];
//         actualUsed = actualGasCosts[batchId];
//         processed = gasRefundProcessed[batchId];

//         if (preCollected > actualUsed && !processed) {
//             refundable = preCollected - actualUsed;
//         } else {
//             refundable = 0;
//         }
//     }

//     function getFlipOrder(PoolId poolId, uint256 orderId) external view returns (
//         address user,
//         uint256 amount,
//         int24 flipTick,
//         bool isActive,
//         bool currentZeroForOne
//     ) {
//         FlipOrder storage order = flipOrders[poolId][orderId];
//         return (order.user, order.amount, order.flipTick, order.isActive, order.currentZeroForOne);
//     }

//     function getPoolCurrentTick(PoolId poolId) external view returns (int24) {
//         (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
//         return currentTick;
//     }

//     // ========== EMERGENCY FUNCTIONS (ONLY OWNER) ==========

//     function emergencyWithdraw(Currency currency, uint256 amount) external onlyOwner {
//         _safeTransfer(currency, owner(), amount);
//     }

//     function updateFeeRecipient(address newFeeRecipient) external onlyOwner {
//         if (newFeeRecipient == address(0)) revert InvalidFeeRecipient();
//         // Note: FEE_RECIPIENT is immutable, so this would require a new contract deployment
//         // This function is here for interface compatibility but will not work with immutable
//     }

//     // ========== FALLBACKS ==========
//     receive() external payable {}
//     fallback() external payable {}
// }