#!/usr/bin/env node

/**
 * Sync deployed pools to Firebase after pool initialization
 * This script reads the deployed pools from the blockchain and writes them to Firebase
 */

const { ethers } = require('ethers');
const admin = require('firebase-admin');
const path = require('path');

// Load environment variables from both contract and server directories
require('dotenv').config(); // Load from current directory

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


// Firebase initialization
if (!admin.apps.length) {
    // Use individual environment variables instead of JSON service account
    const serviceAccount = {
        type: "service_account",
        project_id: process.env.FIREBASE_PROJECT_ID,
        private_key_id: process.env.FIREBASE_PRIVATE_KEY_ID,
        private_key: process.env.FIREBASE_PRIVATE_KEY?.replace(/\\n/g, '\n'),
        client_email: process.env.FIREBASE_CLIENT_EMAIL,
        client_id: process.env.FIREBASE_CLIENT_ID,
        auth_uri: "https://accounts.google.com/o/oauth2/auth",
        token_uri: "https://oauth2.googleapis.com/token",
        auth_provider_x509_cert_url: "https://www.googleapis.com/oauth2/v1/certs",
        client_x509_cert_url: process.env.FIREBASE_CLIENT_X509_CERT_URL
    };
    
    admin.initializeApp({
        credential: admin.credential.cert(serviceAccount),
        projectId: process.env.FIREBASE_PROJECT_ID || 'dexter-city-de124'
    });
}

const db = admin.firestore();

// Pool configurations matching InitializePool.s.sol
const POOL_CONFIGS = [
    {
        currency0: "0x0000000000000000000000000000000000000000", // ETH
        currency1: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // USDC
    fee: 0xF00000, // DYNAMIC_FEE_FLAG
    tickSpacing: 10,
        pairName: "ETH/USDC",
        sqrtPriceX96: "1871430318305059074410128097500"
    },
    {
        currency0: "0x0000000000000000000000000000000000000000", // ETH
        currency1: "0xdAC17F958D2ee523a2206206994597C13D831ec7", // USDT
    fee: 0xF00000,
    tickSpacing: 10,
        pairName: "ETH/USDT",
        sqrtPriceX96: "1871430318305059074410128097500"
    },
    {
        currency0: "0x0000000000000000000000000000000000000000", // ETH
        currency1: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", // WBTC
        fee: 0xF00000,
        tickSpacing: 60,
        pairName: "ETH/WBTC",
        sqrtPriceX96: "198433000000000000000000" // ~27 ETH per WBTC
    },
    {
        currency0: "0x0000000000000000000000000000000000000000", // ETH
        currency1: "0x514910771AF9Ca656af840dff83E8264EcF986CA", // LINK
        fee: 0xF00000,
        tickSpacing: 60,
        pairName: "ETH/LINK",
        sqrtPriceX96: "31622776601683793319988935444" // ~160 LINK per ETH
    },
    {
        currency0: "0x0000000000000000000000000000000000000000", // ETH
        currency1: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984", // UNI
        fee: 0xF00000,
        tickSpacing: 60,
        pairName: "ETH/UNI",
        sqrtPriceX96: "177827941003892492739851029760" // ~315 UNI per ETH
    },
    {
        currency0: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // USDC
        currency1: "0xdAC17F958D2ee523a2206206994597C13D831ec7", // USDT
        fee: 0xF00000,
    tickSpacing: 10,
        pairName: "USDC/USDT",
        sqrtPriceX96: "79228162514264337593543950336" // 1:1
    }
];

function generatePoolId(currency0, currency1, fee, tickSpacing, hookAddress) {
    // Generate pool ID as per Uniswap V4 specification
    const poolKey = ethers.utils.defaultAbiCoder.encode(
        ['address', 'address', 'uint24', 'int24', 'address'],
        [currency0, currency1, fee, tickSpacing, hookAddress]
    );
    return ethers.utils.keccak256(poolKey);
}

async function getPoolStatus(provider, poolManagerAddress, poolId) {
    try {
        // Simple call to check if pool is initialized
        const poolManagerAbi = [
            "function getLiquidity(bytes32 poolId) external view returns (uint128)",
            "function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint16 protocolFee, uint24 lpFee)"
        ];
        
        const poolManager = new ethers.Contract(poolManagerAddress, poolManagerAbi, provider);
        
        const [liquidity, slot0] = await Promise.all([
            poolManager.getLiquidity(poolId).catch(() => 0),
            poolManager.getSlot0(poolId).catch(() => ({ sqrtPriceX96: 0, tick: 0, protocolFee: 0, lpFee: 0 }))
        ]);
        
        return {
            isInitialized: slot0.sqrtPriceX96 > 0,
            liquidity: liquidity.toString(),
            sqrtPriceX96: slot0.sqrtPriceX96.toString(),
            tick: slot0.tick,
            lpFee: slot0.lpFee
        };
    } catch (error) {
        console.log(`❌ Error checking pool ${poolId}: ${error.message}`);
        log('RED', `❌ Error checking pool ${poolId}: ${error.message}`);
        return {
            isInitialized: false,
            liquidity: "0",
            sqrtPriceX96: "0",
            tick: 0,
            lpFee: 0
        };
    }
}

