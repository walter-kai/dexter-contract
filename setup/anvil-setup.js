#!/usr/bin/env node

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// Set environment variables for consistent deployment
process.env.FEE_RECIPIENT_ADDRESS = '0x3Fef4207017024b01eFd67d3f4336df88F47A3F3';

console.log('🔧 Setting up Anvil development environment...\n');

// Function to run forge commands
function runForgeScript(scriptName, description) {
  try {
    console.log(`\n=== ${description} ===`);
    console.log(`Running: forge script ${scriptName} --rpc-url http://localhost:8545 --broadcast --ffi`);
    
    const output = execSync(
      `forge script ${scriptName} --rpc-url http://localhost:8545 --broadcast --ffi`,
      { 
        encoding: 'utf8',
        stdio: 'inherit',
        cwd: process.cwd()
      }
    );
    
    console.log(`✅ ${description} completed successfully!`);
    return output;
  } catch (error) {
    console.error(`❌ ${description} failed:`, error.message);
    process.exit(1);
  }
}

try {
  // Step 1: Setup Anvil wallets with USDC funding
  runForgeScript('script/SetupAnvilWallets.s.sol:SetupAnvilWallets', 'Step 1: Setup Anvil Wallets');
  
  // Step 2: Deploy hook contract with proper mining
  runForgeScript('script/DeployHookContract.s.sol:DeployHookContract', 'Step 2: Deploy Hook Contract');
  
  // Step 3: Initialize pool with hook contract address
  runForgeScript('script/InitializePool.s.sol:InitializePool', 'Step 3: Initialize Pool');
  
  console.log('\n🎉 Anvil setup completed successfully!');
  console.log('\n📋 Next steps:');
  console.log('   1. Your development environment is ready');
  console.log('   2. Hook contract deployed with proper mining');
  console.log('   3. Pool initialized with hook functionality');
  console.log('   4. Test accounts funded with USDC/WETH');
  
} catch (error) {
  console.error('\n❌ Setup failed:', error.message);
  console.error('\nPlease check that:');
  console.error('   1. Anvil is running on port 8545');
  console.error('   2. All required contracts are compiled');
  console.error('   3. No conflicting processes are running');
  process.exit(1);
}
