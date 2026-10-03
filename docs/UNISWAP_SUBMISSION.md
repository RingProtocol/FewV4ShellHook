# Uniswap Submission Package

Use this package only after the final Hook is deployed on Ethereum mainnet, the exact source is verified, and at least one reviewed Shell Pool has minimal liquidity. Replace every placeholder and recheck the live forms before submitting. Hooklist registration and routing review are separate.

Current official guidance:

- [Routing for hooked pools](https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools)
- [Routing-review form](https://developers.uniswap.org/hook-allowlist)
- [Hooklist submission](https://github.com/Uniswap/hooklist/issues/new?template=submit-hook.yml)
- [Hooklist schema](https://github.com/Uniswap/hooklist/blob/main/schema.json)

## 1. Release facts

| Item | Value |
|---|---|
| Name | FewV4ShellHook |
| Chain | Ethereum (`1`) |
| Hook address | `<HOOK_ADDRESS>` |
| PoolId or Uniswap pool URL | `<POOL_ID_OR_APP_URL>` |
| Source | `<PUBLIC_REPOSITORY_URL>` |
| Verified source | `<SOURCE_VERIFICATION_URL>` |
| Deployment transaction | `<DEPLOY_TX>` |
| Initial pool list | `<INITIAL_POOL_IDS>` |
| Contact | `<CONTACT>` |

The address must have permission mask `0x2088`: `beforeInitialize`, `beforeSwap` and `beforeSwapReturnsDelta` are true; every other Hook permission is false.

Properties:

- dynamic fee: `false`
- upgradeable: `false`
- custom swap data required: `false`
- vanilla swap supported: `true`
- swap access: `none`

## 2. Hooklist issue

| Field | Answer |
|---|---|
| Chain | `ethereum` |
| Hook Address | `<HOOK_ADDRESS>` |
| Hook Name | `FewV4ShellHook` |
| Description | `Lets users trade origin tokens through an explicitly approved canonical FewToken Uniswap v4 LP. It wraps input 1:1, executes the nested FewToken LP swap, unwraps output and settles atomically through PoolManager. The Hook is non-upgradeable, permissionless for swaps, requires no custom hookData and charges no additional Hook fee.` |
| Deployer Address | `<DEPLOYER_ADDRESS>` |
| Audit URL | Leave blank until an independent audit covers the exact release commit. |

Hooklist inclusion supplies public metadata. It does not make the Hook eligible for routing.

## 3. Routing-review form

This Hook requires manual review because it uses `beforeSwapReturnsDelta`.

| Field | Answer |
|---|---|
| Hook name | `FewV4ShellHook` |
| Hook description | `This immutable Uniswap v4 Hook lets users swap ordinary origin tokens through one owner-approved canonical FewToken v4 LP without manually wrapping. The owner initializes the Shell Pool to prevent third-party price front-running, then binds its PoolId to the reviewed LP. The Hook wraps input directly to PoolManager, executes the nested FewToken LP at its live price, depth and fee, unwraps output back to PoolManager and returns the complete swap delta. Each route is restricted to canonical FewFactory wrappers. Callers cannot select another LP, hookData may be empty, partial fills revert, and the Hook charges no additional fee.` |
| Hook address | `<HOOK_ADDRESS>` |
| Pool address | `<POOL_ID_OR_APP_URL>` — provide the v4 PoolId and a Uniswap or explorer link; the pool must already have minimal liquidity |
| Hook details | Select the delta-flag option. Select major-token pairs when applicable. Do not select `None of the above`. |
| Chain(s) | `Ethereum mainnet` |
| Link to source | `<PUBLIC_REPOSITORY_URL>` |
| Website | `https://ring.exchange` |
| Audit links | Leave blank until the final release has an applicable audit |
| Contact and consent | Complete by the person authorized to submit for Ring |

## 4. Published routing criteria

| Uniswap criterion | Evidence to provide |
|---|---|
| Mainnet deployment | `<HOOK_ADDRESS>` and `<DEPLOY_TX>` |
| Verified source | `<SOURCE_VERIFICATION_URL>` matching `<COMMIT_SHA>` and runtime codehash |
| Does not modify or bypass the AMM protocol fee | The Shell curve is bypassed by Custom Accounting; the nested FewToken v4 LP charges its configured v4 LP fee and the Hook returns no fee override or extra fee. Ask Uniswap to confirm this two-pool accounting is acceptable. |
| No upgradeable proxy | Direct immutable deployment; no proxy, delegatecall or upgrade role |
| Not malicious or extractive | Canonical wrappers, explicit route mapping, full-fill enforcement, exact backing/balance checks, reentrancy lock and atomic rollback |
| No custom router calldata | `hookData` is ignored and may be empty; fork tests use Universal Router |

The fee criterion requires an explicit Uniswap answer. Do not describe it as already approved for the new address.

## 5. Evidence to attach

- [Public Hook description](hooks-description.md)
- [Architecture](FEW_V4_SHELL_HOOK.md)
- [Design decision and gas evidence](DESIGN_DECISION.md)
- [Security review](SECURITY_REVIEW.md)
- [Audit scope](../AUDIT_SCOPE.md)
- [Deployment runbook](DEPLOYMENT.md)
- [Release record](RELEASE_RECORD.md)
- `<SOURCE_VERIFICATION_URL>`
- `<POOL_ID_OR_APP_URL>`
- `<UNFORCED_QUOTE_RESPONSE_OR_SCREENSHOT>`
- `<SWAP_CALLDATA_SIMULATION>`
- `<CANARY_TX>` after explicit approval and execution

## 6. Acceptance sequence

1. Freeze one commit, deploy it and verify source plus constructor values.
2. Initialize one reviewed PoolKey, register the FewToken LP and add capped canary inventory.
3. File the Hooklist issue for public metadata.
4. Submit the routing-review form for the exact address and PoolId.
5. Request an unforced official quote. Continue only if it contains the exact Hook address, Shell PoolId and intended FewToken LP route.
6. Simulate official Universal Router calldata against the current block.
7. Broadcast one approved small canary, reconcile balances/events and monitor before increasing capital.

Do not claim routing, frontend traffic or production approval from a Hooklist entry, local UniRoute replay, successful simulation or manually forced route. Each is a separate evidence step.
