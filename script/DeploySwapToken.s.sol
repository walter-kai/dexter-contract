// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SwapToken} from "../src/SwapToken.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeploySwapToken is Script {
    // Anvil default accounts (for local development)
    address constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant ANVIL_ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    
    function run() public {
        // ALL DEPLOYMENTS REQUIRE LEDGER AUTHENTICATION FOR SECURITY
        // Use the deploy-with-ledger.sh script for both mainnet and local deployments
        revert("Security: All deployments must use Ledger authentication. Use deploy-with-ledger.sh script.");
    }
}
