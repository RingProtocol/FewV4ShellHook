# Gas design decision

Updated: 2026-10-03

## Decision

Ship the direct-settlement release candidate. Keep batched netting in a separate experimental branch until real traffic shows enough same-direction trades to cover its capital and operating cost.

## Compared designs

| Design | Per-trade behavior | Benefit | Added risk and cost |
|---|---|---|---|
| Current deployed Shell | Each trade wraps, transfers, swaps, transfers and unwraps | Proven live integration | Highest execution gas |
| Direct settlement | `wrapTo`/`unwrapTo` send directly to PoolManager; wrapper approvals are cached; transient storage blocks reentry | No long-lived Hook inventory or keeper; lower gas | Canonical wrapper allowance remains open; bounded by the reviewed wrapper implementation |
| Batched netting | Trades use prefunded origin/FewToken buffers; a keeper wraps/unwraps accumulated imbalances later | A separate hardened prototype saved about `45k–60k gas` per Router call versus its local immediate-settlement baseline under `--isolate`; this is not a head-to-head result against this direct-settlement candidate | Requires four inventory buffers per pair, per-pool accounting, caps, pause/keeper operations and a safe exit process; a direct two-asset batch call cost about `342k–350k gas` under `--isolate` |

The cached approval follows the same pattern used by Uniswap's audited `WstETHHook`, which approves its immutable wrapper once. Ring narrows that pattern to the exact non-upgradeable wrapper recorded by the immutable FewFactory, then verifies backing and recipient balances on every conversion. FewV2 keeps exact per-swap approvals because its current gas saving already clears the release target without accepting this standing dependency.

The earlier `122k–135k` per-swap saving and three/four-trade operating threshold came from repeated calls inside one test transaction. Independent transaction contexts change the access and storage costs, so those figures are withdrawn as production estimates. Set a batch threshold only after measuring the intended deployment, full transaction cost, inventory yield cost and actual trade sequence. Publicly rewarded jobs add posting and payout costs; user gas savings are not Ring revenue.

## Fixed-block result

Ethereum mainnet fork block: `26,069,215`.

Reproduced on October 3, 2026 with `forge test --isolate --match-contract FewV4ShellHookMainnetTest -vv`. The following numbers are the complete Universal Router **call** measured by `vm.lastCallGas().gasTotalUsed`, not mined receipt gas. They exclude transaction intrinsic/calldata costs and setup/registration transactions. The candidate's canonical allowances were already registered before the measured swaps.

| Universal Router path | Deployed Shell | Release candidate | Saving |
|---|---:|---:|---:|
| ETH -> WBTC exact input | 310,292 | 266,112 | 44,180 gas |
| ETH -> WBTC exact output | 310,634 | 266,533 | 44,101 gas |
| WBTC -> ETH exact input | 321,343 | 287,299 | 34,044 gas |
| WBTC -> ETH exact output | 320,283 | 285,971 | 34,312 gas |

The same fork suite executed 24 combinations across ETH/WBTC and WETH/WBTC: both directions, exact input/output and three sizes. The gas table compares the four ETH/WBTC directions and trade types at `0.01 ETH` or `100,000 sats` specified amount. It also verified atomic rollback on failed slippage. Previously published savings of `61,774–88,985 gas` from non-isolated calls are not the current transaction-context estimate.

These are deterministic fork measurements, not a forecast of route selection or future mainnet volume. The release decision still requires deployment simulation, code review, independent audit and canary limits.

## Security rationale

Uniswap's [v4 Security Framework](https://developers.uniswap.org/docs/protocols/v4/security) treats custom accounting, external dependencies and unusual token behavior as separate review surfaces. OpenZeppelin's [Hooks Library audit](https://blog.openzeppelin.com/uniswap-hooks-library-milestone-1-audit) also highlights exact-output accounting, multi-pool isolation, withdrawal rules and reentrancy around ERC-6909/async settlement. The direct design keeps settlement atomic and does not retain claims or user-facing inventory between trades.

The netting design follows useful ideas from Uniswap's [PoolVault](https://github.com/Uniswap/v4-hooks-public/blob/main/src/alf/base/PoolVault.sol), but using ERC-6909 claims safely requires more accounting and operational controls than this release needs. It remains a separate experiment rather than a hidden production feature.

## Reconsider netting when

- a replay of real traffic reaches a measured batch size that covers settlement costs, rather than a fixed four-trade rule;
- the extra routing wins and LP revenue exceed inventory opportunity cost, keeper gas and monitoring cost;
- per-pool inventory isolation, caps, pause, forced settlement and withdrawal tests pass;
- an independent review accepts the expanded custody and accounting surface.
