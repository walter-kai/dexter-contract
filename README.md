# DCA Dexter Bot V1
*Production-Ready DCA (Dollar Cost Averaging) Bot for Uniswap V4*

## 🎯 Overview

DCA Dexter Bot is a **sophisticated progressive DCA system** built as a Uniswap V4 hook that enables automated dollar-cost averaging with dynamic take-profit management. This system implements true DCA strategies with progressive level creation, accumulated position tracking, and intelligent profit-taking.

**Key Features:**
- **Progressive DCA Execution**: Starts with initial swap, then creates buy levels progressively as price moves down
- **Dynamic Take-Profit Management**: Automatically adjusts take-profit orders based on accumulated average cost
- **Gas Tank System**: Self-sustaining gas pool that refills from successful swaps
- **Perpetual Operation**: Automatically restarts DCA cycle when take-profit is hit
- **Manual Sell Now**: Users can manually sell at market price and restart cycle
- **Manual Sell Now**: Users can manually sell at market price and restart cycle

---

## ⚠️ Gas Caveats

In order to create a bot that can operate in perpetuity, a sophisticated **Gas Tank system** was devised.

- **Stall Protection**: When a DCA order's gas tank is exhausted AND no claimable profits are available for automatic refill, the order becomes "stalled" and will not execute further automatic levels until manually topped up. This prevents failed executions but requires user intervention only when both gas tank and profit backup are depleted.

- **Gas Tank Economics**: 
  - **Automatic Refill**: Gas tank automatically refills from claimable profits when running low, serving as a backup mechanism
  - **Initial Allocation**: At order creation, 2x the gas amount is allocated to ensure sufficient gas for multiple swaps
  - **Smart Refill Logic**: 
    - For buy orders: Attempts to refill with 2x required gas (likely to swap again)
    - For sell orders: Refills with exact amount needed
    - Only triggers refill when tank is insufficient for execution
  - **Fallback**: If no claimable profits available for refill, order becomes stalled until manual intervention
  - **Efficiency**: Gas contribution from successful buys only happens when tank is running low (below 2x estimated gas cost)
  - Consider conservative `priceDeviationMultiplier` and reasonable `maxSwapOrders` to optimize gas usage


---

## 🏗️ Architecture Evolution

**Typical Bot Lifecycle:**

1) Initial swap (immediate upon creation)
  - Executes the base swap amount at market price.
  - Creates a TAKE-PROFIT SELL order sized to the accumulated output.
  - Creates the first BUY limit order at Level 1 deviation (first DCA level).
  - Gas: the contract allocates 2x the user-provided `gasTankAmount` at creation. This provides an execution buffer so the order can continue for at least one additional execution without immediate top-up.

2) Level 1 (first buy) triggers
  - When price reaches Level 1 tick, the buy executes.
  - The contract updates accumulated position and re-calculates the TAKE-PROFIT SELL order (cancels old TP and places an updated one sized to new accumulated output).
  - It then creates Level 2 (next buy) at the next deviation.
  - Gas: before executing the DCA buy the contract deducts an estimated gas amount from the `gasTank`. If the tank is below the estimated amount, the contract will first attempt an automatic refill from `claimableOutputTokens`:
    - For buy executions the refill attempts to allocate up to 2x the required gas from available profits (because another swap is likely to follow).
    - For sell (take-profit) executions the refill uses the exact required gas amount.
    - If available profits are insufficient to refill, the order is marked `isStalled` and will not execute further automatic levels until topped up.

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
    beforeSwap: true,        // Execute DCA orders during swaps
    afterSwap: true,         // Update pool state
    // All others: false
})
```

---

## 🔄 DCA Flow Explained

### 1. DCA Order Creation
```solidity
function createDCAOrder(
    PoolParams calldata pool,     // Pool configuration (currency0, currency1, fee)
    DCAParams calldata dca,       // DCA parameters (direction, amounts, levels, etc.)
    uint32 slippage,              // Slippage tolerance
    uint256 expirationTime,       // Order expiration
    uint256 gasTankAmount,        // Initial gas tank funding
    uint32 gasTankPercent         // % of each swap that refills gas tank
) external payable returns (uint256 dcaId)
```

**DCA Parameters:**
```solidity
struct DCAParams {
    bool zeroForOne;                    // Swap direction
    uint32 takeProfitPercent;          // Take profit % (0-50%)
    uint8 maxSwapOrders;               // Max DCA levels (1-10)
    uint32 priceDeviationPercent;      // Price deviation per level (0-20%)
    uint32 priceDeviationMultiplier;   // Amount scaling factor
    uint256 swapOrderAmount;           // Base swap amount
    uint32 swapOrderMultiplier;        // Amount scaling factor
}
```

### 2. DCA Execution Process

**Step 1: Initial Swap**
- Immediately executes swap at `swapOrderAmount`
- Accumulates output tokens
- Creates first take-profit order

**Step 2: Progressive Level Creation**
- Creates first DCA buy level below/above current price
- Each subsequent execution creates the next level
- Levels use logarithmic scaling for price and amount

**Step 3: Dynamic Take-Profit Management**
- Take-profit price adjusts based on accumulated average cost
- Cancels old take-profit orders when creating new ones
- Executes when price hits take-profit level

**Step 4: Restart Cycle**
- When take-profit is hit, cancels all pending orders
- Reinvests profits into new DCA cycle
- Process repeats perpetually

### 3. Gas Tank System

**Self-Sustaining Gas Management:**
```
User Provides Initial Gas Tank → Each Swap Contributes % → Gas Tank Refills
                ↓                        ↓                        ↓
    Execute DCA Level → Deduct Gas Cost → Check Tank Level → Stall if Empty
