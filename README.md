# DCA Dexter Bot V1
*Production-Ready DCA (Dollar Cost Averaging) Strategy Bot for Uniswap V4*

## 🎯 Overview

DCA Dexter Bot is a **sophisticated progressive DCA strategy system** built as a Uniswap V4 hook that enables automated dollar-cost averaging with dynamic take-profit management. This system implements true DCA strategies with progressive order creation, accumulated position tracking, and intelligent profit-taking.

**Key Features:**
- **Progressive DCA Execution**: Starts with initial swap, then creates buy orders progressively as price moves down
- **Dynamic Take-Profit Management**: Automatically adjusts take-profit orders based on accumulated average cost
- **Gas Tank System**: Self-sustaining gas pool that refills from successful swaps
- **Perpetual Operation**: Automatically restarts DCA cycle when take-profit is hit
- **Manual Sell Now**: Users can manually sell at market price and restart cycle

---

## ⚠️ Gas Management

In order to create a bot that can operate in perpetuity, a sophisticated **Central Gas Tank system** was devised.

- **Central Gas Tank**: A unified gas management system that holds all gas required for strategy execution, eliminating individual gas management complexity.

- **Gas Tank Economics**: 
  - **Central Management**: All DCA strategies pre-allocate total estimated gas to a central gasTank that handles ALL contract operations
  - **Pre-Allocation**: Each strategy estimates total gas required (initial swap + DCA levels + take profit + 20% buffer) and allocates upfront
  - **Real-time Deduction**: Gas is deducted from the tank for each swap operation during strategy execution
  - **Settlement on Completion**: When strategy completes (take profit or cancellation), unused gas is credited to user profits or deficit is debited
  - **Unified Operations**: All gas for swaps, limit orders, and contract operations comes from the central tank
  - **No External Dependencies**: Self-contained gas management without relying on external swapper compensation


---

## 🏗️ Contract Architecture

**DCA Execution Process:**

1) **Initial swap** (`_initiateFirstDCASwap()`)
  - Executes `order.baseSwapAmount` at market price via `poolManager.swap()`
  - Updates `dcaAccumulatedInput[dcaId]` and `dcaAccumulatedOutput[dcaId]`
  - Calls `_createTakeProfitOrder(dcaId)` to place initial take-profit sell order
  - Creates first DCA buy level via `_calculateInitialDCALevel()` and stores in `pendingOrders[poolId][tick][zeroForOne]`
  - Gas: `gasTank += totalEstimatedGas` central tank pre-allocated at creation to handle all strategy operations

2) **Level 1 buy triggers** (`_executeLimitOrdersAtTick()` → `_handleDCAExecution()`)
  - Price hits Level 1 tick, `_beforeSwap()` detects pending order and executes
  - `_handleDCAExecution(dcaId, executeAmount)` updates accumulation and calls `_cancelTakeProfitOrder(dcaId)`
  - `_createTakeProfitOrder(dcaId)` places new take-profit sized to updated `dcaAccumulatedOutput[dcaId]`
  - `_calculateNextDCALevel(dcaId, poolKey)` creates Level 2, adds to `pendingOrders` and `tickToOrderIds`
  - Gas: `gasTank -= swapGasCost` deducted for actual swap execution; `_settleGasAccounting(dcaId)` handles surplus/deficit on completion
    - Buy refills: attempts `requiredGas * 2` from `claimableOutputTokens[dcaId]`
    - If insufficient: `order.isStalled = true`, emits `DCAStalled(dcaId, order.gasTank)`

3) **Level 2+ buy triggers** (same `_handleDCAExecution()` flow)
  - Execute buy → `dcaAccumulatedInput[dcaId] += amount`, `dcaAccumulatedOutput[dcaId] += outputAmount`
  - `_cancelTakeProfitOrder()` → `_createTakeProfitOrder()` → `_calculateNextDCALevel()` if not `maxSwapOrders` reached
  - Gas: opportunistic `order.gasTank += gasContribution` when tank below threshold (via `gasTankPercent`)

4) **Take-profit execution** (`_handleTakeProfitHit()`)
  - Price hits `dcaTakeProfitTick[dcaId]`, opposite direction sell executes
  - `_handleTakeProfitHit(dcaId, takeProfitAmount)` cancels all pending buy levels in `pendingOrders`
  - Updates `claimableOutputTokens[dcaId] += profits` and calls `_restartDCAWithProfits(dcaId, profitAmount)`
  - `_restartDCAWithProfits()` reinvests profits via new `_initiateFirstDCASwap()` and `_calculateInitialDCALevel()`
  - Gas: `_tryRefillGasTankFromProfits(dcaId, requiredGas, false)` for exact gas amount before execution

