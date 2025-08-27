#!/usr/bin/env node

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// Set environment variables for consistent deployment
process.env.FEE_RECIPIENT_ADDRESS = '0x3Fef4207017024b01eFd67d3f4336df88F47A3F3';

console.log('🔧 Setting up Anvil development environment...\n');

// Function to run forge commands and capture output
function runForgeScript(scriptName, description) {
  try {
    console.log(`\n=== ${description} ===`);
    console.log(`Running: forge script ${scriptName} --rpc-url http://localhost:8545 --broadcast --ffi`);
    
    const output = execSync(
      `forge script ${scriptName} --rpc-url http://localhost:8545 --broadcast --ffi`,
      { 
        encoding: 'utf8',
        stdio: 'pipe',
        cwd: process.cwd()
      }
    );
    
    console.log(output);
    console.log(`✅ ${description} completed successfully!`);
    return output;
  } catch (error) {
    console.error(`❌ ${description} failed:`, error.message);
    if (error.stdout) {
      console.error('STDOUT:', error.stdout);
    }
    process.exit(1);
  }
}

// Function to extract addresses from script output
function extractAndSetEnvAddress(output, pattern, envVarName) {
  const match = output.match(pattern);
  if (match) {
    const address = match[1];
    process.env[envVarName] = address;
    console.log(`Set ${envVarName}=${address}`);
    return address;
  }
  return null;
}

try {
  // Step 1: Setup Anvil wallets with USDC funding
  const walletOutput = runForgeScript('script/SetupAnvilWallets.s.sol:SetupAnvilWallets', 'Step 1: Setup Anvil Wallets');
  
  // Extract USDC and WETH addresses from wallet setup
  extractAndSetEnvAddress(walletOutput, /USDC_ADDRESS[=\s]+([0-9a-fA-Fx]+)/, 'USDC_ADDRESS');
  extractAndSetEnvAddress(walletOutput, /WETH_ADDRESS[=\s]+([0-9a-fA-Fx]+)/, 'WETH_ADDRESS');
  
  // Step 2: Deploy hook contract with proper mining
  const deployOutput = runForgeScript('script/DeployHookContract.s.sol:DeployHookContract', 'Step 2: Deploy Hook Contract');
  
  // Extract hook address from deployment output
  const hookAddress = extractAndSetEnvAddress(deployOutput, /LIMIT_ORDER_BATCH_ADDRESS[=\s]+([0-9a-fA-Fx]+)/, 'LIMIT_ORDER_BATCH_ADDRESS');
  
  // Step 3: Initialize pool with hook contract address
  const poolOutput = runForgeScript('script/InitializePool.s.sol:InitializePool', 'Step 3: Initialize Pool');
  
  // Extract pool ID
  extractAndSetEnvAddress(poolOutput, /POOL_ID[=\s]+([0-9a-fA-Fx]+)/, 'POOL_ID');
  
  console.log('\n🎉 Anvil setup completed successfully!');
  console.log('\n📋 Deployed addresses:');
  console.log(`   Hook Contract: ${process.env.LIMIT_ORDER_BATCH_ADDRESS || 'Not found'}`);
  console.log(`   USDC: ${process.env.USDC_ADDRESS || 'Not found'}`);
  console.log(`   WETH: ${process.env.WETH_ADDRESS || 'Not found'}`);
  console.log(`   Pool ID: ${process.env.POOL_ID || 'Not found'}`);
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
