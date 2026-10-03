# Gas design decision

Updated: 2026-10-03

## Decision

Ship the direct-settlement release candidate. Keep batched netting in a separate experimental branch until real traffic shows enough same-direction trades to cover its capital and operating cost.

## Compared designs

| Design | Per-trade behavior | Benefit | Added risk and cost |
|---|---|---|---|
| Current deployed Shell | Each trade wraps, transfers, swaps, transfers and unwraps | Proven live integration | Highest execution gas |
| Direct settlement | `wrapTo`/`unwrapTo` send directly to PoolManager; exact per-swap approvals; cached route fields; transient storage blocks reentry | No long-lived Hook inventory, standing approval or keeper; lower gas | Depends on reviewed canonical wrappers and standard origin-token behavior |
| Batched netting | Trades use prefunded origin/FewToken buffers; a keeper wraps/unwraps accumulated imbalances later | A separate hardened prototype saved about `45k–60k gas` per Router call versus its local immediate-settlement baseline under `--isolate`; this is not a head-to-head result against this direct-settlement candidate | Requires four inventory buffers per pair, per-pool accounting, caps, pause/keeper operations and a safe exit process; a direct two-asset batch call cost about `342k–350k gas` under `--isolate` |

### October 3 integration decision

The PR now incorporates `main@7d760a9`: cached route fields, physical-balance caps for the discovery depth proxy and the smaller `LpSwap` event are retained. Canonical-wrapper validation, explicit routes, owner-only initialization, duplicate-route rejection and two-step ownership are retained from the release candidate.

The earlier candidate cached maximum wrapper approvals. That option is withdrawn for this release: main's zero-residual-allowance regression is preserved. Each conversion approves only its input amount, then verifies both the backing change and complete allowance consumption. A remaining allowance reverts the whole transaction. This narrows the standing dependency without abandoning direct settlement; the table below remeasures this exact-approval version.

The earlier `122k–135k` per-swap saving and three/four-trade operating threshold came from repeated calls inside one test transaction. Independent transaction contexts change the access and storage costs, so those figures are withdrawn as production estimates. Set a batch threshold only after measuring the intended deployment, full transaction cost, inventory yield cost and actual trade sequence. Publicly rewarded jobs add posting and payout costs; user gas savings are not Ring revenue.

## Fixed-block result

Ethereum mainnet fork block: `26,069,215`.

Reproduced on October 3, 2026 after main integration with `forge test --isolate --match-contract FewV4ShellHookMainnetTest -vv`. The following numbers are the complete Universal Router **call** measured by `vm.lastCallGas().gasTotalUsed`, not mined receipt gas. They exclude transaction intrinsic/calldata costs and setup/registration transactions. Each measured candidate swap includes its exact input approval and zero-remaining-allowance check; registration grants no allowance. The baseline is the deployed `0xadef...2088` Shell, not current main.

| Universal Router path | Deployed Shell | Release candidate | Saving |
|---|---:|---:|---:|
| ETH -> WBTC exact input | 310,292 | 266,613 | 43,679 gas |
| ETH -> WBTC exact output | 310,634 | 267,034 | 43,600 gas |
| WBTC -> ETH exact input | 321,343 | 293,859 | 27,484 gas |
| WBTC -> ETH exact output | 320,283 | 292,796 | 27,487 gas |

The same fork suite executed 24 combinations across ETH/WBTC and WETH/WBTC: both directions, exact input/output and three sizes. The gas table compares the four ETH/WBTC directions and trade types at `0.01 ETH` or `100,000 sats` specified amount. It also verified atomic rollback on failed slippage. The prior isolated savings of `34,044-44,180 gas` applied to the earlier maximum-approval candidate. Previously published savings of `61,774-88,985 gas` from non-isolated calls are also not the current transaction-context estimate.

These are deterministic fork measurements, not a forecast of route selection or future mainnet volume. The release decision still requires deployment simulation, code review, independent audit and canary limits.

## Security rationale

The direct conversion follows Uniswap's [flash-accounting settlement sequence](https://developers.uniswap.org/docs/protocols/v4/guides/flash-accounting): sync the currency, deliver tokens to PoolManager, then settle the measured amount. OpenZeppelin's [SafeERC20 `forceApprove`](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#SafeERC20-forceApprove-contract-IERC20-address-uint256-) supports tokens that require zero-before-nonzero approval. Neither primitive certifies the wrapper or underlying, so this Hook separately checks canonical identity, exact backing changes and zero remaining allowance.

Uniswap's [v4 Security Framework](https://developers.uniswap.org/docs/protocols/v4/security) treats custom accounting, external dependencies and unusual token behavior as separate review surfaces. OpenZeppelin's [Hooks Library audit](https://blog.openzeppelin.com/uniswap-hooks-library-milestone-1-audit) also highlights exact-output accounting, multi-pool isolation, withdrawal rules and reentrancy around ERC-6909/async settlement. The direct design keeps settlement atomic and does not retain claims or user-facing inventory between trades.

The netting design follows useful ideas from Uniswap's [PoolVault](https://github.com/Uniswap/v4-hooks-public/blob/main/src/alf/base/PoolVault.sol), but using ERC-6909 claims safely requires more accounting and operational controls than this release needs. It remains a separate experiment rather than a hidden production feature.

## Reconsider netting when

- a replay of real traffic reaches a measured batch size that covers settlement costs, rather than a fixed four-trade rule;
- the extra routing wins and LP revenue exceed inventory opportunity cost, keeper gas and monitoring cost;
- per-pool inventory isolation, caps, pause, forced settlement and withdrawal tests pass;
- an independent review accepts the expanded custody and accounting surface.
