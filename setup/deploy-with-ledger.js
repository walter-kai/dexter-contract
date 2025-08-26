#!/usr/bin/env node

/**
 * Ledger Deployment Script for Dexter Contracts
 * JavaScript version of deploy-with-ledger.sh
 */

const { exec, spawn } = require('child_process');
const { promisify } = require('util');
const fs = require('fs');
const path = require('path');

require('dotenv').config();

const execAsync = promisify(exec);

// Colors for output
const colors = {
    RED: '\x1b[31m',
    GREEN: '\x1b[32m',
    YELLOW: '\x1b[33m',
    BLUE: '\x1b[34m',
    NC: '\x1b[0m' // No Color
};

function log(color, message) {
    console.log(`${colors[color]}${message}${colors.NC}`);
}

function validateArgs() {
    const args = process.argv.slice(2);
    if (args.length < 2) {
        log('RED', 'Usage: node setup/deploy-with-ledger.js <script_path> <network> [additional_args]');
        log('BLUE', 'Examples:');
        console.log('  node setup/deploy-with-ledger.js script/DeployCore.s.sol:DeployCore mainnet --verify');
        console.log('  node setup/deploy-with-ledger.js script/DeployCore.s.sol:DeployCore sepolia');
        console.log('  node setup/deploy-with-ledger.js script/DeployCore.s.sol:DeployCore anvil');
        console.log('');
        log('BLUE', 'Supported networks:');
        console.log('  - mainnet     (Ethereum mainnet - requires RPC_URL)');
        console.log('  - sepolia     (Sepolia testnet)');
        console.log('  - anvil       (Local Anvil node)');
        console.log('  - custom      (Custom RPC - requires RPC_URL env var)');
        process.exit(1);
    }
    
    return {
        scriptPath: args[0],
        network: args[1],
        additionalArgs: args.slice(2)
    };
}

function getNetworkConfig(network) {
    const config = {
        rpcUrl: null,
        chainId: null
    };
    
    switch (network) {
        case 'mainnet':
            config.rpcUrl = process.env.MAINNET_RPC_URL;
            config.chainId = 1;
            if (!config.rpcUrl) {
                log('RED', '❌ MAINNET_RPC_URL not set in .env file');
                process.exit(1);
            }
            break;
        case 'sepolia':
            config.rpcUrl = `https://eth-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`;
            config.chainId = 11155111;
            if (!process.env.ALCHEMY_API_KEY) {
                log('RED', '❌ ALCHEMY_API_KEY not set for Sepolia');
                process.exit(1);
            }
            break;
        case 'anvil':
            config.rpcUrl = 'http://localhost:8545';
            config.chainId = 1;
            log('YELLOW', '⚠️ Anvil mode: Using forked mainnet (chain ID 1) - make sure anvil is running');
            break;
        case 'custom':
            config.rpcUrl = process.env.RPC_URL;
            config.chainId = 'auto-detect';
            if (!config.rpcUrl) {
                log('RED', '❌ RPC_URL not set for custom network');
                process.exit(1);
            }
            break;
        default:
            log('RED', `❌ Unknown network: ${network}`);
            process.exit(1);
    }
    
    return config;
}

async function checkAnvilRunning() {
    try {
        const { stdout } = await execAsync('curl -s -X POST -H "Content-Type: application/json" --data \'{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}\' http://localhost:8545');
        return true;
    } catch (error) {
        return false;
    }
}

function buildForgeCommand(scriptPath, network, config, additionalArgs) {
    let forgeCmd;
    
    if (network === 'anvil') {
        // For Anvil, use unlocked accounts
        forgeCmd = `forge script ${scriptPath} --rpc-url ${config.rpcUrl} --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`;
        log('BLUE', '🔓 Using unlocked accounts for Anvil deployment');
    } else {
        // For mainnet/testnet, use Ledger
        forgeCmd = `forge script ${scriptPath} --rpc-url ${config.rpcUrl} --broadcast --ledger`;
        log('BLUE', '🔐 Using Ledger for secure deployment');
    }
    
    // Add verification for mainnet and testnets
    const needsVerification = additionalArgs.includes('--verify') || network === 'mainnet' || network === 'sepolia';
    if (needsVerification && process.env.ETHERSCAN_API_KEY) {
        forgeCmd += ` --verify --etherscan-api-key ${process.env.ETHERSCAN_API_KEY}`;
        log('BLUE', '📝 Contract verification enabled');
    } else if (needsVerification) {
        log('YELLOW', '⚠️ ETHERSCAN_API_KEY not set - skipping verification');
    }
    
    // Add additional arguments (excluding --verify if already handled)
    const filteredArgs = additionalArgs.filter(arg => arg !== '--verify');
    if (filteredArgs.length > 0) {
        forgeCmd += ` ${filteredArgs.join(' ')}`;
    }
    
    return forgeCmd;
}