```

**Key Features:**
- Initial gas tank provided by user
- Each successful swap contributes percentage back to tank
- Orders become "stalled" (not "failed") when tank is empty
- Tank can be topped up to reactivate stalled orders

---

## 💡 Key Innovations

### 1. Progressive vs. Batch Creation
**Traditional Approach:**
```
Create Order: [Level1, Level2, Level3, Level4, Level5] // All at once
```

**DCA Dexter Approach:**
```
Create Order: [InitialSwap] → Execute → [Level1] → Execute → [Level2] → Execute → ...
```

### 2. Accumulated Position Tracking
```solidity
mapping(uint256 => uint256) public dcaAccumulatedInput;  // Total input accumulated
mapping(uint256 => uint256) public dcaAccumulatedOutput; // Total output accumulated
mapping(uint256 => uint256) public dcaCurrentLevel;     // Current DCA level
mapping(uint256 => int24) public dcaTakeProfitTick;     // Current take-profit price
```

### 3. Exponential Amount Scaling
**Price Deviation:** Each level is further from current price using simple linear scaling
**Amount Scaling:** Each level increases amount exponentially based on multiplier

```solidity
// Price deviation increases linearly with level
// Level 0 (initial): 0% deviation
// Level 1: priceDeviationPercent * 1
// Level 2: priceDeviationPercent * 2
// Level 3: priceDeviationPercent * 3
// etc.

// Amount scaling increases exponentially
// If priceDeviationMultiplier = 20 (2.0x):
// Level 1: baseAmount * 2^1 = baseAmount * 2
// Level 2: baseAmount * 2^2 = baseAmount * 4  
// Level 3: baseAmount * 2^3 = baseAmount * 8
// Level 4: baseAmount * 2^4 = baseAmount * 16
// etc.
```

### 4. Smart Take-Profit Adjustment
- Calculates average cost basis from accumulated positions
- Adjusts take-profit price based on `takeProfitPercent`
- Dynamically updates as more positions are accumulated

---

## 🔧 Usage Examples

### Basic DCA Order Creation

```solidity
// Example: DCA buy ETH with USDC over 5 levels
IDCADexterBotV1.PoolParams memory pool = IDCADexterBotV1.PoolParams({
    currency0: address(USDC),
    currency1: address(WETH),
    fee: 3000  // 0.3%
});

IDCADexterBotV1.DCAParams memory dca = IDCADexterBotV1.DCAParams({
    zeroForOne: true,              // USDC → WETH
    takeProfitPercent: 1000,       // 10% take profit
    maxSwapOrders: 5,              // 5 DCA levels max
    priceDeviationPercent: 500,    // 5% price deviation per level
    priceDeviationMultiplier: 20,  // 2.0x logarithmic scaling
    swapOrderAmount: 1000e6,       // 1000 USDC base amount
    swapOrderMultiplier: 15        // 1.5x amount scaling
});

// Create DCA order with 0.01 ETH gas tank, 2% contribution rate
uint256 dcaId = dcaBot.createDCAOrder{value: 0.01 ether}(
    pool,
    dca,
    100,                    // 1% slippage
    block.timestamp + 7 days, // 1 week expiration
    0.01 ether,            // Gas tank amount
    200                    // 2% gas tank contribution
);
```

### Advanced Features

```solidity
// Manual sell at market price
dcaBot.manualSell(dcaId);

// Cancel entire DCA order (refunds tokens + gas tank)
dcaBot.cancelDCAOrder(dcaId);

// Redeem accumulated profits
dcaBot.redeemProfits(dcaId, claimTokenAmount);

// Check DCA status
(address user, address currency0, address currency1, uint256 totalAmount,
 uint256 executedAmount, uint256 claimableAmount, bool isActive, bool isFullyExecuted,
 uint256 expirationTime, bool zeroForOne, uint256 totalBatches, uint24 currentFee,
 uint256 gasTankAmount, uint32 gasTankPercent, bool isStalled) = 
    dcaBot.getDCAInfoExtended(dcaId);
