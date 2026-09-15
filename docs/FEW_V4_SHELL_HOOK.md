# FewToken v4 Shell Pool

> Updated: 2026-09-01
> Status: The review package has been organized. The Hook is deployed on Ethereum mainnet, but has not been audited and has not been confirmed to be automatically discovered by Uniswap routing.

## Overview

`FewV4ShellHook` exposes a designated hookless FewToken v4 `lpPool` as an origin-token `shellPool` for `A/B`. Users and generic v4 routers see the `A -> B` shell pool, while the actual swap execution and LP fee occur in the existing FewToken v4 `lpPool`.

```text
A/B shellPool (tracked by the Hook)
  -> take A from PoolManager
  -> A.wrap() -> fwA
  -> allowlisted hookless fwA/fwB v4 lpPool swap
  -> fwB.unwrap() -> B
  -> settle B to PoolManager
```

This design does not require duplicating A/B liquidity and does not use the existing `A/fwA` or `B/fwB` 1:1 wrapper pools for execution. The wrapper pools are held by the same PoolManager, and their physical origin-token balances can support the Hook's atomic `take` before the router's final settlement. After the router completes settlement, the balance returns to its previous value. If the required inventory is unavailable, the quote and swap both revert.

## Fixed Design

| Item | V1 choice |
|---|---|
| Liquidity source | One exact `lpPool` PoolId from the constructor-approved route configuration or FewFactory inference |
| `lpPool` key | Canonical FewToken pair, hookless, static fee, initialized, and currently holding active liquidity |
| `shellPool` | Uses the shell pool's fee and tick spacing; the shell pool is not the swap execution venue |
| Route input | The caller cannot provide an arbitrary target, `PoolKey`, or non-empty `hookData` |
| Execution | Both exact-in and exact-out swaps must fill completely; a one-wei shortfall reverts the entire transaction |
| Price limit | V1 accepts only the canonical v4 extreme limits; reversed token order uses strict reciprocal rounding |
| Wrap / unwrap | Return values and actual balance changes are checked; approvals are reset after each operation |
| Administration | No proxy, pause, fee setter, or sweep capability. The owner is a single transferable owner whose business permission is to register or remove an explicit `lpPool` mapping |
| Additional fees | None; users only pay the existing LP/protocol fee of the `lpPool` |
| Native ETH | The `shellPool` can use native ETH; the Hook performs the atomic conversion through WETH/FewWETH |

The Hook permission mask is `0x2088`:

- `beforeInitialize`
- `beforeSwap`
- `beforeSwapReturnDelta`

The current version does not enable `beforeAddLiquidity`. Liquidity for the `shellPool` is handled normally by v4 core, and the Hook does not perform an owner check on the add-liquidity path. Registration and removal of an explicit `lpPool` are protected by `LpOwner.onlyOwner`.

The shell pool's liquidity acts as inventory rather than as an execution venue. `beforeSwapReturnDelta` consumes the complete requested amount, so `Pool.swap` receives zero and returns a zero delta. Consequently, shell-pool liquidity never participates in the swap and does not earn swap fees. Its purpose is to keep physical origin-token inventory in the PoolManager for the atomic `take` before wrapping. Liquidity removal is not checked by the Hook (`beforeRemoveLiquidity` remains disabled); v4 still restricts removal to the position holder. `beforeDonate` is also disabled, so v4 core rejects donations when the shell pool has no liquidity.

`beforeSwapReturnDelta` must be enabled for the `shellPool` to be fully settled through the `lpPool`. Therefore, this design does not satisfy the manual-review condition that all four return-delta flags are false, and it must not be described as bypassing Uniswap review.

## Quoting and Discovery Boundaries

The Hook implements the generic `IAggregatorHook` ABI:

- `quote(bool,int256,PoolId)` uses the official `V4Quoter` to simulate the complete shell-pool route rather than calculating only the `lpPool` swap. PoolManager physical inventory, wrapping, unwrapping, and the full-fill check are all included in the quote.
- `pseudoTotalValueLocked(PoolId)` returns a virtual-depth proxy based on the current active liquidity of the `lpPool`. It is not withdrawable TVL and is not the global token balance held by the PoolManager.
- `AggregatorPoolRegistered` and `HookSwap` are retained as generic indexing events.