async function promptUser(message) {
    return new Promise((resolve) => {
        process.stdout.write(message);
        process.stdin.once('data', (data) => {
            resolve(data.toString().trim());
        });
    });
}

async function executeDeployment(forgeCmd, network) {
    return new Promise((resolve, reject) => {
        log('BLUE', `🔧 Executing: ${forgeCmd}`);
        console.log('');
        
        const child = spawn('bash', ['-c', forgeCmd], {
            stdio: 'inherit',
            env: { ...process.env }
        });
        
        child.on('close', (code) => {
            if (code === 0) {
                console.log('');
                log('GREEN', '✅ Deployment completed successfully!');
                log('GREEN', '🎉 Contracts deployed using secure authentication');
                
                if (network === 'mainnet') {
                    log('GREEN', '🔍 Check deployment on Etherscan: https://etherscan.io');
                } else if (network === 'sepolia') {
                    log('GREEN', '🔍 Check deployment on Sepolia: https://sepolia.etherscan.io');
                }
                
                console.log('');
                log('BLUE', '📋 Next steps:');
                console.log('1. Verify contract addresses in the deployment output');
                console.log('2. Update your .env files with new addresses');
                console.log('3. Test the contracts with small amounts first');
                console.log('4. Update your frontend/CLI configuration');
                
                resolve();
            } else {
                console.log('');
                log('RED', '❌ Deployment failed!');
                log('YELLOW', '💡 Common issues:');
                console.log('   - Ledger device not connected or unlocked');
                console.log('   - Ethereum app not open on Ledger');
                console.log('   - Transaction rejected on device');
                console.log('   - Insufficient gas or ETH balance');
                console.log('   - Network connectivity issues');
                console.log('   - Ledger Live interfering (make sure it\'s closed)');
                reject(new Error(`Deployment failed with exit code ${code}`));
            }
        });
    });
}

async function main() {
    const { scriptPath, network, additionalArgs } = validateArgs();
    const config = getNetworkConfig(network);
    
    log('BLUE', '🔐 Preparing deployment...');
    log('BLUE', `📜 Script: ${scriptPath}`);
    log('BLUE', `🌐 Network: ${network}`);
    log('BLUE', `🔗 RPC URL: ${config.rpcUrl}`);
    log('BLUE', `⛓️ Chain ID: ${config.chainId}`);
    log('BLUE', `📋 Additional args: ${additionalArgs.join(' ')}`);
    
    // Check Anvil for local deployment
    if (network === 'anvil') {
        const isAnvilRunning = await checkAnvilRunning();
        if (!isAnvilRunning) {
            log('RED', '❌ Anvil is not running! Please start it first with: npm run anvil');
            process.exit(1);
        }
        log('GREEN', '✅ Anvil is running');
    }
    
    // Safety checks for mainnet
    if (network === 'mainnet') {
        console.log('');
        log('RED', '⚠️  MAINNET DEPLOYMENT WARNING ⚠️');
        log('RED', 'You are about to deploy to Ethereum mainnet!');
        log('RED', 'This will use REAL ETH and incur actual costs.');
        console.log('');
    }
    
    // Display deployment checklist
    console.log('');
    if (network === 'anvil') {
        log('YELLOW', '📋 Anvil deployment checklist:');
        console.log('1. Ensure Anvil is running: npm run anvil');
        console.log('2. Contracts will be deployed using unlocked accounts');
        console.log('');
        log('BLUE', '🔒 SECURITY: Using unlocked accounts for local development');
    } else {
        log('YELLOW', '📋 Ledger deployment checklist:');
        console.log('1. Connect your Ledger device');
        console.log('2. Unlock your Ledger with PIN');
        console.log('3. Open the Ethereum app on your Ledger');
        console.log('4. Close Ledger Live if it\'s running');
        console.log('5. Make sure no other app is using the Ledger');
        console.log('');
        log('BLUE', '🔒 SECURITY SETTINGS:');
        console.log('   📱 Ensure blind signing is DISABLED (recommended for security)');
        console.log('   📋 Allow contract data if deploying contracts');
        console.log('   🔐 With blind signing disabled, you\'ll see full transaction details');
        console.log('      on your Ledger screen for verification before signing');
    }
    
    console.log('');
    await promptUser('Press ENTER when ready to continue (or Ctrl+C to cancel)...');
    
    console.log('');
    log('GREEN', '🚀 Starting deployment...');
    
    const forgeCmd = buildForgeCommand(scriptPath, network, config, additionalArgs);
    
    try {
        await executeDeployment(forgeCmd, network);
    } catch (error) {
        process.exit(1);
    }
}

// Make stdin readable for prompts
if (require.main === module) {
    process.stdin.setRawMode(false);
    process.stdin.resume();
    process.stdin.setEncoding('utf8');
    
    main().catch((error) => {
        log('RED', `❌ Script failed: ${error.message}`);
        process.exit(1);
    });
}

module.exports = { main };
