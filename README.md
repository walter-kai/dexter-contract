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

## ⚠️ Gas Caveats

In order to create a bot that can operate in perpetuity, a sophisticated **Gas Tank system** was devised.

- **Stall Protection**: When a DCA strategy's gas tank is exhausted AND no claimable profits are available for automatic refill, the strategy becomes "stalled" and will not execute further automatic orders until manually topped up. This prevents failed executions but requires user intervention only when both gas tank and profit backup are depleted.

- **Gas Tank Economics**: 
  - **Automatic Refill**: Gas tank automatically refills from claimable profits when running low, serving as a backup mechanism
  - **Initial Allocation**: At strategy creation, 2x the gas amount is allocated to ensure sufficient gas for multiple swaps
  - **Smart Refill Logic**: 
    - For buy orders: Attempts to refill with 2x required gas (likely to swap again)
    - For sell orders: Refills with exact amount needed
    - Only triggers refill when tank is insufficient for execution
  - **Fallback**: If no claimable profits available for refill, strategy becomes stalled until manual intervention
  - **Efficiency**: Gas contribution from successful buys only happens when tank is running low (below 2x estimated gas cost)
  - Consider conservative `priceDeviationMultiplier` and reasonable `maxSwapOrders` to optimize gas usage


---

## 🏗️ Architecture Evolution

**DCA Execution Process:**

1) Initial swap (immediate upon creation)
  - Executes the base swap amount at market price.
  - Creates a TAKE-PROFIT SELL order sized to the accumulated output.
  - Creates the first BUY limit order at Level 1 deviation (first DCA level).
  - Gas: the contract allocates 2x the user-provided `gasTankAmount` at creation. This provides an execution buffer so the strategy can continue for at least one additional execution without immediate top-up.

2) Level 1 (first buy) triggers
  - When price reaches Level 1 tick, the buy executes.
  - The contract updates accumulated position and re-calculates the TAKE-PROFIT SELL order (cancels old TP and places an updated one sized to new accumulated output).
  - It then creates Level 2 (next buy) at the next deviation.
  - Gas: before executing the DCA buy the contract deducts an estimated gas amount from the `gasTank`. If the tank is below the estimated amount, the contract will first attempt an automatic refill from `claimableOutputTokens`:
    - For buy executions the refill attempts to allocate up to 2x the required gas from available profits (because another swap is likely to follow).
    - For sell (take-profit) executions the refill uses the exact required gas amount.
    - If available profits are insufficient to refill, the strategy is marked `isStalled` and will not execute further automatic orders until topped up.

3) Level 2 (second buy) triggers
  - Same flow: execute buy → update accumulation → update TAKE-PROFIT SELL → create next buy level.
  - Gas: successful buys will contribute a percentage (`gasTankPercent`) back into the tank, but only when the tank is running low (this minimizes unnecessary taxation of every swap).

4) TAKE-PROFIT hit (sell executes)
  - Cancels all pending buy levels
  - Settles profits to claimable output (available for user redemption via `redeemProfits`)
  - Restarts the DCA cycle by reinvesting profits (creating a fresh initial swap and Level 1)
  - Gas: take-profit sells use the same automatic refill logic prior to execution (exact gas amount if refill needed). Note: profits are primarily recorded as `claimableOutputTokens` and used as a backup source for gas refill when necessary — they are not automatically siphoned into the gas tank unless a refill is required.

5) Manual Sell Now Override
  - Users may call `sellNow` to cancel the existing take-profit limit order, cancel all pending DCA buy orders, and immediately sell all accumulated output at market price instead of waiting for the limit price to be hit.
  - This also restarts the cycle with the sale proceeds.
  - Cancellation refunds remaining `gasTank` balance to the user.

This makes the lifecycle deterministic and easy to follow: initial swap → progressive buys (each buy creates the next level and updates TP) → TP hit (cancels pending buys, takes profit, restarts). Gas handling is automatic: initial 2x allocation, per-execution deduction, opportunistic refill from profits (2x for buys / exact for sells), contribution back to the tank when low, and stall/refund semantics when funds are exhausted.

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

- `function createDCAStrategy(PoolParams calldata pool, DCAParams calldata dca, uint32 slippage, uint256 expirationTime, uint256 gasTankAmount, uint32 gasTankPercent) external payable returns (uint256 dcaId)`
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

- `function getDCAInfo(uint256 dcaId) external view returns (address user, address currency0, address currency1, uint256 totalAmount, uint256 executedAmount, uint256 claimableAmount, bool isActive, bool isFullyExecuted, uint256 expirationTime, bool zeroForOne, uint256 totalLevels, uint24 currentFee)`
  - Returns common DCA metadata and execution state.

- `function getDCAInfoExtended(uint256 dcaId) external view returns (address user, address currency0, address currency1, uint256 totalAmount, uint256 executedAmount, uint256 claimableAmount, bool isActive, bool isFullyExecuted, uint256 expirationTime, bool zeroForOne, uint256 totalLevels, uint24 currentFee, uint256 gasTankAmount, uint256 gasTankPercent, bool isStalled)`
  - Extended view including gas tank and stall state.

- `function getDCAOrder(uint256 dcaId) external view returns (address user, address currency0, address currency1, uint256 totalAmount, uint256 executedAmount, uint256[] memory targetPrices, uint256[] memory targetAmounts, bool isActive, bool isFullyExecuted)`
  - Returns per-order target ticks/prices and amounts.

### Internal Gas / Execution Notes (for integrators)
- Estimated gas per DCA execution is used as a heuristic — the contract sets an approximate gas constant and checks/refills using this estimate. Integrators should expect the gas model to use approximations and rely on `getDCAInfoExtended` to inspect `gasTank` and `isStalled`.
- `claimableOutputTokens` are the canonical place where profits land after take-profit execution; they also serve as a backup refill source for the gas tank when the tank is low.

### Quick Examples (ABI usage)
- Create a DCA order (JS/ethers):
```js
const tx = await dcaBot.createDCAStrategy(poolParams, dcaParams, slippage, expiration, gasTankAmountInWei, gasTankPercent);
const receipt = await tx.wait();
// Parse DCAStrategyCreated event to obtain dcaId
```

- Read extended info:
```js
const info = await dcaBot.getDCAInfoExtended(dcaId);
console.log(info.gasTankAmount, info.isStalled);
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
- `gasTankAmount` (uint256) — initial ETH amount to fund the internal gas tank; the contract expects `gasTankAmount * 2` to be sent (pre-funded) via `msg.value` to ensure an initial buffer
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
- Poll `getDCAInfoExtended(dcaId)` periodically to show `gasTankAmount` and `isStalled` in UIs.
### Suggested integration checklist
- After creating an order, subscribe to `DCASwapExecuted` and `DCAStalled` for that `dcaId`.
- When a user cancels or redeems, listen for `BatchOrderCancelledOptimized` to confirm on-chain settlement.
  - When a user cancels an order, listen for `BatchOrderCancelledOptimized` to confirm on-chain settlement.

If you'd like, I can also:
- Add TypeScript/TypeChain interface snippets for these structs and events.
- Generate a small example script that creates a DCA order with realistic param values.


