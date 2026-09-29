# FewV4NettingShellHook

Status: draft research implementation. Do not deploy or fund without completing the production gates below.

## What changes

The current Shell hook wraps the user's input and unwraps the output during every swap. The netting version keeps four prefunded inventories as PoolManager ERC-6909 claims:

```text
originA claim  <->  fewA claim
originB claim  <->  fewB claim
```

For an A -> B swap, the hook:

1. burns `fewA` claims to pay the real FewToken LP;
2. mints claims for the `fewB` received from that LP;
3. mints `originA` claims for the user's payment;
4. burns prefunded `originB` claims to pay the user.

No wrap or unwrap runs on the user's swap path. Opposite-direction flow offsets the balances naturally. When flow remains one-way, the owner calls `rebalancePair()` to wrap the accumulated input and unwrap the accumulated output in one PoolManager unlock.

## Inventory operations

- `depositClaim()` funds one inventory leg.
- `withdrawClaim()` returns unused inventory to an owner-selected address.
- `rebalanceOriginToFew()` and `rebalanceFewToOrigin()` repair one leg.
- `rebalancePair()` repairs both sides of a one-way flow in one transaction.
- `claimBalance()` exposes the exact PoolManager claim balance.

Only the owner can move inventory. Registered FewToken pools must use canonical wrappers returned by FewFactory. Callback data is bound to an active request hash, and claim shortfalls revert the complete swap.

## Fork evidence

The fixed-block fork uses Ethereum block `26,069,215` and the fwWBTC/fwWETH pool behind position `#416852`.

- 24 Universal Router executions cover ETH/WBTC and WETH/WBTC, both directions, exact-in, exact-out, and three sizes.
- Netting and immediate settlement return identical quotes and user balances.
- Against current `main`, netting reduces the user transaction by `169,185-181,803 gas` in the tested matrix.
- A cold combined rebalance costs `331,241 gas` for WETH/WBTC and `339,226 gas` for ETH/WBTC, excluding transaction intrinsic gas.
- Claim shortage, unauthorized inventory management, forged callback data, and non-canonical wrappers revert.
- The new fork suite passes `9/9`; the existing fork suite passes `7/7`; local integration/deployment tests pass `73/73`, including 10,000 fuzz runs.

The product comparison against the separately optimized Shell vNext remains the conservative decision baseline: each user swap saves `98,303-137,145 gas`, and four same-direction trades are the minimum practical batch before settlement. Three trades are too close to break-even after keeper calldata and cold-state variation.

## What this draft does not solve

- Claims are shared hook inventory, not isolated per Shell pool.
- There is no bounded keeper role, pause mode, or per-pool exposure cap.
- There is no multi-provider share accounting; deposits are owner inventory only.
- There is no historical order-flow replay proving the required inventory size or natural offset rate.
- Fee-on-transfer and rebasing assets are not supported.
- The combination of four claim inventories and delayed FewToken conversion has not been independently audited.

## Production gates

1. Add per-pool inventory accounting and caps so one route cannot consume another route's buffer.
2. Separate a bounded keeper role from the owner; keeper may rebalance but never withdraw.
3. Add pause-new-risk behavior while keeping withdrawals available.
4. Add invariants for claim conservation, donations, transfer pollution, callback reentrancy, keeper failure, and owner exit.
5. Replay representative order flow to size each claim leg and set the settlement threshold from net gas, not a fixed trade count.
6. Complete independent security review before any mainnet funding.

## References

- [Uniswap PoolVault](https://github.com/Uniswap/v4-hooks-public/blob/main/src/alf/base/PoolVault.sol)
- [OpenZeppelin Uniswap v4 Core audit](https://blog.openzeppelin.com/uniswap-v4-core-audit)
- [OpenZeppelin Hooks Library audit](https://blog.openzeppelin.com/uniswap-hooks-library-milestone-1-audit)
- [CoW Protocol batch auctions](https://docs.cow.fi/cow-protocol/concepts/introduction/fair-combinatorial-auction)
