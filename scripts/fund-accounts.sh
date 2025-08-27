#!/bin/bash

# USDC and whale addresses
USDC_ADDRESS="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
WHALE_ADDRESS="0x5414d89a8bF7E99d732BC52f3e6A3Ef461c0C078"

# Anvil accounts to fund
ACCOUNTS=(
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
    "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
    "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"
)

# Amount to fund each account (100,000 USDC = 100,000 * 10^6)
AMOUNT="100000000000"

echo "=== Funding Anvil Accounts with USDC ==="
echo "Whale: $WHALE_ADDRESS"
echo "USDC Contract: $USDC_ADDRESS"
echo "Amount per account: 100,000 USDC"
echo ""

# Check whale balance first
echo "Checking whale balance..."
cast call $USDC_ADDRESS "balanceOf(address)(uint256)" $WHALE_ADDRESS --rpc-url http://localhost:8545

echo ""
echo "Funding accounts..."

# Fund each account
for i in "${!ACCOUNTS[@]}"; do
    account="${ACCOUNTS[$i]}"
    echo "Funding account $((i+1)): $account"
    
    # Use cast send with --from to impersonate the whale
    cast send $USDC_ADDRESS "transfer(address,uint256)(bool)" $account $AMOUNT \
        --from $WHALE_ADDRESS \
        --rpc-url http://localhost:8545 \
        --unlocked
        
    if [ $? -eq 0 ]; then
        echo "✅ Account $((i+1)) funded successfully"
    else
        echo "❌ Failed to fund account $((i+1))"
    fi
    
    # Check the account balance
    balance=$(cast call $USDC_ADDRESS "balanceOf(address)(uint256)" $account --rpc-url http://localhost:8545)
    # Remove scientific notation and extract just the number
    balance_clean=$(echo $balance | awk '{print $1}')
    echo "   Balance: $balance_clean wei"
    echo ""
done

echo "=== Funding complete ==="