```

---

## 📊 Technical Specifications

### Contract Details

| Metric | Value |
|--------|-------|
| **Contract Size** | 23.97KB |
| **Size Margin** | 605 bytes (under 24.576KB limit) |
| **Test Coverage** | Production ready |
| **Hook Permissions** | 4 hooks implemented |

### Gas Tank Economics

| Action | Gas Tank Impact |
|--------|-----------------|
| **Create DCA Order** | User provides initial tank |
| **Execute DCA Level** | Deducts ~50,000 gas equivalent |
| **Successful Swap** | Contributes `gasTankPercent` back |
| **Manual Sell** | Uses existing tank |
| **Cancel Order** | Refunds remaining tank |

### DCA Level Progression Example

**Base Parameters:**
- `swapOrderAmount`: 1000 USDC (base amount)
- `priceDeviationPercent`: 500 (5%)
- `priceDeviationMultiplier`: 20 (2.0x)
- Current ETH price: $3000

**Exponential Scaling Formulas:**
```solidity
// Price deviation for level N (linear)
priceDeviation = priceDeviationPercent * level / 10000
levelPrice = currentPrice * (1 - priceDeviation)  // for buy orders

// Amount for level N (exponential)
amountMultiplier = multiplier^level  // where multiplier = priceDeviationMultiplier/10
levelAmount = baseAmount * amountMultiplier
```

**Progressive Execution:**
```
Initial Swap: 1000 USDC → ETH at $3000 (immediate, 0% deviation)

Level 1: at $2850 (-5% price)
  - Price deviation: 5% * 1 = 5%
  - Amount: 1000 * 2^1 = 1000 * 2 = 2000 USDC

Level 2: at $2700 (-10% price) 
  - Price deviation: 5% * 2 = 10%
  - Amount: 1000 * 2^2 = 1000 * 4 = 4000 USDC

Level 3: at $2550 (-15% price)
  - Price deviation: 5% * 3 = 15% 
  - Amount: 1000 * 2^3 = 1000 * 8 = 8000 USDC

Level 4: at $2400 (-20% price)
  - Price deviation: 5% * 4 = 20%
  - Amount: 1000 * 2^4 = 1000 * 16 = 16000 USDC
```

**Take-Profit Calculation:**
After initial + Level 1 execution:
- Total ETH: (1000/3000) + (2000/2850) ≈ 0.333 + 0.702 = 1.035 ETH
- Total cost: 1000 + 2000 = 3000 USDC  
- Average cost: 3000 / 1.035 ≈ $2899
- Take-profit (10%): $2899 * 1.10 ≈ $3189

---

## 🔒 Security & Production Readiness

### Input Validation
- Take profit percentage: 0-50%
- Max swap orders: 1-10 levels
- Price deviation: 0-20%
- Gas tank percentage: 0-10%
- Comprehensive parameter validation

### Economic Security
- Gas tank system prevents failed executions
- Stalled state instead of failed state
- User-controlled gas tank contributions
- Automatic refunds on cancellation

### Access Control
- User-only cancellation and manual sell
- Owner restrictions on critical functions
- Pool manager-only hook execution

### Error Handling
```solidity
error InsufficientGasTank();
error OrderStalled();
error InvalidTakeProfitPercent();
error InvalidMaxSwapOrders();
error InvalidPriceDeviation();
```

---

## 🚀 Current Status

**Production Readiness:** ✅ Production-ready and fully functional

**Contract Status:**
- ✅ Compiles successfully with no errors
- ✅ All DCA flow implemented and tested
- ✅ Gas tank system fully operational
- ✅ Progressive level creation working
- ✅ Take-profit management functional
- ✅ Manual sell and restart cycle operational

**Key Features Implemented:**
- ✅ Progressive DCA execution
- ✅ Dynamic take-profit adjustment
- ✅ Gas tank self-sustaining system
- ✅ Stall protection mechanism
- ✅ Manual sell functionality
- ✅ Perpetual restart capability
- ✅ ERC-6909 claim token system

**Next Steps:**
1. Security audit
2. Advanced testing scenarios
3. Frontend integration
4. Mainnet deployment

---

## 🔄 DCA vs Traditional Limit Orders

| Feature | Traditional Limit Orders | DCA Dexter Bot |
|---------|-------------------------|----------------|
| **Order Creation** | All levels at once | Progressive creation |
| **Execution** | Independent orders | Linked DCA progression |
| **Take Profit** | Static separate orders | Dynamic adjustment |
| **Gas Management** | Pre-collection only | Self-sustaining tank |
| **Position Tracking** | None | Accumulated cost basis |
| **Restart Logic** | Manual only | Automatic perpetual |
| **Failure Handling** | Orders fail | Orders stall |

---

## 📝 License

MIT License - see [LICENSE](./LICENSE) for details.

---

## 🔍 Understanding the Innovation

DCA Dexter Bot represents a paradigm shift from static batch limit orders to intelligent, progressive DCA execution. The system mimics how sophisticated traders actually perform DCA - starting with an initial position, adding to it as price moves favorably, adjusting take-profit levels based on average cost, and automatically reinvesting profits.

The gas tank system ensures sustainability without requiring users to monitor and refund failed transactions. Instead of failing when gas runs out, orders simply pause ("stall") until the tank is replenished by successful swaps or manual top-ups.

This creates a truly "set-and-forget" DCA experience that can run perpetually with minimal user intervention.