5) **Manual override** (`sellNow()`)
  - User calls `sellNow(dcaId)` to immediately sell `dcaAccumulatedOutput[dcaId]` at market price
  - Cancels `dcaTakeProfitTick[dcaId]` via `_cancelTakeProfitOrder()` and clears all `pendingOrders` for this strategy
  - Direct `poolManager.swap()` call, transfers proceeds to user, then `_restartDCAWithProfits(dcaId, amountOut)`
  - Cancellation (`cancelDCAStrategy()`): refunds `order.gasTank` and remaining `pendingOrders` amounts to user

This makes the lifecycle deterministic and easy to follow: initial swap → progressive buys (each buy creates the next level and updates TP) → TP hit (cancels pending buys, takes profit, restarts). Gas handling is automatic: initial 2x allocation, per-execution deduction, opportunistic refill from profits (2x for buys / exact for sells), contribution back to the tank when low, and stall/refund semantics when funds are exhausted.

---

## 📊 Order Status System

**OrderStatus Enum Values:**
- **ACTIVE**: Order is running normally and processing DCA levels
- **COMPLETED**: Order finished successfully when take-profit was hit
- **CANCELLED**: Order was manually cancelled by user via `cancelDCAStrategy()`
- **STALLED**: Order is stalled due to insufficient gas in the central tank

**Status Transitions:**
- Creation → **ACTIVE** (when `createDCAStrategy()` is called)
- **ACTIVE** → **COMPLETED** (when take-profit target is reached)
- **ACTIVE** → **CANCELLED** (when user calls `cancelDCAStrategy()`)
- **ACTIVE** → **STALLED** (when gas tank has insufficient funds for next operation)

This unified status system replaces the previous separate `isActive` and `isStalled` boolean flags, providing clearer order lifecycle management.

---

### Core Contract: DCADexterBotV1 (23.97KB)

```solidity
contract DCADexterBotV1 is IDCADexterBotV1, ERC6909Base, BaseHook, IUnlockCallback
```

**Hook Permissions:**
```solidity
Hooks.Permissions({
    beforeInitialize: true,  // Pool setup and tracking
    afterInitialize: true,   // Track pool state
    beforeSwap: true,        // Execute DCA strategy orders during swaps
    afterSwap: true,         // Update pool state
    // All others: false
})
```

---

## 🔄 ABI Reference

This section documents the contract's external and public ABI: functions (signatures, inputs, outputs), events, errors, and important storage shapes. Use this as the canonical reference when integrating wallets, UIs, or off-chain services.

### Key Structs & Mappings
- `OrderInfo` (storage struct): represents a DCA strategy. Key fields:
  - `address user` — owner of the DCA strategy
  - `uint96 totalAmount` — total input amount deposited for the strategy
  - `PoolKey poolKey` — pool identifiers (currency0, currency1, fee, tickSpacing)
  - `uint64 expirationTime` — strategy expiration timestamp
  - `uint32 takeProfitPercent` — take-profit percentage (basis points, 0-5000 = 0-50%)
  - `uint8 maxSwapOrders` — maximum DCA levels (1-10)
  - `uint256 baseSwapAmount` — base swap amount used for initial swap
  - `uint256 gasTank` — remaining ETH in the order's gas tank
  - `uint32 gasTankPercent` — percent of swap amount used to opportunistically refill tank (bps; 0-1000 = 0-10%)

- Important mappings:
  - `mapping(uint256 => uint256) dcaAccumulatedInput` — cumulative input spent
  - `mapping(uint256 => uint256) dcaAccumulatedOutput` — cumulative output tokens accumulated (sells from this amount)
  - `mapping(uint256 => int24) dcaTakeProfitTick` — current take-profit tick for an order

### Errors (revert selectors)
- `error NothingToClaim()` — no claimable profits available
- `error InvalidBatchId()` — provided batch id is out of range
- `error OrderNotActive()` — order is not active
- `error NotAuthorized()` — caller not authorized for the operation
- `error NoTokensToCancel()` — user has no claim tokens to burn on cancel
- `error BatchAlreadyExecutedUseRedeem()` — nothing left to cancel (historical; redeem flow removed)
- `error InsufficientClaimTokenBalance()` — caller doesn't hold required claim tokens
- `error InvalidFeeRecipient()` — owner/executor addresses invalid
- `error InvalidExecutorAddress()` — invalid executor
- `error ExpiredDeadline()` — provided expirationTime is in the past
- `error SameCurrencies()` — pool currencies are identical
- `error InvalidAmount()` — zero or invalid amounts provided
- `error InvalidBatch()` — batch data not found
- `error InvalidTakeProfitPercent()` — takeProfit percent outside allowed range
- `error InvalidMaxSwapOrders()` — maxSwapOrders outside allowed range
- `error InvalidPriceDeviation()` — price deviation outside allowed range
- `error InvalidMultiplier()` — multiplier outside allowed range
- `error InsufficientGasTank()` — gas tank amount not provided or zero
- `error OrderStalled()` — operation cannot run because order is stalled

