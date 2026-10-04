# Release Record

Complete this file from the exact clean commit selected for deployment. Do not reuse values from the current `0xadef...2088` deployment.

## 1. Candidate

| Field | Value |
|---|---|
| Release commit | `<COMMIT_SHA>` |
| Repository | `https://github.com/RingProtocol/FewV4ShellHook` |
| Solidity | `0.8.26` |
| Foundry | `<FOUNDRY_VERSION>` |
| Optimizer | `enabled, 200 runs, via IR` |
| Runtime size | `16,385 bytes` for the main-integrated local candidate; remeasure after the final commit |
| Runtime codehash | `<RUNTIME_CODEHASH>` |
| Test result | `107 passed, 0 failed, 0 skipped` across four suites after main integration on October 3, 2026; fixed blocks `25,833,244` and `26,069,215`; three Universal Router tests also passed with `--isolate`; historical latest-state evidence at block `26,087,184` is not a validation of this updated candidate |
| Final diff approved by | `<APPROVER>` |

## 2. Immutable configuration

| Field | Value |
|---|---|
| Hook address | `<HOOK_ADDRESS>` |
| CREATE2 salt | `<HOOK_SALT>` |
| Constructor arguments | `<CONSTRUCTOR_ARGS>` |
| PoolManager | `<POOL_MANAGER>` |
| FewFactory | `<FEW_FACTORY>` |
| WETH9 | `<WETH9>` |
| V4Quoter | `<V4_QUOTER>` |
| Initial owner | `<SAFE_OWNER>` |

Deployment is rejected if any dependency has no code, V4Quoter reports a different PoolManager, or ownership is not the approved Safe.

## 3. Deployment evidence

| Field | Value |
|---|---|
| Deployment transaction | `<DEPLOY_TX>` |
| Deployer | `<DEPLOYER>` |
| Source verification | `<SOURCE_VERIFICATION_URL>` |
| Runtime codehash matches build | `<YES_OR_NO>` |
| Permission mask | `0x2088` |
| Proxy or upgrade path | `none` |
| Additional Hook fee | `0` |

## 4. Initial routes

Record one row per registered Shell Pool.

| Origin pair | Shell PoolId | FewToken LP PoolId | LP fee/tick | Init/config tx | Active LP depth | Shell inventory | Max canary amount |
|---|---|---|---|---|---|---|---|
| `<PAIR>` | `<SHELL_POOL_ID>` | `<LP_POOL_ID>` | `<FEE_AND_TICK>` | `<TXS>` | `<DEPTH>` | `<TOKEN_AMOUNTS>` | `<LIMIT>` |

Record every Shell Pool separately, including fee and tick metadata, when multiple Shell Pools share one FewToken LP. Record native ETH and WETH routes separately.

## 5. Acceptance and rollback

- [ ] Source, constructor values and runtime codehash are independently verified.
- [ ] Safe owns the Hook and `pendingOwner()` is zero.
- [ ] Route maps to the reviewed canonical FewToken LP and has no duplicate.
- [ ] Both directions and exact-input/exact-output pass through Universal Router.
- [ ] Quote and execution agree within documented integer rounding.
- [ ] Hook balances return to their starting values after success and failure.
- [ ] Unforced Uniswap Quote API returns the exact PoolId and Hook address.
- [ ] Official `/swap` calldata simulates successfully against the current block.
- [ ] One approved small canary is reconciled on-chain.
- [ ] Hooklist metadata and routing review cover the exact deployment.

Rollback means: remove the affected LP mapping, stop adding Shell inventory, remove the address/PoolIds from Ring routing, and retain the immutable deployment for investigation. The route can be restored only after a new review and simulation.
