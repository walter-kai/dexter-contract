# Limit Order Types: Traditional vs Liquidity-Based

## Usage Examples

### Traditional Limit Orders (Short-term traders)

```solidity
// Create traditional limit orders - exact execution, no fee earning
uint256 batchId = limitOrderHook.createBatchOrder(
    ETH_ADDRESS,           // currency0
    USDC_ADDRESS,          // currency1  
    3000,                  // 0.3% fee tier
    false,                 // buying ETH with USDC
    [4000e6, 3800e6],     // target prices: $4000, $3800
    [1000e6, 1500e6],     // amounts: 1000 USDC, 1500 USDC
    block.timestamp + 1 days, // deadline
    false                  // Traditional limit orders
);

// Result:
// - 2500 USDC sits idle waiting for price triggers
// - When ETH drops to $4000, 1000 USDC buys ETH immediately
// - When ETH drops to $3800, 1500 USDC buys ETH immediately  
// - No fees earned while waiting
// - Exact price execution guaranteed
```

### Liquidity-Based Limit Orders (Long-term positions)

```solidity
// Create liquidity-based limit orders - earn fees while waiting
uint256 batchId = limitOrderHook.createBatchOrder(
    ETH_ADDRESS,           // currency0
    USDC_ADDRESS,          // currency1
    3000,                  // 0.3% fee tier
    false,                 // buying ETH with USDC
    [4000e6, 3800e6],     // target prices: $4000, $3800
    [1000e6, 1500e6],     // amounts: 1000 USDC, 1500 USDC
    block.timestamp + 30 days, // deadline
    true                   // Liquidity-based limit orders
);

// Result:
// - 2500 USDC becomes concentrated liquidity at target ticks
// - Earns 0.3% fees on all trades that cross those price levels
// - When ETH price reaches target levels, liquidity gets consumed
// - Capital is productive while waiting
// - Slight price range vs exact price (within one tick)
```

## Comparison Table

| Feature | Traditional Limit Orders | Liquidity-Based Limit Orders |
|---------|-------------------------|------------------------------|
| **Fee Earning** | ❌ No fees while waiting | ✅ Earn pool fees |
| **Price Precision** | ✅ Exact target price | ⚠️ Within one tick spacing |
| **Capital Efficiency** | ❌ Idle until execution | ✅ Productive immediately |
| **Gas Cost** | ✅ Lower (simple storage) | ⚠️ Higher (liquidity operations) |
| **Partial Fills** | ✅ All-or-nothing execution | ⚠️ May be partially consumed |
| **Best For** | Short-term trading | Long-term positions |
| **Pool Benefits** | ❌ No liquidity contribution | ✅ Helps pool liquidity |

## When to Use Each

### Use Traditional Limit Orders when:
- You need exact price execution
- You're trading short-term (hours/days)
- You want all-or-nothing fills
- Gas costs are a concern
- You don't want exposure to impermanent loss

### Use Liquidity-Based Limit Orders when:
- You're holding positions longer-term (weeks/months)  
- You want to earn fees while waiting
- You're okay with slight price variance (within tick spacing)
- You want to contribute to pool liquidity
- Capital efficiency is important

## Technical Implementation

### Traditional Flow:
1. Tokens stored in `pendingBatchOrders` mapping
2. `afterSwap` hook detects price movement
3. Executes orders via separate swaps
4. Mints claim tokens for proceeds

### Liquidity-Based Flow:
1. Tokens become concentrated liquidity via `modifyLiquidity`
2. Liquidity earns fees on trades crossing target ticks
3. When price moves through range, liquidity gets consumed
4. User receives output tokens + earned fees

Both approaches give users choice based on their trading strategy and time horizon!