### Events
- `event DCAStrategyCreated(uint256 indexed dcaId, address indexed user, address currency0, address currency1, uint256 totalAmount, uint32 takeProfitPercent, uint8 maxSwapOrders)` — emitted on successful order creation
- `event DCASwapExecuted(uint256 indexed dcaId, uint256 level, uint256 amountIn, uint256 amountOut, bool direction)` — emitted when a DCA swap or manual sell executes. `level` uses special markers: `0` initial swap, `999` take-profit, `1000` manual sell.
- `event DCARestarted(uint256 indexed dcaId, uint256 profitAmount)` — emitted when a perpetual DCA restarts using profits
- `event GasTankContribution(uint256 indexed dcaId, uint256 amount)` — emitted when gas tank is topped up (either opportunistic contribution or refill from profits)
- `event DCAStalled(uint256 indexed dcaId, uint256 gasTankRemaining)` — emitted when order becomes stalled
- `event BatchOrderCancelledOptimized(uint256 indexed batchId, address indexed user)` — cancellation event
- `event PoolInitializationTracked(PoolId indexed poolId, int24 initialTick, uint256 timestamp)` — pool init tracking

### Public / External Functions (ABI)
Below are the key externally-callable functions and their shapes. For full parameter docs see the `DCAParams` and `PoolParams` structures in `IDCADexterBotV1.sol`.

- `function createDCAStrategy(PoolParams calldata pool, DCAParams calldata dca, uint32 slippage, uint256 expirationTime, uint256 gasBaseAmount) external payable returns (uint256 dcaId)`
  - Creates a perpetual DCA order. `msg.value` must include required ETH for gasTank (2x) and optionally ETH input if `currency0`/`currency1` is ETH.
  - Returns newly created `dcaId`.

- `function cancelDCAStrategy(uint256 dcaOrderId) external`
  - Cancels all pending buy & take-profit orders for `dcaOrderId`, refunds unspent input and remaining `gasTank` to the user, burns claim tokens, deactivates the order.

- `function sellNow(uint256 dcaId) external`
  - Cancels the take-profit limit order and all pending buy levels, then sells the total `dcaAccumulatedOutput[dcaId]` at market price immediately. Transfers proceeds to the user and restarts the DCA cycle using proceeds.

  
  Note: `redeemProfits` was removed from the contract. Profits are settled on-chain via take-profit executions or `sellNow`; integrations should listen for `DCARestarted` / `DCASwapExecuted` to detect profit settlement.

- `function getPoolCurrentTick(PoolId poolId) external view returns (int24)` — returns the pool's current tick.
- `function getAllPools() external view returns (PoolId[] memory poolIds, PoolKey[] memory poolKeys, int24[] memory ticks)` — helper listing tracked pools.
- `function getPoolCount() external view returns (uint256)` — tracked pool count.

- `function getDCAInfo(uint256 dcaId) external view returns (address user, address currency0, address currency1, uint256 totalAmount, uint256 executedAmount, uint256 claimableAmount, OrderStatus status, bool isFullyExecuted, uint256 expirationTime, bool zeroForOne, uint256 totalLevels, uint24 currentFee)`
  - Returns common DCA metadata and execution state. Status enum values: ACTIVE, COMPLETED, CANCELLED, STALLED.

- `function getDCAInfoExtended(uint256 dcaId) external view returns (address user, address currency0, address currency1, uint256 totalAmount, uint256 executedAmount, uint256 claimableAmount, OrderStatus status, bool isFullyExecuted, uint256 expirationTime, bool zeroForOne, uint256 totalLevels, uint24 currentFee, uint256 gasAllocated, uint256 gasUsed)`
  - Extended view including gas allocation and usage tracking.

- `function getDCAOrder(uint256 dcaId) external view returns (address user, address currency0, address currency1, uint256 totalAmount, uint256 executedAmount, uint256[] memory targetPrices, uint256[] memory targetAmounts, OrderStatus status, bool isFullyExecuted)`
  - Returns per-order target ticks/prices and amounts.

