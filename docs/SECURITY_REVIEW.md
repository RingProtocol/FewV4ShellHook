# Security review status

Updated: 2026-10-03

## Conclusion

The release candidate is suitable for public source review and a capped canary after independent review. Local testing did not find an exploitable balance, route-selection or reentrancy failure. It is not correct to call the contract fully safe or audited.

## Controls in this release

| Risk | Control |
|---|---|
| Fake wrapper receives an allowance | Both LP currencies must equal the FewFactory canonical wrappers for their reported underlyings |
| Wrapper retains a usable allowance after conversion | Registration grants no approval; each swap approves its exact input and reverts unless the allowance is fully consumed |
| Third party front-runs Shell initialization with a misleading permanent price | `_beforeInitialize` accepts only the current owner, expected to be a Safe |
| Wrong constructor dependency | Every dependency must contain code; V4Quoter must point to the configured PoolManager |
| Owner removes a mapping but trading continues elsewhere | No automatic LP inference; a missing mapping makes the route unavailable |
| Nested LP Hook changes custom-accounting deltas | PoolManager accounts LP Hook deltas to that Hook and returns the adjusted Shell delta; the LP Hook must settle its own deltas |
| Nested Hook or token callback reenters Shell swap | Official v4-periphery transient `ReentrancyLock` blocks nested Shell swaps |
| Partial fill changes economics | Exact input/output must fill completely or revert |
| Unbacked wrap or unwrap | Return amounts, temporary balances and the wrapper's exact backing delta are checked; any mismatch rolls back the LP swap |
| Forced or accidental ETH | The receive path accepts ETH only from PoolManager or WETH9 |
| Wrong price-limit direction | Shell price limits are mapped into FewToken currency order and tested in both directions |
| Admin typo transfers control | Two-step ownership transfer; production owner should be a Safe |
| Admin needs to stop one pair | Removing that Shell Pool's LP mapping disables the route |

The main integration removes cached unlimited approvals. The Hook grants only the exact input amount during conversion and checks that the canonical wrapper consumed it completely. The dependency still needs review, but it has no standing allowance after a successful swap. A non-standard token that reports a remaining allowance causes the full transaction to revert.

## Tests completed

- Both directions and exact input/output.
- Native ETH and WETH paths.
- Quote versus actual settlement.
- Small/medium/large Universal Router mainnet-fork trades.
- Slippage failure and full atomic rollback.
- Insufficient PoolManager inventory and insufficient wrapper backing.
- Zero/oversized amount boundaries.
- Malicious wrapper with a plausible underlying.
- Lying canonical-wrapper mock that under-transfers backing on wrap or unwrap, including full rollback.
- Constructor dependency without code and V4Quoter/PoolManager mismatch.
- Multiple Shell Pools with different fee metadata sharing one LP, plus removal/re-registration.
- Unexpected direct ETH transfer.
- Forced ETH dust cannot change native-swap accounting; it remains trapped because the Hook deliberately has no sweep function.
- Inner LP hooks with before/after swap return-delta permissions.
- Nested LP Hook reentrancy attempt.
- Route removal and restoration.
- Two-step ownership, unauthorized initialization and unauthorized admin calls.
- Residual origin/FewToken/WETH/ETH balances.
- Fuzzed quote/settlement consistency.
- Zero remaining allowance in both directions and exact input/output, including native WETH conversion.
- Unexpected origin-token dust cannot be pulled through a residual wrapper allowance.
- Unconsumed allowance rolls back approval, balances, backing and LP price.
- Cached route replacement clears the old duplicate guard and updates its PoolId, fee and tick spacing.
- Discovery depth is capped by wrapper backing and shared PoolManager inventory.

October 3, 2026 post-integration recheck: `forge test --force --json` executed all four suites, with 97 local integration/deployment tests and 10 fixed-block fork tests passing; none failed or skipped. The three Universal Router tests also passed with `--isolate`, including the 24-case matrix and slippage rollback. The fuzz target ran 10,000 cases. Format, build and high-severity lint checks passed; runtime is 16,385 bytes. Incremental runs omitted a fork suite during concurrent validation, so those partial totals are not the acceptance record. Validation must be serial and must reconcile all expected suites.

The earlier latest-state fork run used block `26,087,184` on September 30, 2026; it does not certify this updated candidate. The prior review recorded Slither analyzing 50 contracts with 99 detectors and zero results after intentional suppressions for ignored V4Quoter gas estimates, unused slot fields, the required DeltaResolver override and bounded route registration. Slither was not available locally for the October 3 integration check and was not rerun; this is not a new static-analysis or audit result. CI must be inspected separately, and an RPC-unavailable fork job is not evidence that fork tests ran.

## Remaining risks

1. **No independent audit.** The tests are local and fixed-block fork evidence, not a third-party audit or formal proof.
2. **Underlying-token behavior.** Canonical wrapper identity does not make fee-on-transfer, rebasing, callback-heavy or malicious origin tokens safe. Production routes need a separate token allowlist and review.
3. **Privileged route choice.** The owner can redirect future swaps to another canonical FewToken LP or stop a route. Use a Safe, transaction simulation and change monitoring.
4. **External LP Hook risk.** A permitted inner Hook can still change fees, revert or have its own vulnerabilities. Review it separately or use a hookless FewToken LP.
5. **PoolManager inventory.** Settlement depends on physical origin-token inventory in PoolManager or a router that prepays before swap. A quote, route discovery and an executable full transaction are separate checks.
6. **Routing approval.** Public source, Registry inclusion, UniRoute discovery and default frontend selection are separate external decisions.
7. **Privileged initialization.** Only the owner can initialize a Shell Pool. This closes third-party price front-running, but it makes Safe availability part of adding a new pool. Losing the owner key does not stop existing routes.
8. **Shared LP discovery.** Multiple Shell Pools may intentionally share one LP. Discovery and accounting systems must avoid treating the shared LP liquidity as independent depth for every Shell.
9. **Forced ETH dust.** `SELFDESTRUCT` can force ETH into any contract. It does not affect the tested native settlement baseline, but the dust cannot be recovered because this Hook has no sweep authority.

## Review still required before uncapped capital

- Independent Solidity review focused on custom accounting and nested Hook behavior.
- Reproduce the fork matrix against the final deployed bytecode.
- Verify constructor dependencies and canonical wrapper bytecode on the target chain.
- Safe ownership, monitoring and route-removal drill.
- Token-specific review for every new origin pair.

The review approach follows Uniswap's [v4 Security Framework](https://developers.uniswap.org/docs/protocols/v4/security), OpenZeppelin's [v4 Core audit](https://blog.openzeppelin.com/uniswap-v4-core-audit) and its [Hooks Library audit](https://blog.openzeppelin.com/uniswap-hooks-library-milestone-1-audit).

The earlier maximum-approval candidate is superseded by exact per-swap approval after integrating main's zero-residual-allowance tests. Canonical-wrapper identity and exact backing/settlement checks remain mandatory. A wrapper defect or malicious origin token remains a dependency risk; removing standing approval is not a general safety guarantee.
