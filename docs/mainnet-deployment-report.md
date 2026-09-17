# FewV4ShellHook Ethereum Mainnet Deployment Report

**Date**: 2026-09-17
**Network**: Ethereum Mainnet (Chain ID: 1)

---

## 1. Overview

FewV4ShellHook was deployed on Ethereum mainnet and its source code verified. The hook was deployed via CREATE2 through a `HookDeployer` helper contract, with the owner set in the constructor (no transferOwner step; the CREATE2 address is bound to the owner, preventing front-running). Etherscan source verification passed.

**Deployment status**: Success
**Source verification**: Success (Etherscan `Pass - Verified`)
**Total gas cost**: ~0.00018 ETH

---

## 2. Mainnet Infrastructure

| Contract | Address |
|----------|---------|
| V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| FewFactory | `0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD` |
| WETH9 | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| V4Quoter | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |

---

## 3. Hook Deployment

### Deployment Details

| Item | Value |
|------|-------|
| Deploy script | `script/DeployFewV4ShellHookWithOwner.s.sol` |
| Deployer | `0x87555dd0e101817c1bc7867e32451b080C55f596` |
| HookDeployer | `0x5EED96397543E8307024657fD3E73EcB66D03e73` |
| **Hook address** | **`0xADEf200B8E8b66e27D5bd11C87D789D4D6E82088`** |
| Owner | `0x87555dd0e101817c1bc7867e32451b080C55f596` |
| Salt | `0x00000000000000000000000000000000000000000000000000000000000020c3` |
| Deploy block | 25994339 |

### Deployment Transactions

| # | Tx Hash | Type | Gas Used |
|---|---------|------|----------|
| 1 | `0x098d53c9ffe1264e7331ea9ec31c578d34c20ae1304e5346b4abafc3f03865cc` | HookDeployer CREATE | 135,255 |
| 2 | `0xd4ac28ad1bb28e901299ab6b31f25afbbb49479a84d34ef21a830e101c931d28` | deployHook CALL (CREATE2) | 2,987,310 |

Total: 3,122,565 gas at ~0.12 gwei, ~0.00018 ETH actual cost.

### Pre-deployment Gas Estimate (simulation)

| Item | Value |
|------|-------|
| Estimated total gas | 4,302,051 |
| Estimated gas price | 0.128 gwei |
| Estimated cost | ~0.00055 ETH |
| Deployer balance | 0.01849 ETH |

### Hook Address Permission Flags

Low 14 bits of the hook address = `0x2088` = `0b10000010001000`, matching the required permission flags:

| Permission | Flag bit | Status |
|------------|----------|--------|
| BEFORE_INITIALIZE | bit 13 (0x2000) | Set |
| BEFORE_SWAP | bit 7 (0x0080) | Set |
| BEFORE_SWAP_RETURNS_DELTA | bit 3 (0x0008) | Set |

No extra flag bits.

### On-chain Verification

```
owner:        0x87555dd0e101817c1bc7867e32451b080C55f596
poolManager:  0x000000000004444c5dc75cB358380D2e3dE08A90
fewFactory:   0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD
weth:         0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
v4Quoter:     0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203
```

### getHookPermissions (on-chain eth_call)

```
beforeInitialize:          true
afterInitialize:           false
beforeAddLiquidity:         false
afterAddLiquidity:          false
beforeRemoveLiquidity:      false
afterRemoveLiquidity:       false
beforeSwap:                 true
afterSwap:                  false
beforeDonate:               false
afterDonate:                false
beforeSwapReturnsDelta:     true
afterSwapReturnsDelta:      false
afterAddLiquidityReturnsDelta:    false
afterRemoveLiquidityReturnsDelta: false
```

### Etherscan Source Verification

- Status: `Pass - Verified`
- URL: https://etherscan.io/address/0xadef200b8e8b66e27d5bd11c87d789d4d6e82088
- Method: `forge verify-contract`, constructor args = `(poolManager, fewFactory, weth, v4Quoter, owner)`
- Compiler settings: solc 0.8.26, optimizer 200 runs, via_ir = true, evm_version = cancun

---

## 4. Notes

### Source Change

The deployed code includes one uncommitted fix on top of commit `75b432c`: `src/FewV4ShellHook.sol` adds the missing `error InvalidAmount();` declaration (`_validateAmount` referenced it but it was never declared — a compile error; test files already referenced this selector). The deployed bytecode includes this fix.

### Previous Deployments

Two earlier instances exist on-chain (per Etherscan `getcontractcreation`):

| Deployment | Address | Block | Factory | `owner()` |
|------------|---------|-------|---------|-----------|
| 1st | `0x241109e8f79663c1361c13e8cafa5245ea986088` | 25,980,974 | `0x4e59b44847b379578588920cA78FbF26c0B4956C` (deterministic CREATE2) | `0x4e59b44847b379578588920cA78FbF26c0B4956C` — uncontrollable |
| 2nd | `0xb003f2cc4b314d98b4ea77667350b974ad102088` | 25,980,998 | `0x1dd3a11bbd1331f2646972aefa054bfbc49c6087` (HookDeployer) | `0xeb85b790FDe7B923916e659cF04f518fFc8c6CF4` |

The first instance was deployed with the owner misconfigured to the CREATE2 factory address and is unusable. The second was a corrected redeploy minutes later with owner `0xeb85b790FDe7B923916e659cF04f518fFc8c6CF4`. Both were created by the same deployer EOA `0x87555dd0e101817c1bc7867e32451b080C55f596`.

**Note**: the previous deployment's owner (`0xeb85b790...`) differs from this deployment's owner (`0x87555dd0...`, the deployer itself via `HOOK_OWNER`). If `0xeb85b790...` was the intended owner, this deployment's owner is misconfigured.