### Internal Gas / Execution Notes (for integrators)
- Estimated gas per DCA execution is used as a heuristic — the contract sets an approximate gas constant and checks/refills using this estimate. Integrators should expect the gas model to use approximations and rely on `getDCAInfoExtended` to inspect `gasTank` and `isStalled`.
- `claimableOutputTokens` are the canonical place where profits land after take-profit execution; they also serve as a backup refill source for the gas tank when the tank is low.

### Quick Examples (ABI usage)
- Create a DCA order (JS/ethers):
```js
const tx = await dcaBot.createDCAStrategy(poolParams, dcaParams, slippage, expiration, gasBaseAmountInWei);
const receipt = await tx.wait();
// Parse DCAStrategyCreated event to obtain dcaId
```

- Read extended info:
```js
const info = await dcaBot.getDCAInfoExtended(dcaId);
console.log(info.gasContribution, info.isStalled);
```

---

### Expanded ABI Details
Below are the exact helper structs used by the external ABI (copied from `IDCADexterBotV1.sol`) and field-level documentation to remove ambiguity.

- PoolParams (exact solidity type)
```solidity
struct PoolParams {
  address currency0; // token A (input token for the DCA)
  address currency1; // token B (output token)
  uint24 fee;        // pool fee tier (in hundredths of a bip as Uniswap uses)
}
```

- DCAParams (exact solidity type)
```solidity
struct DCAParams {
  bool zeroForOne;                // direction of swap: true means swap currency0 -> currency1
  uint32 takeProfitPercent;       // take-profit percent (bps; 100 = 1%)
  uint8 maxSwapOrders;            // maximum DCA levels (1-255; enforced by contract range checks)
  uint32 priceDeviationPercent;   // percent deviation per level (bps)
  uint32 priceDeviationMultiplier;// multiplier applied between levels
  uint256 swapOrderAmount;        // base swap amount for the initial swap (in input token units)
  uint32 swapOrderMultiplier;     // base multiplier used for exponential sizing
}
```

Notes on `createDCAStrategy` parameters:
- `slippage` (uint32) — maximum allowed slippage in bps for on-chain swaps (e.g., 100 = 1%)
- `expirationTime` (uint256) — UNIX timestamp after which the order cannot be created (must be > block.timestamp)
- `gasBaseAmount` (uint256) — Base gas amount for single swap operation; total strategy gas is calculated as: initial swap + (DCA levels * gasBaseAmount) + take profit + 20% buffer, then allocated to central gasTank
- `gasTankPercent` (uint32) — percentage (bps) of successful buy amounts that can be opportunistically routed back to the gas tank when the tank is low (for example, 100 = 1%)

### Events decoding table (examples)
This table shows typical event payloads and how a UI or integration should interpret them.

| Event | Example decoded object | Notes |
|---|---|---|
| `DCAStrategyCreated` | { dcaId: 42, user: '0x..', currency0: '0x..', currency1: '0x..', totalAmount: '1000000000000000000', takeProfitPercent: 300, maxSwapOrders: 5 } | Use `dcaId` to watch for subsequent `DCASwapExecuted` and `DCARestarted` events for lifecycle tracking. |
| `DCASwapExecuted` | { dcaId: 42, level: 1, amountIn: '200000000000000000', amountOut: '120000000000000000', direction: true } | `level`=0 initial market swap, `999`=take-profit, `1000`=manual sell. `direction`==true implies currency0→currency1. |
| `DCARestarted` | { dcaId: 42, profitAmount: '150000000000000000' } | Emitted when a perpetual order restarts using profits. `profitAmount` is the output token amount reinvested. |
| `GasTankContribution` | { dcaId: 42, amount: '5000000000000000' } | Small ETH contributions to the order gas tank; often from opportunistic taxation or refill from profits. |
| `DCAStalled` | { dcaId: 42, gasTankRemaining: '0' } | Indicates the order will not auto-execute until topped up. |

### Suggested integration checklist
- After creating an order, subscribe to `DCASwapExecuted` and `DCAStalled` for that `dcaId`.
- Poll `getDCAInfoExtended(dcaId)` periodically to show `gasContribution` and shared pool status in UIs.
### Suggested integration checklist
- After creating an order, subscribe to `DCASwapExecuted` and `DCAStalled` for that `dcaId`.
- When a user cancels or redeems, listen for `BatchOrderCancelledOptimized` to confirm on-chain settlement.
  - When a user cancels an order, listen for `BatchOrderCancelledOptimized` to confirm on-chain settlement.

If you'd like, I can also:
- Add TypeScript/TypeChain interface snippets for these structs and events.
- Generate a small example script that creates a DCA order with realistic param values.


