# Audit Scope

## Review target

| Item | Value |
|---|---|
| Branch | `review/v4-shell-release` |
| Commit | To be fixed after internal review |
| Compiler | Solidity `0.8.26`, optimizer 200 runs, `via_ir = true`, Cancun |
| Framework | Foundry |
| Test snapshot | `97 passed, 0 failed, 0 skipped` on October 3, 2026; 10,000 fuzz cases; fixed Ethereum blocks `25,833,244` and `26,069,215`; the three Universal Router fork tests also passed with `--isolate` |
| Runtime size | `15,643 bytes`, 8,933 bytes below the EIP-170 limit |

The current deployment at `0xadef...2088` is prior art and live-integration evidence. It is not the bytecode in this review target.

## Production code in scope

| File | Role | Priority |
|---|---|---|
| `src/FewV4ShellHook.sol` | Route registration, quote/depth interfaces, nested v4 swap and custom accounting | Critical |
| `src/base/LpSettlement.sol` | Origin/FewToken conversion and PoolManager settlement | Critical |
| `src/base/LpOwner.sol` | Two-step bounded route administrator | High |
| `src/libraries/LpRouteLib.sol` | Route construction and LP availability | High |
| `src/libraries/LpPriceLib.sol` | Price-limit mapping between Shell and FewToken order | High |
| `src/interfaces/**` | Minimal external and discovery ABIs | Supporting |

Pinned dependencies, scripts and tests are not production code, but their assumptions are in scope where they affect deployment or external calls.

## Architecture under review

1. An origin-token v4 Shell Pool is the public Uniswap entry; its curve and fee are not the execution venue.
2. Only the owner may initialize a Shell Pool; the owner then binds that PoolId to one explicit canonical FewToken v4 LP.
3. The Hook takes the full swap delta, wraps origin input, executes a nested v4 swap, unwraps output and settles atomically.
4. `quote()` simulates the complete path through V4Quoter. `pseudoTotalValueLocked()` reports active FewToken LP depth in origin-token order.
5. The Hook is immutable and non-upgradeable. The owner can register/remove routes and transfer ownership, but cannot sweep assets, withdraw LP or charge a Hook fee.
6. Duplicate Shell metadata cannot advertise the same FewToken LP for the same raw origin pair within one deployment. Native ETH and WETH routes are distinct.

## Directed questions

1. Are all `BeforeSwapDelta` signs and PoolManager take/settle operations correct for both directions and exact-input/exact-output?
2. Do full-fill and mapped `sqrtPriceLimitX96` checks prevent partial or direction-inverted execution?
3. Can shared PoolManager physical balances create loss rather than a clean quote/execution failure?
4. Do return-value, temporary-balance and exact wrapper-backing checks close lying wrapper and fee-on-transfer paths?
5. Can an underlying, canonical wrapper or permitted inner LP Hook reenter any value-moving path?
6. Is cached unlimited approval acceptable given immutable canonical FewFactory wrappers, or should a deployment-specific revocation mechanism be added?
7. Can initialization, route registration/removal, ownership transfer or cross-deployment duplicates create stale prices or misleading routing depth?
8. Does `pseudoTotalValueLocked()` remain a safe discovery signal when settlement inventory is smaller than LP depth?
9. Does the v4 Shell fee bypass plus the nested FewToken LP fee satisfy Uniswap's current routing criteria?

## Evidence

- [Architecture](docs/FEW_V4_SHELL_HOOK.md)
- [Design decision](docs/DESIGN_DECISION.md)
- [Security review](docs/SECURITY_REVIEW.md)
- [Deployment runbook](docs/DEPLOYMENT.md)
- [Uniswap submission package](docs/UNISWAP_SUBMISSION.md)
- `test/integration/` and `test/fork/`

The requested audit output is a report against one frozen commit plus one post-fix review pass.