async function syncPoolsToFirebase() {
    log('BLUE', '🔄 Syncing deployed pools to Firebase...');
    
    const network = process.argv[2] || 'anvil';
    let rpcUrl;
    let poolManagerAddress;
    let hookAddress;
    
    // Network configuration
    switch (network) {
        case 'mainnet':
            rpcUrl = process.env.MAINNET_RPC_URL;
            poolManagerAddress = process.env.POOL_MANAGER_ADDRESS;
            hookAddress = process.env.LIMIT_ORDER_BATCH_ADDRESS;
            break;
        case 'sepolia':
            rpcUrl = process.env.SEPOLIA_RPC_URL;
            poolManagerAddress = process.env.POOL_MANAGER_ADDRESS;
            hookAddress = process.env.LIMIT_ORDER_BATCH_ADDRESS;
            break;
        case 'anvil':
        default:
            rpcUrl = 'http://localhost:8545';
            poolManagerAddress = '0x000000000004444c5dc75cB358380D2e3dE08A90';
            hookAddress = '0x9FbE77AE175211529F90337940EE05Ba39Efb0c0';
            break;
    }
    
    if (!rpcUrl) {
        console.error('❌ RPC URL not configured for network:', network);
        process.exit(1);
    }
    
    console.log(`🌐 Network: ${network}`);
    console.log(`🔗 RPC URL: ${rpcUrl}`);
    console.log(`📋 Pool Manager: ${poolManagerAddress}`);
    console.log(`🪝 Hook Address: ${hookAddress}`);
    
    const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    
    let syncedCount = 0;
    let skippedCount = 0;
    
    for (const config of POOL_CONFIGS) {
        try {
            const poolId = generatePoolId(
                config.currency0,
                config.currency1,
                config.fee,
                config.tickSpacing,
                hookAddress
            );
            
            console.log(`\n🏊 Processing ${config.pairName}...`);
            console.log(`   Pool ID: ${poolId}`);
            
            // Check pool status on-chain
            const poolStatus = await getPoolStatus(provider, poolManagerAddress, poolId);
            
            if (!poolStatus.isInitialized) {
                console.log(`   ⚠️  Pool not initialized on-chain, skipping`);
                skippedCount++;
                continue;
            }
            
            // Prepare Firebase document
            const poolDoc = {
                pool_id: poolId,
                currency0: config.currency0,
                currency1: config.currency1,
                fee: config.fee,
                tick_spacing: config.tickSpacing,
                pair_name: config.pairName,
                is_initialized: true,
                liquidity: poolStatus.liquidity,
                sqrt_price_x96: poolStatus.sqrtPriceX96,
                current_tick: poolStatus.tick,
                lp_fee: poolStatus.lpFee,
                network: network,
                hook_address: hookAddress,
                pool_manager_address: poolManagerAddress,
                created_at: admin.firestore.FieldValue.serverTimestamp(),
                updated_at: admin.firestore.FieldValue.serverTimestamp()
            };
            
            // Write to Firebase
            await db.collection('pools').doc(poolId).set(poolDoc, { merge: true });
            
            console.log(`   ✅ Synced to Firebase`);
            console.log(`   📊 Liquidity: ${poolStatus.liquidity}`);
            console.log(`   💰 Price: ${poolStatus.sqrtPriceX96}`);
            
            syncedCount++;
            
        } catch (error) {
            console.error(`   ❌ Error syncing ${config.pairName}: ${error.message}`);
        }
    }
    
    console.log(`\n🎉 Sync complete!`);
    console.log(`   ✅ Synced: ${syncedCount} pools`);
    console.log(`   ⚠️  Skipped: ${skippedCount} pools`);
    console.log(`   📦 Total processed: ${POOL_CONFIGS.length} pools`);
    
    if (syncedCount > 0) {
        console.log(`\n💡 Pools are now available in the server API`);
        console.log(`   Test with: curl http://localhost:8000/pools`);
    }
}

// Run the sync
if (require.main === module) {
    syncPoolsToFirebase()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error('❌ Sync failed:', error);
            process.exit(1);
        });
}

module.exports = { syncPoolsToFirebase };
