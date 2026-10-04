# FewV4ShellHook

`FewV4ShellHook` lets users trade ordinary tokens through an explicitly approved FewToken Uniswap v4 LP.

```text
origin token A
  -> wrap directly to PoolManager as fwA
  -> swap in the registered fwA/fwB LP
  -> unwrap fwB directly to PoolManager as origin token B
```

The origin-token Shell Pool is the Uniswap entry and settlement layer. The registered FewToken LP sets the price, depth and LP fee. The Hook does not add another fee and never executes against the Shell Pool curve.

## Status

This branch is a new, unaudited release candidate. It is not the bytecode currently deployed at `0xadef...2088`; any source change requires a new mined Hook address, deployment, verification and Uniswap review.

After integrating main on October 3, 2026, `forge test --force --json` executed all four suites: 107 passed, 0 failed and 0 skipped, including 10,000 fuzz runs for quote/settlement consistency. The three Universal Router fork tests also passed in independent transaction contexts with `--isolate`. The earlier latest-state run used Ethereum block `26,087,184` on September 30, 2026 and does not certify this updated candidate. These are engineering checks, not an independent security audit. See [Security review](docs/SECURITY_REVIEW.md).

## Why this version

Two gas-saving designs were compared:

| Design | Result | Decision |
|---|---:|---|
| Direct settlement | `wrapTo`/`unwrapTo` settle directly with PoolManager; exact per-swap approvals; cached route fields; transient reentrancy lock | Use for the release candidate |
| Batched netting | Keeps origin/FewToken inventory and wraps/unwraps several trades together | Keep experimental; it needs prefunded inventory, keeper settlement and per-pool accounting |

After integrating current main, the exact-approval candidate saved `27,484-43,679 gas` per complete Universal Router call versus the deployed Shell Hook at Ethereum block `26,069,215`, across ETH/WBTC in both directions and exact-input/exact-output modes under `--isolate`. This is call gas, not mined receipt gas or a benchmark against current main. A 24-case matrix covered both ETH/WBTC and WETH/WBTC. Previous candidate and non-isolated estimates are superseded; full methodology is in [Design decision](docs/DESIGN_DECISION.md).

## Safety boundary

- Only the owner can initialize a Shell Pool or register/remove its route. This prevents a third party from permanently front-running the reviewed PoolKey with a misleading Shell price.
- A route accepts only canonical FewFactory wrappers for the Shell currencies.
- Constructor dependencies must contain code, and V4Quoter must use the same PoolManager.
- The same FewToken LP cannot be advertised twice for the same origin-token pair from one Hook. Native ETH and WETH modes remain separately available.
- Removing a route stops that Shell Pool; there is no automatic fallback to another LP.
- LP hooks that return swap deltas are rejected because nested custom accounting cannot be settled safely here.
- Exact-input and exact-output swaps must fill completely or revert.
- Wrap/unwrap must change the canonical wrapper's backing by the exact requested amount.
- Native ETH is accepted only from PoolManager or WETH9.
- The Hook has no upgrade, withdrawal, sweep or fee-taking function.
- Ownership transfer takes two steps. Production ownership should be a Safe multisig.

The owner can redirect future swaps to another valid canonical FewToken LP or stop a route. The owner cannot move wallet funds, withdraw LP positions or sweep PoolManager assets.

`quote()` simulates the complete Shell swap through V4Quoter and rolls back all state changes. It models swap-before-payment. A router that pays PoolManager before swapping may execute with less starting inventory, so the complete router calldata must also be simulated. `pseudoTotalValueLocked()` caps its active-liquidity estimate by physical wrapper backing and PoolManager origin-token inventory; those singleton balances are shared, not reserved for this Shell Pool.

Wrapper approvals cover only the current input amount. A nonzero remaining allowance makes the entire swap revert. Route registration does not grant standing approval.

## Build and test

```sh
git submodule update --init --recursive
forge fmt --check
forge build --sizes
forge test --offline
```

Fixed-block mainnet tests use a local `ETH_RPC_URL` and never broadcast:

```sh
forge test --match-path 'test/fork/FewV4ShellHookFork.t.sol' -vv
forge test --match-path 'test/fork/FewV4ShellHookMainnet.t.sol' -vv
forge test --isolate --match-contract FewV4ShellHookMainnetTest -vv
```

The mainnet matrix covers ETH/WBTC and WETH/WBTC, both directions, exact input and exact output, three trade sizes, Universal Router execution, gas comparison and slippage rollback.

## Deployment

Use the owner-aware CREATE2 script only. The address is mined from the exact bytecode, constructor arguments, deployer and deployer nonce.

- [Deployment runbook](docs/DEPLOYMENT.md)
- [Architecture](docs/FEW_V4_SHELL_HOOK.md)
- [Uniswap review description](docs/hooks-description.md)
- [Uniswap submission package](docs/UNISWAP_SUBMISSION.md)
- [Audit scope](AUDIT_SCOPE.md)
- [Release record](docs/RELEASE_RECORD.md)

Never commit private keys, RPC URLs or explorer API keys. Simulate every transaction before broadcasting.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE).
