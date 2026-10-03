# Security review status

Updated: 2026-10-03

## Conclusion

The release candidate is suitable for public source review and a capped canary after independent review. Local testing did not find an exploitable balance, route-selection or reentrancy failure. It is not correct to call the contract fully safe or audited.

## Controls in this release

| Risk | Control |
|---|---|
| Fake wrapper receives an allowance | Both LP currencies must equal the FewFactory canonical wrappers for their reported underlyings |
| Third party front-runs Shell initialization with a misleading permanent price | `_beforeInitialize` accepts only the current owner, expected to be a Safe |
| Wrong constructor dependency | Every dependency must contain code; V4Quoter must point to the configured PoolManager |
| Same LP is advertised by duplicate Shell metadata | Duplicate routes for the same raw origin-token pair and FewToken LP are rejected within the Hook |
| Owner removes a mapping but trading continues elsewhere | No automatic LP inference; a missing mapping makes the route unavailable |
| Nested LP Hook changes custom-accounting deltas | LP hooks with before/after swap return-delta permissions are rejected |
| Nested Hook or token callback reenters Shell swap | Official v4-periphery transient `ReentrancyLock` blocks nested Shell swaps |
| Partial fill changes economics | Exact input/output must fill completely or revert |
| Unbacked wrap or unwrap | Return amounts, temporary balances and the wrapper's exact backing delta are checked; any mismatch rolls back the LP swap |
| Forced or accidental ETH | The receive path accepts ETH only from PoolManager or WETH9 |
| Wrong price-limit direction | Shell price limits are mapped into FewToken currency order and tested in both directions |
| Admin typo transfers control | Two-step ownership transfer; production owner should be a Safe |
| Admin needs to stop one pair | Removing that Shell Pool's LP mapping disables the route |

Cached unlimited approvals are granted only to canonical FewToken wrappers. This is acceptable only while the configured FewFactory and wrapper bytecode remain the reviewed, non-upgradeable implementation. The Hook itself cannot revoke an allowance without changing bytecode, so deployment review must verify those dependencies.

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
- Duplicate Shell metadata for one origin pair and LP, plus removal/re-registration.
- Unexpected direct ETH transfer.
- Forced ETH dust cannot change native-swap accounting; it remains trapped because the Hook deliberately has no sweep function.
- Inner LP hooks with return-delta permissions.
- Nested LP Hook reentrancy attempt.
- Route removal and restoration.
- Two-step ownership, unauthorized initialization and unauthorized admin calls.
- Residual origin/FewToken/WETH/ETH balances.
- Fuzzed quote/settlement consistency.

October 3, 2026 recheck: 87 local integration/deployment tests plus 10 fixed-block fork tests passed; no tests were skipped. The three Universal Router fork tests also passed with `--isolate`, including the 24-case matrix and slippage rollback. The fuzz target ran 10,000 cases. Format, build and high-severity lint checks passed; runtime is 15,643 bytes.

The earlier latest-state fork run used block `26,087,184` on September 30, 2026. The prior review recorded Slither analyzing 50 contracts with 99 detectors and zero results after intentional suppressions for ignored V4Quoter gas estimates, unused slot fields, the required DeltaResolver override and bounded route registration. Slither was not available for the October 3 push check and was not rerun; this is not a new static-analysis or audit result.

## Remaining risks

1. **No independent audit.** The tests are local and fixed-block fork evidence, not a third-party audit or formal proof.
2. **Underlying-token behavior.** Canonical wrapper identity does not make fee-on-transfer, rebasing, callback-heavy or malicious origin tokens safe. Production routes need a separate token allowlist and review.
3. **Privileged route choice.** The owner can redirect future swaps to another canonical FewToken LP or stop a route. Use a Safe, transaction simulation and change monitoring.
4. **External LP Hook risk.** A permitted inner Hook can still change fees, revert or have its own vulnerabilities. Review it separately or use a hookless FewToken LP.
5. **PoolManager inventory.** Settlement depends on physical origin-token inventory in PoolManager or a router that prepays before swap. A quote, route discovery and an executable full transaction are separate checks.
6. **Routing approval.** Public source, Registry inclusion, UniRoute discovery and default frontend selection are separate external decisions.
7. **Privileged initialization.** Only the owner can initialize a Shell Pool. This closes third-party price front-running, but it makes Safe availability part of adding a new pool. Losing the owner key does not stop existing routes.
8. **Cross-deployment duplicates.** The duplicate-route guard covers one Hook deployment. Release operations must not publish equivalent duplicate routes from a second Hook address.
9. **Forced ETH dust.** `SELFDESTRUCT` can force ETH into any contract. It does not affect the tested native settlement baseline, but the dust cannot be recovered because this Hook has no sweep authority.

## Review still required before uncapped capital

- Independent Solidity review focused on custom accounting and nested Hook behavior.
- Reproduce the fork matrix against the final deployed bytecode.
- Verify constructor dependencies and canonical wrapper bytecode on the target chain.
- Safe ownership, monitoring and route-removal drill.
- Token-specific review for every new origin pair.

The review approach follows Uniswap's [v4 Security Framework](https://developers.uniswap.org/docs/protocols/v4/security), OpenZeppelin's [v4 Core audit](https://blog.openzeppelin.com/uniswap-v4-core-audit) and its [Hooks Library audit](https://blog.openzeppelin.com/uniswap-hooks-library-milestone-1-audit).

The cached wrapper allowance is not a new approval model. Uniswap's audited `WstETHHook` also grants its immutable canonical wrapper a maximum underlying-token allowance once. Here, `setLpPool()` first requires the exact FewFactory wrapper, the factory mapping is write-once, and deployed `FewWrappedToken` contracts are non-upgradeable. The Hook still checks the exact wrapper-backing and recipient-balance change on every conversion and normally retains no token balance. A defect in the canonical wrapper remains a dependency risk, so this design is limited to the reviewed FewFactory and remains in the audit scope.
