# Architecture

Updated: 2026-10-03

## Purpose

FewToken liquidity can be useful without asking an origin-token user to wrap or unwrap manually. A Shell Pool exposes the origin pair in Uniswap; every accepted swap is converted and executed in one owner-approved FewToken LP.

The Hook uses Uniswap v4 custom accounting. It returns the complete Shell swap delta from `beforeSwap`, so the Shell Pool price curve and LP fee are not used. The FewToken LP is the only execution venue.

## Swap flow

1. The router starts a swap in an origin-token Shell Pool.
2. The Hook resolves the Shell PoolId to one explicitly registered FewToken LP.
3. The Hook executes the nested FewToken LP swap first. PoolManager's flash accounting records the resulting input debt and output credit; physical settlement follows within the same transaction.
4. The Hook takes the required origin input from PoolManager.
5. `wrapTo` mints the input FewToken directly to PoolManager and settles the input debt.
6. The Hook takes the output FewToken, then `unwrapTo` sends the origin output directly to PoolManager. Native ETH uses WETH as the wrapper underlying and is withdrawn before settlement.
7. The Hook returns the full input/output delta. The Shell Pool price remains unchanged; the FewToken LP price moves normally.

## Route rules

| Item | Rule |
|---|---|
| Shell Pool | Static-fee origin-token v4 pool using this Hook |
| Shell Pool | Initialized by the owner so a third party cannot preempt the permanent metadata price |
| FewToken LP | Explicitly registered by the owner for that Shell PoolId |
| Wrappers | Both must be the canonical wrappers returned by the configured FewFactory |
| LP Hook | Allowed only if it does not use `beforeSwapReturnDelta` or `afterSwapReturnDelta` |
| Liquidity | The FewToken LP must be initialized and have active liquidity |
| Trade types | Both directions; exact input and exact output; full fill only |
| Route removal | Stops the route; no automatic pool fallback |
| Duplicate route | One FewToken LP may back only one Shell Pool for the same raw origin-token pair in this Hook; ETH and WETH modes use distinct route keys |

The Hook can serve many Shell Pools from one address. Each Shell Pool has its own registered FewToken LP. Callers and `hookData` cannot choose a different execution pool. Duplicate Shell Pools with different fee/tick metadata cannot advertise the same LP for the same origin-token pair.

## Pricing and discovery

- `quote()` simulates the complete Shell execution through the official V4Quoter.
- `pseudoTotalValueLocked()` reports the FewToken LP's active-liquidity depth in origin-token order. It is a routing proxy, not withdrawable TVL.
- `AggregatorPoolRegistered` records Shell Pool initialization.
- `LpSwap` records the Shell PoolId, actual FewToken LP PoolId, direction and amounts.

The standard quote models swap before payment. A router that prepays PoolManager may execute with lower starting inventory than the quote requires, so production integration must also simulate the complete router calldata.

## Administration

The owner may initialize Shell Pools, register/remove routes and nominate a new owner. The nominated address must accept ownership. The contract is non-upgradeable and has no method to take fees, sweep tokens or withdraw LP positions.

For production, use a Safe multisig and verify every PoolKey. Removing a mapping is the per-pair emergency stop.

## Unsupported cases

- Dynamic-fee Shell Pools.
- LP hooks that return swap deltas.
- Partial fills.
- Fee-on-transfer, rebasing or otherwise non-standard origin tokens unless separately reviewed and tested.
- A FewToken wrapper that is not canonical for the configured factory.

Canonical wrapper validation proves wrapper identity, not that an arbitrary underlying token is safe.

The constructor also requires code at PoolManager, FewFactory, WETH9 and V4Quoter, and requires V4Quoter to report the same PoolManager. Wrap and unwrap verify the exact change in wrapper backing. Unexpected direct ETH transfers revert.