These interfaces and the standard `PoolKey` are sufficient for a generic v4 quoter to execute the pool, but they do not mean that 0x, Uniswap, or another solver will automatically discover and include it in its candidate set. Post-deployment validation must inspect real API quote responses and confirm that the route contains the shell PoolId or Hook address. A successful transaction and aggregator discovery are separate states.

## Verification Coverage

Local integration tests using a real PoolManager cover:

- Both aligned and reversed wrapper-address ordering;
- Exact-in and exact-out swaps in both directions;
- Wei-level agreement between Hook quotes, direct `lpPool` quotes, and executed swaps;
- Shell-pool liquidity remaining unchanged, the shell-pool `slot0` remaining unchanged, and the `lpPool` `slot0` moving;
- Liquidity operations through arbitrary non-PositionManager routers and PositionManager positions held by non-owners reverting with `LiquidityNotAllowed`; owner positions can be added and fully removed, while swaps continue to execute through the `lpPool`;
- All four Hook ERC-20 balances and transient deltas returning to zero;
- Existing origin/FewToken wrapper-pool `slot0` and liquidity remaining unchanged;
- PoolManager physical origin-token inventory returning to its prior value after router settlement;
- Partial fills, insufficient inventory, non-extreme price limits, non-empty `hookData`, malicious wrapper reentrancy, and false return values all reverting atomically.

At Ethereum mainnet fixed block `25,833,244`, the fork tests also verified:

- The real `fwUSDC/fwUSDT` `lpPool` with PoolId `0x6199c1a871328a693bbc9cd80a7e4874a4a7e2ebc862b51fa04bb6b587dbac47`;
- The wrapper pools `fwUSDC/USDC` and `USDT/fwUSDT`;
- Four bidirectional USDC/USDT exact-in and exact-out quote/execution cases;
- Both wrapper pools retaining their `slot0` and liquidity;
- The real PositionManager `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` plus Permit2: owner minting succeeds, non-owner minting reverts with `LiquidityNotAllowed`, and `BURN_POSITION` fully removes the position. The fork test supports `FORK_BLOCK=0` to follow the RPC head for reruns against a local Anvil mainnet fork.

These results demonstrate contract execution and accounting at the fixed block only. They do not establish current liquidity, deployment safety, or aggregator discovery.

## Deployment Sequence

This section should only be followed after an independent security audit and confirmation of the official routing integration process.

1. Audit `src/FewV4ShellHook.sol`; do not reuse audit conclusions from the existing FewV2 Hook.
2. Rerun fork tests, inventory checks, and quote matrices for all target sizes at the target block.
3. Use `script/MineFewV4ShellHookAddress.s.sol` to inspect the `lpPool` and generate the salt/address for the current init code.
4. Manually verify the factory, quoter, PoolManager, `lpPool` PoolId, fee, tick spacing, and Hook permission mask.
5. Deploy the Hook with `script/DeployFewV4ShellHookWithOwner.s.sol`, setting the owner through `HOOK_OWNER` during the same deployment flow. This script does not initialize the `shellPool`. The owner/LP must initialize the target PoolKey and provide the required inventory separately; begin with a single USDC/USDT pair.
6. Verify the source, then perform read-only bidirectional validation across multiple trade sizes using the Universal Router and the production 0x quote API.
7. Only change the status to “considered by the aggregator” when the API response clearly includes the Hook route. Only change it to “receiving flow” after observing a real transaction.

The CREATE2 address is bound to the complete init code, including Solidity metadata. Address mining and deployment must use exactly the same Foundry, Solc, optimizer, `bytecode_hash`, and source. Any change requires mining a new salt. With Foundry 1.5.1, if the default script execution reports `No contract bytecode`, use `FOUNDRY_BYTECODE_HASH=bzzr1 --force` for both the address-mining and deployment dry-run steps; applying it to only one step is insufficient.

Stop conditions: any residual delta or balance, an accepted partial fill, a non-strict 1:1 wrapper, a mutable `lpPool` PoolId, insufficient PoolManager origin inventory, a mismatch between quote and execution, or a production solver failing to return the route must prevent the deployment from proceeding to the funding phase.
