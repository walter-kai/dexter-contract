# Dexter Batch Limit Order Hook
Production-ready batch limit orders for Uniswap V4 (ABI & integration guide)

## Purpose of this document
This README focuses on the ABI-level types, hook/callback flow, and encoding examples that integrators and off-chain tooling need to interact with the `LimitOrderBatch` hook and the Uniswap V4 PoolManager. Test output and run logs have been intentionally removed — the repo contains separate tests under `test/`.

## Quick overview
Dexter implements a gas-optimized batch limit order hook for Uniswap V4. The contract uses Uniswap V4 core types and the PoolManager unlock/callback flow. Key on-chain interactions are expressed in canonical v4 types (see `lib/v4-core/src/interfaces/IPoolManager.sol`).

## Canonical ABI types (detailed)
Below are the exact ABI-level shapes and practical semantics used across the codebase.

- PoolKey (tuple)
    - Solidity shape: tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    - Notes: In v4 the `Currency` wrapper is used, but ABI-level encoding is the underlying address. Off-chain code must ensure address(currency0) < address(currency1) before creating a `PoolKey`.
    - PoolId: a bytes32 identifier computed from a `PoolKey` (library exposes `PoolKey.toId()` helpers). ABI consumers treat PoolId as `bytes32`.

- IPoolManager.SwapParams (struct)
    - Solidity shape: struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    - Semantics:
        - `amountSpecified < 0` => exactIn (caller provides input amount). The absolute value is the input token amount.
        - `amountSpecified > 0` => exactOut (caller requests output amount).
        - `sqrtPriceLimitX96` sets a price boundary for the swap (as Q64.96 sqrt price).

- IPoolManager.ModifyLiquidityParams (struct)
    - Solidity shape: struct ModifyLiquidityParams { int24 tickLower; int24 tickUpper; int256 liquidityDelta; bytes32 salt; }
    - Semantics: positive `liquidityDelta` adds liquidity, negative removes. `salt` distinguishes multiple positions with identical ranges.

- BalanceDelta (struct / representation)
    - ABI-level: pair of signed 128-bit integers: (int128 amount0, int128 amount1).
    - Role: represents the token deltas resulting from swaps, modifies, and settlements. Positive values mean tokens were added to the pool; negative values mean tokens were removed.

- BeforeSwapDelta / AfterSwap semantics
    - Hooks can return values (BeforeSwapDelta or other encoded returns) that the PoolManager interprets to adjust deltas during a swap. In this repo the hook returns `BeforeSwapDelta` instances to indicate how much of the swap should be consumed by on-chain limit order execution or hook-provided liquidity.

## Hook permissions and lifecycle (how PoolManager calls hooks)
- Permission discovery:
    - The PoolManager queries a hook contract for `Hooks.Permissions` flags (beforeInitialize, afterInitialize, beforeSwap, afterSwap, returnDelta flags, etc.) to determine which callbacks to call.

- Typical unlock/callback pattern for state-changing operations:
    1. An external actor (or the hook itself) calls `poolManager.unlock(bytes calldata data)` to begin an operation that requires atomic settlement.
 2. The PoolManager invokes `IUnlockCallback(msg.sender).unlockCallback(data)` on the caller contract. The hook executes logic (reading storage, moving tokens, emitting actions) and returns `bytes memory` to the PoolManager.
 3. The PoolManager continues / finalizes the underlying operation (swap, modifyLiquidity, settle) using the updated balances and any returned data.

## ABI encoding examples (off-chain)
Below are practical examples for off-chain encoding with ethers.js. Use the v4-core types when possible; manual ABI encoding is useful for low-level calls and testing.

- Encode a `PoolKey` and `SwapParams` into a single payload for `poolManager.unlock`:

```js
// Ethers.js pseudocode
const abi = new ethers.utils.AbiCoder();

const poolKeyTuple = [currency0Address, currency1Address, fee, tickSpacing, hookAddress];
const poolKeyEncoded = abi.encode(['tuple(address,address,uint24,int24,address)'], [poolKeyTuple]);

const swapParamsTuple = [zeroForOne, amountSpecified, sqrtPriceLimitX96];
const swapParamsEncoded = abi.encode(['tuple(bool,int256,uint160)'], [swapParamsTuple]);

// combine (concatenate) encodings or create a larger tuple depending on the target function signature
const payload = ethers.utils.concat([poolKeyEncoded, swapParamsEncoded]);
// call poolManager.unlock(payload)
```

Notes:
- If you interact with the Solidity `IPoolManager` functions directly from a contract (not off-chain), prefer using `IPoolManager.SwapParams` and `IPoolManager.ModifyLiquidityParams` datatypes in Solidity to avoid manual encoding errors.
- Use Uniswap v4 helper libraries (PoolKey.toId) when available to compute `PoolId` instead of reimplementing hash logic off-chain.

## Practical integration tips
- Always verify token ordering (currency0 < currency1 by address) before creating or signing a `PoolKey`.
- Use `IPoolManager.SwapParams` with `amountSpecified` sign conventions to avoid accidental exactOut/ exactIn mismatches.
- When returning deltas from hook callbacks, ensure values are within int128 ranges and match the pool's expected token denominations.
- Prefer `poolManager.unlock` + `unlockCallback` pattern for any on-chain action that requires atomic settlement.

## Development & quick commands
- Build: `forge build`
- Run tests: `forge test`

## License
MIT - see LICENSE
     3. The PoolManager then completes the underlying operation (modifyLiquidity, swap, settle, etc.) using the data returned by the hook.


