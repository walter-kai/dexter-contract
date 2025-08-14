#!/bin/bash

# Ledger Deployment Script for Dexter Contracts
# This script deploys contracts using Ledger hardware wallet instead of private keys
# Supports both mainnet and testnet deployments with proper safety checks

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if required arguments are provided
if [ "$#" -lt 2 ]; then
    echo -e "${RED}Usage: $0 <script_path> <network> [additional_args]${NC}"
    echo -e "${BLUE}Examples:${NC}"
    echo "  $0 script/DeploySwapToken.s.sol:DeploySwapToken mainnet --verify"
    echo "  $0 script/DeployBatch.s.sol:DeployBatch sepolia"
    echo "  $0 script/DeploySwapToken.s.sol:DeploySwapToken anvil"
    echo ""
    echo -e "${BLUE}Supported networks:${NC}"
    echo "  - mainnet     (Ethereum mainnet - requires RPC_URL)"
    echo "  - sepolia     (Sepolia testnet)"
    echo "  - anvil       (Local Anvil node)"
    echo "  - custom      (Custom RPC - requires RPC_URL env var)"
    exit 1
fi

SCRIPT_PATH=$1
NETWORK=$2
shift 2  # Remove first two arguments
ADDITIONAL_ARGS="$@"  # Capture remaining arguments

# Load environment variables
source .env 2>/dev/null || echo "Warning: .env file not found"

# Network configuration
case $NETWORK in
    "mainnet")
        RPC_URL="${MAINNET_RPC_URL}"
        CHAIN_ID=1
        if [ -z "$RPC_URL" ]; then
            echo -e "${RED}❌ MAINNET_RPC_URL not set in .env file${NC}"
            exit 1
        fi
        ;;
    "sepolia")
        RPC_URL="https://eth-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
        CHAIN_ID=11155111
        if [ -z "$ALCHEMY_API_KEY" ]; then
            echo -e "${RED}❌ ALCHEMY_API_KEY not set for Sepolia${NC}"
            exit 1
        fi
        ;;
    "anvil")
        RPC_URL="http://localhost:8545"
        CHAIN_ID=1  # Anvil forks from mainnet, so uses chain ID 1
        echo -e "${YELLOW}⚠️ Anvil mode: Using forked mainnet (chain ID 1) - make sure anvil is running${NC}"
        ;;
    "custom")
        if [ -z "$RPC_URL" ]; then
            echo -e "${RED}❌ RPC_URL not set for custom network${NC}"
            exit 1
        fi
        CHAIN_ID="auto-detect"
        ;;
    *)
        echo -e "${RED}❌ Unknown network: $NETWORK${NC}"
        exit 1
        ;;
esac

echo -e "${BLUE}🔐 Preparing Ledger deployment...${NC}"
echo -e "${BLUE}📜 Script: $SCRIPT_PATH${NC}"
echo -e "${BLUE}🌐 Network: $NETWORK${NC}"
echo -e "${BLUE}🔗 RPC URL: $RPC_URL${NC}"
echo -e "${BLUE}⛓️ Chain ID: $CHAIN_ID${NC}"
echo -e "${BLUE}📋 Additional args: $ADDITIONAL_ARGS${NC}"

# Safety checks for mainnet
if [ "$NETWORK" = "mainnet" ]; then
    echo ""
    echo -e "${RED}⚠️  MAINNET DEPLOYMENT WARNING ⚠️${NC}"
    echo -e "${RED}You are about to deploy to Ethereum mainnet!${NC}"
    echo -e "${RED}This will use REAL ETH and incur actual costs.${NC}"
    echo ""
    echo -e "${YELLOW}Please confirm:${NC}"
    echo "1. Your Ledger device is connected and unlocked"
    echo "2. The Ethereum app is open on your Ledger"
    echo "3. You have reviewed the deployment script"
    echo "4. You have sufficient ETH for gas fees"
    echo ""
    # read -p "Do you want to continue with MAINNET deployment? (type 'YES' to continue): " confirm
    # if [ "$confirm" != "YES" ]; then
    #     echo -e "${YELLOW}Deployment cancelled by user${NC}"
    #     exit 0
    # fi
fi

