# Dexter Contract Setup Scripts

This directory contains JavaScript-based setup scripts for the Dexter contract project. All shell scripts have been converted to JavaScript for better maintainability and cross-platform compatibility.

## Available Scripts

### Core NPM Commands

```bash
# Start local Anvil node
npm run anvil

# Setup Anvil environment (fund accounts, initialize currencies)
npm run anvil:setup

# Deploy contracts to Anvil using unlocked accounts
npm run anvil:contract

# Deploy contracts to mainnet using Ledger
npm run main:contract

# Create individual pools on mainnet using Ledger (interactive)
npm run main:pool
```

## Script Files

### 1. `anvil-setup.js`
**Purpose**: Sets up the Anvil development environment
**Used by**: `npm run anvil:setup`

**Features**:
- ✅ Checks if Anvil is running
- ✅ Funds accounts with 1M USDC each
- ✅ Updates .env file with contract addresses
- ✅ Provides clear status feedback with colors

**Usage**:
```bash
node setup/anvil-setup.js
```

### 2. `deploy-with-ledger.js`
**Purpose**: Secure contract deployment with Ledger support
**Used by**: `npm run anvil:contract`, `npm run main:contract`

**Features**:
- ✅ Supports mainnet, sepolia, anvil, and custom networks
- ✅ Ledger hardware wallet integration for mainnet/testnet
- ✅ Unlocked accounts for Anvil development
- ✅ Automatic contract verification on Etherscan
- ✅ Safety checks and confirmation prompts
- ✅ Clear deployment status and next steps

**Usage**:
```bash
# Deploy to Anvil (uses unlocked accounts)
node setup/deploy-with-ledger.js script/DeployCore.s.sol:DeployCore anvil

# Deploy to mainnet (uses Ledger)
node setup/deploy-with-ledger.js script/DeployCore.s.sol:DeployCore mainnet --verify

# Deploy to Sepolia (uses Ledger)
node setup/deploy-with-ledger.js script/DeployCore.s.sol:DeployCore sepolia
```

**Networks Supported**:
- `mainnet` - Ethereum mainnet (requires MAINNET_RPC_URL)
- `sepolia` - Sepolia testnet (requires ALCHEMY_API_KEY)
- `anvil` - Local Anvil node (http://localhost:8545)
- `custom` - Custom RPC (requires RPC_URL)

### 3. `create-single-pool.js`
**Purpose**: Interactive pool creation with Ledger support
**Used by**: `npm run main:pool`

**Features**:
- ✅ Interactive token selection (ETH default for Token 0)
- ✅ Fee tier selection (0.01%, 0.05%, 0.30%, 1.00%, Dynamic)
- ✅ Automatic token ordering (lower address first)
- ✅ Ledger integration for secure transactions
- ✅ Temporary Solidity script generation
- ✅ Automatic cleanup after deployment

**Usage**:
```bash
# Create pool on mainnet (interactive with Ledger)
node setup/create-single-pool.js mainnet

# Create pool on Anvil (uses unlocked accounts)
node setup/create-single-pool.js anvil
```

**Available Tokens**:
1. ETH (0x0000000000000000000000000000000000000000)
2. WETH (0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
3. USDC (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
4. USDT (0xdAC17F958D2ee523a2206206994597C13D831ec7)
5. WBTC (0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599)
6. LINK (0x514910771AF9Ca656af840dff83E8264EcF986CA)
7. UNI (0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984)

### 4. `sync-pools-to-firebase.js`
**Purpose**: Syncs deployed pools to Firebase for server API
**Used by**: Various deployment scripts

**Features**:
- ✅ Reads pool configurations from blockchain
- ✅ Validates pool initialization status
- ✅ Syncs pool data to Firebase Firestore
- ✅ Supports multiple networks
- ✅ Colored output for better readability

**Usage**:
```bash
# Sync pools for mainnet
node setup/sync-pools-to-firebase.js mainnet

# Sync pools for Anvil
node setup/sync-pools-to-firebase.js anvil
```

## Development Workflow

### 1. Initial Setup (First Time)
```bash
# Start Anvil in one terminal
npm run anvil

# In another terminal, setup the environment
npm run anvil:setup

# Deploy contracts
npm run anvil:contract
```

### 2. Adding Individual Pools
```bash
# For development (Anvil)
node setup/create-single-pool.js anvil

# For mainnet (requires Ledger)
npm run main:pool
```

### 3. Mainnet Deployment
```bash
# Deploy core contracts (requires Ledger)
npm run main:contract

# Create pools individually (requires Ledger)
npm run main:pool
```

## Environment Variables

The scripts use these environment variables from `.env`:

```bash
# Network URLs
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
ALCHEMY_API_KEY=your_alchemy_api_key

# Contract Verification
ETHERSCAN_API_KEY=your_etherscan_api_key

# Firebase (for pool syncing)
FIREBASE_PROJECT_ID=your_project_id
FIREBASE_PRIVATE_KEY=your_private_key
FIREBASE_CLIENT_EMAIL=your_client_email
# ... other Firebase configs
```

## Security Features

### Ledger Integration
- ✅ Hardware wallet support for mainnet/testnet
- ✅ Transaction verification on device
- ✅ Blind signing warnings and recommendations
- ✅ Clear security checklists before deployment

### Safety Checks
- ✅ Network connectivity verification
- ✅ Anvil running status check
- ✅ Mainnet deployment warnings
- ✅ Confirmation prompts for destructive actions

### Development vs Production
- **Anvil**: Uses unlocked accounts for fast development
- **Mainnet/Testnet**: Requires Ledger for secure deployment
- **Environment separation**: Clear distinction between networks

## Troubleshooting

### Common Issues

**"Anvil is not running"**
```bash
# Start Anvil first
npm run anvil
```

**"Ledger device not found"**
- Connect Ledger device
- Unlock with PIN
- Open Ethereum app
- Close Ledger Live

**"Contract verification failed"**
- Check ETHERSCAN_API_KEY in .env
- Ensure network is supported for verification

**"Pool creation failed"**
- Pool might already exist
- Check gas fees and balances
- Verify network connectivity

### Getting Help

Each script provides detailed error messages and next steps. For additional help:

1. Check the console output for specific error messages
2. Verify environment variables in `.env`
3. Ensure required dependencies are installed
4. Check network connectivity and node status

## Migration from Shell Scripts

The following shell scripts have been converted to JavaScript:

- ❌ `test/anvil-setup.sh` → ✅ `setup/anvil-setup.js`
- ❌ `test/anvil-setup-simple.sh` → ✅ `setup/anvil-setup.js`
- ❌ `test/create-pool.sh` → ✅ `setup/create-single-pool.js`
- ❌ `deploy/deploy-with-ledger.sh` → ✅ `setup/deploy-with-ledger.js`
- ❌ `anvil-setup.sh` → ✅ `setup/anvil-setup.js`

All functionality has been preserved and enhanced with better error handling, colored output, and improved user experience.
