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

All 97 local and fixed-block Ethereum fork tests passed again on October 3, 2026, including 10,000 fuzz runs for quote/settlement consistency. The three Universal Router fork tests also passed in independent transaction contexts with `--isolate`. The earlier latest-state run of the 10 fork tests used Ethereum block `26,087,184` on September 30, 2026. These are engineering checks, not an independent security audit. See [Security review](docs/SECURITY_REVIEW.md).

## Why this version

Two gas-saving designs were compared:

| Design | Result | Decision |
|---|---:|---|
| Direct settlement | `wrapTo`/`unwrapTo` settle directly with PoolManager; cached approvals; transient reentrancy lock | Use for the release candidate |
| Batched netting | Keeps origin/FewToken inventory and wraps/unwraps several trades together | Keep experimental; it needs prefunded inventory, keeper settlement and per-pool accounting |

At Ethereum block `26,069,215`, the release candidate saved `34,044–44,180 gas` per complete Universal Router call versus the currently deployed Shell Hook across ETH/WBTC in both directions and exact-input/exact-output modes under `--isolate`. This is call gas, not mined receipt gas. A 24-case matrix covered both ETH/WBTC and WETH/WBTC. The earlier non-isolated savings are superseded; full methodology is in [Design decision](docs/DESIGN_DECISION.md).

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