echo ""
if [ "$NETWORK" = "anvil" ]; then
    echo -e "${YELLOW}📋 Anvil + Ledger deployment checklist:${NC}"
    echo "1. Ensure Anvil is running: npm run anvil"
    echo "2. Connect your Ledger device"
    echo "3. Unlock your Ledger with PIN"
    echo "4. Open the Ethereum app on your Ledger"
    echo "5. Close Ledger Live if it's running"
    echo ""
    echo -e "${BLUE}🔒 SECURITY: Even for local development, we use Ledger authentication${NC}"
    echo "   This ensures consistent security practices across all environments"
    echo ""
else
    echo -e "${YELLOW}📋 Ledger deployment checklist:${NC}"
    echo "1. Connect your Ledger device"
    echo "2. Unlock your Ledger with PIN"
    echo "3. Open the Ethereum app on your Ledger"
    echo "4. Close Ledger Live if it's running"
    echo "5. Make sure no other app is using the Ledger"
    echo ""
    echo -e "${BLUE}🔒 SECURITY SETTINGS:${NC}"
    echo "   📱 Ensure blind signing is DISABLED (recommended for security)"
    echo "   📋 Allow contract data if deploying contracts"
    echo "   🔐 With blind signing disabled, you'll see full transaction details"
    echo "      on your Ledger screen for verification before signing"
    echo ""
fi

echo ""
read -p "Press ENTER when ready to continue (or Ctrl+C to cancel)..."

echo ""
echo -e "${GREEN}🚀 Starting deployment with Ledger...${NC}"

# Build forge command - use unlocked accounts for Anvil, Ledger for others
if [ "$NETWORK" = "anvil" ]; then
    # For Anvil, use unlocked accounts instead of private keys with explicit sender
    FORGE_CMD="forge script $SCRIPT_PATH --rpc-url $RPC_URL --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    echo -e "${BLUE}🔓 Using unlocked accounts for Anvil deployment${NC}"
else
    # For mainnet/testnet, use Ledger
    FORGE_CMD="forge script $SCRIPT_PATH --rpc-url $RPC_URL --broadcast --ledger"
    echo -e "${BLUE}🔐 Using Ledger for secure deployment${NC}"
fi

# Add verification for mainnet and testnets
if [[ "$ADDITIONAL_ARGS" == *"--verify"* ]] || [ "$NETWORK" = "mainnet" ] || [ "$NETWORK" = "sepolia" ]; then
    if [ ! -z "$ETHERSCAN_API_KEY" ]; then
        FORGE_CMD="$FORGE_CMD --verify --etherscan-api-key $ETHERSCAN_API_KEY"
        echo -e "${BLUE}📝 Contract verification enabled${NC}"
    else
        echo -e "${YELLOW}⚠️ ETHERSCAN_API_KEY not set - skipping verification${NC}"
    fi
fi

# Add any additional arguments (excluding --verify if already handled)
FILTERED_ARGS=$(echo "$ADDITIONAL_ARGS" | sed 's/--verify//g')
if [ ! -z "$FILTERED_ARGS" ]; then
    FORGE_CMD="$FORGE_CMD $FILTERED_ARGS"
fi

echo -e "${BLUE}🔧 Executing: $FORGE_CMD${NC}"
echo ""

# Execute the deployment
if eval $FORGE_CMD; then
    echo ""
    echo -e "${GREEN}✅ Deployment completed successfully!${NC}"
    echo -e "${GREEN}🎉 Contracts deployed using Ledger hardware wallet${NC}"
    
    if [ "$NETWORK" = "mainnet" ]; then
        echo -e "${GREEN}🔍 Check deployment on Etherscan: https://etherscan.io${NC}"
    elif [ "$NETWORK" = "sepolia" ]; then
        echo -e "${GREEN}🔍 Check deployment on Sepolia: https://sepolia.etherscan.io${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}📋 Next steps:${NC}"
    echo "1. Verify contract addresses in the deployment output"
    echo "2. Update your .env files with new addresses"
    echo "3. Test the contracts with small amounts first"
    echo "4. Update your frontend/CLI configuration"
    
else
    echo ""
    echo -e "${RED}❌ Deployment failed!${NC}"
    echo -e "${YELLOW}💡 Common issues:${NC}"
    echo "   - Ledger device not connected or unlocked"
    echo "   - Ethereum app not open on Ledger"
    echo "   - Transaction rejected on device"
    echo "   - Insufficient gas or ETH balance"
    echo "   - Network connectivity issues"
    echo "   - Ledger Live interfering (make sure it's closed)"
    exit 1
fi
