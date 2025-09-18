# DexterHook

**Automated DCA & Take-Profit Trading on Uniswap V4**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.26-363636?logo=solidity)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFFBF0.svg)](https://getfoundry.sh/)

DexterHook is an automated trading infrastructure that integrates directly with Uniswap V4 hooks to provide gas-efficient Dollar-Cost Averaging (DCA) and take-profit execution. By leveraging native AMM integration, it eliminates the need for external bots while ensuring optimal execution.

## Features

- **Automated DCA**: Progressive position building with configurable price triggers and exponential scaling
- **Take-Profit Automation**: Disciplined profit-taking with automatic position rebalancing  
- **Perpetual Compounding**: Seamless profit reinvestment for continuous strategy execution
- **Gas-Optimized Operations**: Built-in gas management with hook-native execution
- **Non-Custodial Architecture**: Complete user control over funds with on-chain execution guarantees

## Architecture

DexterHook implements Uniswap V4's hook interface to intercept and process swaps within the AMM's execution flow:

```
User Strategy → DexterHook Contract → Uniswap V4 Pool → Autonomous Execution
```

The hook architecture enables zero-latency execution within swap transactions, atomic order fulfillment, and minimal gas overhead through callback integration.

## Quick Start

### Basic DCA Strategy

```solidity
IDexterHook.PoolParams memory pool = IDexterHook.PoolParams({
    currency0: WETH,
    currency1: USDC,
    fee: 3000 // 0.3% fee tier
});

IDexterHook.DCAParams memory dca = IDexterHook.DCAParams({
    zeroForOne: true,              // Sell WETH for USDC
    takeProfitPercent: 2000,       // 20% profit target
    maxSwapOrders: 3,              // 3 DCA levels
    priceDeviationPercent: 500,    // 5% price intervals
    priceDeviationMultiplier: 20,  // 2x size scaling
    swapOrderAmount: 0.1 ether,    // Base order size
    swapOrderMultiplier: 20        // 2x exponential scaling
});

uint256 strategyId = dexterHook.createDCAStrategy{value: 1 ether}(
    pool,
    dca,
    100,                    // 1% max slippage
    block.timestamp + 30 days
);
```

### Strategy Examples

**Conservative Bitcoin Accumulation**
```solidity
// Steady accumulation with moderate scaling
takeProfitPercent: 2500,       // 25% profit target
maxSwapOrders: 4,              // 4 DCA levels
priceDeviationPercent: 300,    // 3% price intervals
priceDeviationMultiplier: 15,  // 1.5x size scaling
```

**Aggressive Momentum Trading**
```solidity
// High-frequency with aggressive scaling
takeProfitPercent: 1500,       // 15% profit target
maxSwapOrders: 5,              // 5 DCA levels
priceDeviationPercent: 800,    // 8% price intervals
priceDeviationMultiplier: 30,  // 3x size scaling
```

## Strategy Management

### Order Lifecycle

1. **Strategy Creation**: Deploy capital with defined parameters
2. **Initial Execution**: Immediate market buy at base amount
3. **DCA Progression**: Automated level triggering based on price action
4. **Take-Profit**: Automatic profit realization at target levels
5. **Compounding**: Profit reinvestment for perpetual execution

### Position Management

```solidity
// Cancel entire strategy and withdraw funds
dexterHook.cancelDCAStrategy(strategyId);

// Manual profit-taking at current market prices
dexterHook.sellNow(strategyId);

// Query strategy status and performance
(
    address user,
    address currency0,
    address currency1,
    uint256 totalAmount,
    uint256 executedAmount,
    uint256 claimableAmount,
    IDexterHook.OrderStatus status,
    bool isFullyExecuted
) = dexterHook.getDCAInfo(strategyId);
```

## Development Setup

### Prerequisites

- [Foundry](https://getfoundry.sh/) development framework
- [Node.js](https://nodejs.org/) v16+ for tooling
- Git for version control

### Installation

```bash
# Clone the repository
git clone https://github.com/DexterHook/DexterHook.git
cd DexterHook

# Install dependencies
forge install

# Compile contracts
forge build
```

### Testing

```bash
# Run complete test suite
forge test

# Generate gas usage reports
forge test --gas-report

# Coverage analysis
forge coverage
```

### Deployment

```bash
# Configure environment
cp .env.example .env
# Edit .env with your configuration

# Deploy to local testnet
anvil

# Deploy contracts (new terminal)
forge script script/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  --verify
```


## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<div align="center">

**Built by the DexterHook Team**

*Autonomous Trading Infrastructure for DeFi*

</div>