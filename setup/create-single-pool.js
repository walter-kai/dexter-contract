#!/usr/bin/env node

/**
 * Single Pool Initialization Script
 * Allows initialization of individual pools with Ledger support
 */

const { exec, spawn } = require('child_process');
const { promisify } = require('util');
const fs = require('fs');
const path = require('path');
const readline = require('readline');

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

// Available tokens
const TOKENS = {
    1: { name: 'ETH', address: '0x0000000000000000000000000000000000000000' },
    2: { name: 'WETH', address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' },
    3: { name: 'USDC', address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48' },
    4: { name: 'USDT', address: '0xdAC17F958D2ee523a2206206994597C13D831ec7' },
    5: { name: 'WBTC', address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599' },
    6: { name: 'LINK', address: '0x514910771AF9Ca656af840dff83E8264EcF986CA' },
    7: { name: 'UNI', address: '0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984' }
};

// Available fees
const FEES = {
    1: { description: '0.01% (100)', value: 100 },
    2: { description: '0.05% (500)', value: 500 },
    3: { description: '0.30% (3000)', value: 3000 },
    4: { description: '1.00% (10000)', value: 10000 },
    5: { description: 'Dynamic (0xF00000)', value: '0xF00000' }
};

function createReadlineInterface() {
    return readline.createInterface({
        input: process.stdin,
        output: process.stdout
    });
}

async function promptUser(question) {
    const rl = createReadlineInterface();
    return new Promise((resolve) => {
        rl.question(question, (answer) => {
            rl.close();
            resolve(answer.trim());
        });
    });
}

function displayTokens() {
    console.log('');
    log('BLUE', 'Available Tokens:');
    log('BLUE', '=================');
    Object.entries(TOKENS).forEach(([key, token]) => {
        console.log(`   ${colors.YELLOW}${key}${colors.NC}. ${colors.GREEN}${token.name}${colors.NC} (${token.address.substring(0, 10)}...)`);
    });
}

function displayFees() {
    console.log('');
    log('BLUE', 'Available Fees:');
    log('BLUE', '==============');
    Object.entries(FEES).forEach(([key, fee]) => {
        console.log(`   ${colors.YELLOW}${key}${colors.NC}. ${colors.GREEN}${fee.description}${colors.NC}`);
    });
}

async function getTokenSelection(prompt, defaultToken = null) {
    let token0Choice;
    
    if (defaultToken) {
        const useDefault = await promptUser(`Use ${defaultToken} as ${prompt}? (Y/n): `);
        if (useDefault.toLowerCase() !== 'n') {
            // Find the token number for the default
            const tokenEntry = Object.entries(TOKENS).find(([_, token]) => token.name === defaultToken);
            if (tokenEntry) {
                return { choice: tokenEntry[0], token: tokenEntry[1] };
            }
        }
    }
    
    while (true) {
        token0Choice = await promptUser(`Select ${prompt} (1-7): `);
        if (/^[1-7]$/.test(token0Choice) && TOKENS[token0Choice]) {
            return { choice: token0Choice, token: TOKENS[token0Choice] };
        }
        log('RED', 'Invalid choice. Please select 1-7.');
    }
}

async function getFeeSelection() {
    while (true) {
        const feeChoice = await promptUser('Select Fee Tier (1-5): ');
        if (/^[1-5]$/.test(feeChoice) && FEES[feeChoice]) {
            return { choice: feeChoice, fee: FEES[feeChoice] };
        }
        log('RED', 'Invalid choice. Please select 1-5.');
    }
}

function ensureProperOrdering(token0, token1) {
    // Ensure proper ordering (lower address first)
    if (token0.address.toLowerCase() > token1.address.toLowerCase()) {
        return { token0: token1, token1: token0 };
    }
    return { token0, token1 };
}

async function createPoolScript(token0, token1, fee) {
    const scriptName = `CreatePool_${token0.name}_${token1.name}_${fee.value}.s.sol`;
    const scriptPath = path.join('script', scriptName);
    
    const scriptContent = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract CreatePool_${token0.name}_${token1.name}_${fee.value} is Script {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    
    function run() external {
        vm.startBroadcast();
        
        console2.log("=== Creating Pool: ${token0.name}/${token1.name} ===");
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(${token0.address}),
            currency1: Currency.wrap(${token1.address}),
            fee: ${fee.value},
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        console2.log("Token 0:", ${token0.address});
        console2.log("Token 1:", ${token1.address});
        console2.log("Fee:", ${fee.value});
        
        // Calculate initial price (1:1 ratio at tick 0)
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // sqrt(1) * 2^96
        
        try POOL_MANAGER.initialize(key, sqrtPriceX96, new bytes(0)) {
            PoolId poolId = key.toId();
            console2.log("✅ Pool created successfully!");
            console2.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
        } catch Error(string memory reason) {
            console2.log("❌ Pool creation failed:", reason);
        } catch (bytes memory lowLevelData) {
            console2.log("❌ Pool creation failed with low-level error");
        }
        
        vm.stopBroadcast();
    }
}`;

    fs.writeFileSync(scriptPath, scriptContent);
    return { scriptPath, scriptName };
}

async function runPoolCreation(scriptPath, network = 'mainnet') {
    const deployScript = path.join(__dirname, 'deploy-with-ledger.js');
    
    return new Promise((resolve, reject) => {
        const child = spawn('node', [deployScript, scriptPath, network], {
            stdio: 'inherit',
            env: { ...process.env }
        });
        
        child.on('close', (code) => {
            if (code === 0) {
                log('GREEN', '✅ Pool creation completed');
                resolve();
            } else {
                log('YELLOW', '⚠️  Pool creation may have failed (could already exist)');
                resolve(); // Don't fail entirely as pool might already exist
            }
        });
    });
}

async function main() {
    const network = process.argv[2] || 'mainnet';
    
    console.log('🏊 Create Individual Pool');
    console.log('========================');
    
    displayTokens();
    displayFees();
    
    console.log('');
    log('YELLOW', 'Create a new pool by selecting tokens and fee:');
    
    // Get Token 0 (with ETH as default)
    const { token: token0 } = await getTokenSelection('Token 0', 'ETH');
    
    // Get Token 1
    console.log('');
    const { choice: token1Choice, token: token1Raw } = await getTokenSelection('Token 1');
    
    // Check for same token
    if (token0.name === token1Raw.name) {
        log('RED', '❌ Cannot create pool with the same token. Exiting.');
        process.exit(1);
    }
    
    // Get Fee
    console.log('');
    const { fee } = await getFeeSelection();
    
    // Ensure proper ordering
    const { token0: orderedToken0, token1: orderedToken1 } = ensureProperOrdering(token0, token1Raw);
    
    console.log('');
    log('GREEN', '📋 Pool Configuration:');
    log('GREEN', '======================');
    log('BLUE', `Token 0: ${colors.GREEN}${orderedToken0.name}${colors.NC} (${orderedToken0.address})`);
    log('BLUE', `Token 1: ${colors.GREEN}${orderedToken1.name}${colors.NC} (${orderedToken1.address})`);
    log('BLUE', `Fee:     ${colors.GREEN}${fee.description}${colors.NC}`);
    log('BLUE', `Network: ${colors.GREEN}${network}${colors.NC}`);
    log('GREEN', '======================');
    
    console.log('');
    const confirm = await promptUser('Create this pool? (y/N): ');
    if (!/^[Yy]$/.test(confirm)) {
        console.log('Pool creation cancelled.');
        process.exit(0);
    }
    
    console.log('');
    log('BLUE', `Creating pool ${orderedToken0.name}/${orderedToken1.name}...`);
    
    try {
        // Create temporary Solidity script
        const { scriptPath, scriptName } = await createPoolScript(orderedToken0, orderedToken1, fee);
        
        // Run the pool creation
        await runPoolCreation(`${scriptPath}:CreatePool_${orderedToken0.name}_${orderedToken1.name}_${fee.value}`, network);
        
        // Clean up the temporary script
        fs.unlinkSync(scriptPath);
        
        console.log('');
        log('GREEN', '🎉 Pool Creation Process Complete!');
        log('BLUE', `Pool: ${colors.GREEN}${orderedToken0.name}/${orderedToken1.name}${colors.NC} with fee ${colors.GREEN}${fee.description}${colors.NC}`);
        console.log('');
        log('YELLOW', 'You can now use this pool in your batch orders!');
        
    } catch (error) {
        log('RED', `❌ Pool creation failed: ${error.message}`);
        process.exit(1);
    }
}

if (require.main === module) {
    main().catch((error) => {
        log('RED', `❌ Script failed: ${error.message}`);
        process.exit(1);
    });
}

module.exports = { main };
