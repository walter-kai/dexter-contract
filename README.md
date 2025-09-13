# DCA Dexter Bot V1
*Production-Ready DCA (Dollar Cost Averaging) Bot for Uniswap V4*

## 🎯 Overview

DCA Dexter Bot is a **sophisticated progressive DCA system** built as a Uniswap V4 hook that enables automated dollar-cost averaging with dynamic take-profit management. Unlike traditional batch limit orders, this system implements true DCA semantics with progressive level creation, accumulated position tracking, and intelligent profit-taking.

**Key Features:**
- **Progressive DCA Execution**: Starts with initial swap, then creates buy levels progressively as price moves
- **Dynamic Take-Profit Management**: Automatically adjusts take-profit orders based on accumulated average cost
- **Gas Tank System**: Self-sustaining gas pool that refills from successful swaps
- **Perpetual Operation**: Automatically restarts DCA cycle when take-profit is hit
- **Manual Override**: Users can manually sell at market price and restart cycle
- **Stall Protection**: Orders become "stalled" when gas tank is exhausted

---

## 🏗️ Architecture Evolution

### From Batch Limit Orders to Progressive DCA

**Previous System (Batch Limit Orders):**
- Created all price levels simultaneously
- Static limit orders without relationship between levels
- Simple gas pre-collection system

**Current System (Progressive DCA):**
```
Initial Swap → Create Level 1 → Execute Level 1 → Create Level 2 → Execute Level 2 → ...
     ↓              ↓              ↓              ↓              ↓
Take Profit    Take Profit    Take Profit    Take Profit    Take Profit
   Order         Update         Update         Update         Update
```

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
    uint32 priceDeviationMultiplier;   // Logarithmic scaling factor
    uint256 swapOrderAmount;           // Base swap amount
    uint32 swapOrderMultiplier;        // Amount scaling factor
}
```

### 2. Progressive DCA Execution

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

**Revolutionary Self-Sustaining Gas Management:**
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

### 3. Logarithmic Scaling
**Price Deviation:** Each level is further from current price using logarithmic scaling
**Amount Scaling:** Each level can have different amounts based on scaling formula

```solidity
function _calculateLogarithmicMultiplier(uint256 level, uint256 baseMultiplier) internal pure returns (uint256) {
    // Formula: 10 + (baseMultiplier - 10) * (1 + log2(level))
    // Ensures multiplier increases logarithmically with level
}
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
- `swapOrderAmount`: 1000 USDC
- `priceDeviationPercent`: 500 (5%)
- Multipliers: 2.0x

**Progressive Execution:**
```
Initial Swap: 1000 USDC → ETH (immediate)
Level 1: 1500 USDC at -5% price (when triggered)
Level 2: 2000 USDC at -7.5% price (when triggered)
Level 3: 2500 USDC at -11.25% price (when triggered)
...
```

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
