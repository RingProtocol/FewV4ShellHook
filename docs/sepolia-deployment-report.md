# FewV4ShellHook Sepolia 部署与测试报告

**日期**: 2026-09-15
**网络**: Ethereum Sepolia (Chain ID: 11155111)
**RPC**: `https://eth-sepolia.g.alchemy.com/v2/REDACTED`

---

## 1. 概要

在 Sepolia 测试网上完成了 FewV4ShellHook 的部署和端到端链上测试。Hook 合约部署成功，所有权正确转移，shell pool 和 lp pool 初始化完成，双向 swap 验证通过 — 所有 swap 均路由到 lp pool 执行，shell pool 价格保持不变。

**部署状态**: 成功
**测试状态**: 成功（21 笔交易全部成功）
**总 Gas 费用**: 0.257423 ETH

---

## 2. Sepolia 基础设施

| 合约 | 地址 | 状态 |
|------|------|------|
| V4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | 已部署 |
| FewFactory | `0x226e65279E177A779522864Ce1dE40c85E2C08A5` | 已部署 |
| WETH9 | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` | 已部署 |
| V4Quoter | `0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227` | 已部署 |
| TOKEN (UV4A) | `0xc41CdC9422c70c07681f9A92CDf23d3f8b3bd54B` | 已部署 |
| FEW_TOKEN (fwUV4A) | `0x57AFcCC6D20e72D55B2A9ccB4fae10d189dcf19d` | 已部署 |
| FEW_WETH (fwWETH) | `0x98b902eF4f9fEB2F6982ceEB4E98761294854D61` | 已部署 |

### 代币包装关系

```
TOKEN (UV4A)  --FewFactory.getWrappedToken-->  FEW_TOKEN (fwUV4A)
WETH          --FewFactory.getWrappedToken-->  FEW_WETH (fwWETH)
```

---

## 3. Hook 部署

### 部署信息

| 项目 | 值 |
|------|-----|
| 部署脚本 | `script/DeployFewV4ShellHookWithOwner.s.sol` |
| Deployer | `0x87555dd0e101817c1bc7867e32451b080C55f596` |
| HookDeployer | `0xd7AdAFcb6e36104c6B289Fa8Fa67b0dAbbF97AE8` |
| **Hook 地址** | **`0xff5641ABF89a3Cd2e28ea01e65e19a5a33EB2088`** |
| Owner | `0x87555dd0e101817c1bc7867e32451b080C55f596` |
| Salt | `0x0000000000000000000000000000000000000000000000000000000000002108` |
| 部署区块 | 11710128 - 11710130 |

### 部署交易

| # | 交易哈希 | 类型 | Gas | 区块 |
|---|---------|------|-----|------|
| 1 | `0x069c537f97e82a681ff6d1dd93d081004df455c15c18a4fcfea4ed77074f286d` | HookDeployer CREATE | 169,771 | 11710128 |
| 2 | `0xbef1d093d0b7298f9ccad9dd844b52fd24b0751d73c0824c77814d90ae2a940b` | deployHook CALL | 2,966,523 | 11710130 |

### Hook 地址权限标志验证

Hook 地址低 14 位 = `0x2088` = `0b10000010001000`，匹配所需的权限标志：

| 权限 | 标志位 | 状态 |
|------|--------|------|
| BEFORE_INITIALIZE | bit 13 (0x2000) | 已设置 |
| BEFORE_SWAP | bit 7 (0x0080) | 已设置 |
| BEFORE_SWAP_RETURNS_DELTA | bit 3 (0x0008) | 已设置 |

无多余标志位。

### 链上验证

```
owner:        0x87555dd0e101817c1bc7867e32451b080C55f596
poolManager:  0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
fewFactory:   0x226e65279E177A779522864Ce1dE40c85E2C08A5
weth:         0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
v4Quoter:     0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227
```

### getHookPermissions (链上 eth_call)

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

---

## 4. 端到端链上测试

### 测试脚本

`script/TestSepolia.s.sol` — 直接在 Sepolia 链上执行完整流程。

### 测试参数

| 参数 | 值 |
|------|-----|
| Shell pool | ETH (currency0) / TOKEN UV4A (currency1) |
| LP pool | FEW_TOKEN (currency0) / FEW_WETH (currency1) |
| Fee | 2500 |
| Tick Spacing | 60 |
| 初始价格 | 1:1 (sqrtPriceX96 = 79228162514264337593543950336) |
| LP 流动性 | 0.1 ETH 等值 |
| Shell 流动性 | 0.1 ETH 等值 |
| Swap 金额 | 0.01 ETH |
| 储备金 | 0.05 ETH 等值 |
| orderAligned | false (FEW_TOKEN < FEW_WETH, 但 shell ETH < TOKEN) |

### 执行步骤

1. **部署测试路由器**
   - PoolSwapTest: `0x3A7887BC0631107Ed1E1bE8A553f114502336e0D`
   - PoolModifyLiquidityTest: `0x56d0769aeCc252C2CE4B031D6C663fE79413B6d5`

2. **初始化 Shell Pool** (ETH/TOKEN, fee=2500, tickSpacing=60, hook=FewV4ShellHook)
   - PoolId: `0xf85a2b0f755ca04ed8ef8324294c56007108d1aed0b59aef818713868052d8e0`
   - 初始价格: 1:1

3. **初始化 LP Pool** (FEW_TOKEN/FEW_WETH, fee=2500, tickSpacing=60, 无 hook)
   - PoolId: `0xf335485e8febba1df68f877c2f93e0d9c010e4c260e97bc5167e2f5bef5c0e62`
   - 初始价格: 1:1

4. **注册 LP Pool** — `hook.setLpPool(shellKey, lpKey)`
   - 验证 wrapper underlying 匹配: FEW_TOKEN -> TOKEN, FEW_WETH -> WETH
   - orderAligned = false

5. **包装代币** — 0.15 ETH -> WETH -> FEW_WETH, 0.15 TOKEN -> FEW_TOKEN

6. **添加 LP 流动性** — 全范围 (tick -887220 ~ 887220), 0.1 ETH 等值

7. **添加 Shell 流动性** — 全范围 (tick -887220 ~ 887220), 0.1 ETH + 0.1 TOKEN

8. **预存储备金** — 向 PoolManager 转入 0.05 TOKEN, 0.05 FEW_WETH, 0.05 FEW_TOKEN

### Swap 测试结果

#### Swap 1: zeroForOne (ETH -> TOKEN), exact-input 0.01 ETH

| 指标 | 值 |
|------|-----|
| ETH 消耗 | 0.01 ETH (10000000000000000 wei) |
| TOKEN 收到 | 9070243237099340 (约 0.00907 TOKEN) |
| Shell 价格 (前) | 79228162514264337593543950336 (1:1) |
| Shell 价格 (后) | 79228162514264337593543950336 (不变) |
| LP 价格 (前) | 79228162514264337593543950336 (1:1) |
| LP 价格 (后) | 87131171725062205268499959382 (移动) |
| **结论** | **LP pool 被使用, shell pool 价格不变** |

#### Swap 2: oneForZero (TOKEN -> ETH), exact-input 0.01 TOKEN

| 指标 | 值 |
|------|-----|
| TOKEN 消耗 | 0.01 TOKEN (10000000000000000) |
| ETH 收到 | 10871644312841063 (约 0.01087 ETH) |
| Shell 价格 (前) | 79228162514264337593543950336 (不变) |
| Shell 价格 (后) | 79228162514264337593543950336 (不变) |
| LP 价格 (前) | 87131171725062205268499959382 |
| LP 价格 (后) | 78517767700911710401814003378 (移动) |
| **结论** | **LP pool 被使用, shell pool 价格不变** |

### Hook 余额验证

```
TOKEN balance:    0
FEW_WETH balance: 0
FEW_TOKEN balance: 0
ETH balance:      0
```

Hook 无残留余额。

### 测试交易

共 21 笔交易，区块 11710184 ~ 11710207，全部成功。

| # | 交易哈希 |
|---|---------|
| 0 | `0x20284cb095e25056d59d44e77e8a13af9e8ea8feb64d192e8470aa162ada4f8b` |
| 1 | `0x44fa185fa0d6282d19dce3b459a3e0a766928f4f57637e9d165a4228c5e90290` |
| 2 | `0xe74e46fd6d5c9a205a750af3b829998eadb13b1bd54b00b516a06daa773f5e89` |
| 3 | `0xe6d6e789d9ef4551bd26b23aae06cd2467f7428971f8b32aa03cb9a5987e8c55` |
| 4 | `0x7fea874ccec0747a2d47489290a04a2ec03baf2762326ce0dab2a24e1f288cba` |
| 5 | `0x5838270c63da9c37ee781bb77f86fe1bdb3e4ef296409999dc104764114faf40` |
| 6 | `0x82cb6f0342a63b94fc8c75f43ed45347325a456d7117d167d9483de238627036` |
| 7 | `0x95a49bdfb6723149e76621f575d2fc586621e0604eada58f1b4e1df883c355ec` |
| 8 | `0x665dae024ec9440c1d0bca76f086c3f9ce4c2a27a1d0172427c4b5eb49693335` |
| 9 | `0x792e93fd0255be33678505004ea8c1d130731ffa92ceaaeddf053c855165fa0f` |
| 10 | `0x61c47e433348982466af28f2f21eea9540dfdcb7251e813bd0258ef066dc593d` |
| 11 | `0x2b156320d400e810566b1f72628c00657ff969db5c5a7de1429e60b0cae5514d` |
| 12 | `0x6786018467571511d0e6dc864799a23b8fdb8bdf20d59c4eff7fd459e3abc6ac` |
| 13 | `0x182b46b92cd4364a8c217ff53290362014d68cf0510935414f81b91f694c1d5c` |
| 14 | `0xa9bd1eb5b191918b77b6df8bcae651f3d054e831e53a5d2d8426f468e0497671` |
| 15 | `0x18a9e7f2efa401a98bcd14458d056891b8a5de58806831347da4c8b6e6e7aeba` |
| 16 | `0x81af2d64ebd5b986d8c6055e2c3663a662ba215eb7f9509ba7bae5e02679c02b` |
| 17 | `0x8a22cf091cfe7c4856e1d7435e1de3cc1d3e2fa53256dd700e7669ed78dc4455` |
| 18 | `0x560bf0fbc5f2c99d8a0b4575de35c97e0a32a05bf6b9f944f2e4ba272faffc12` |
| 19 | `0x97fadbedf8c6e885377ee52e2f937eb4fc426aca503eb92bc9df7aefa24689c4` |
| 20 | `0x2db44464e78937307e4751618258a13309f940727e836957caf51ceb39abe0dc` |

---

## 5. 链上状态验证

### Hook 合约状态

```
initedPoolCount: 1
owner:           0x87555dd0e101817c1bc7867e32451b080C55f596
```

### Shell Pool (initedPools)

```
currency0:   0x0000000000000000000000000000000000000000 (ETH)
currency1:   0xc41CdC9422c70c07681f9A92CDf23d3f8b3bd54B (TOKEN)
fee:         2500
tickSpacing: 60
hooks:       0xff5641ABF89a3Cd2e28ea01e65e19a5a33EB2088
PoolId:      0xf85a2b0f755ca04ed8ef8324294c56007108d1aed0b59aef818713868052d8e0
```

### LP Pool (lpPools)

```
currency0:   0x57AFcCC6D20e72D55B2A9ccB4fae10d189dcf19d (FEW_TOKEN)
currency1:   0x98b902eF4f9fEB2F6982ceEB4E98761294854D61 (FEW_WETH)
fee:         2500
tickSpacing: 60
hooks:       0x0000000000000000000000000000000000000000
orderAligned: false
set:         true
PoolId:      0xf335485e8febba1df68f877c2f93e0d9c010e4c260e97bc5167e2f5bef5c0e62
```

### pseudoTotalValueLocked (shell pool 深度)

```
amount0 (ETH 侧):   99103355687158935  (约 0.0991 ETH)
amount1 (TOKEN 侧): 100904756762900657 (约 0.1009 TOKEN)
```

### quote (链上报价)

```
zeroForOne, exact-input 0.01 ETH  -> 9227540536059119  (约 0.00923 TOKEN)
oneForZero, exact-input 0.01 TOKEN -> 8915567654908240  (约 0.00892 ETH)
```

---

## 6. 费用汇总

| 阶段 | Gas | ETH 费用 |
|------|-----|---------|
| Hook 部署 | 3,136,294 gas | 0.003394 ETH |
| 端到端测试 | 4,235,452 gas | 0.254029 ETH |
| **总计** | **7,371,746 gas** | **0.257423 ETH** |

### Deployer 余额变化

```
部署前: 1.4326 ETH
部署后: 1.4292 ETH
测试后: 1.1751 ETH
剩余:   1.1751 ETH
```

---

## 7. 单元测试

在本地运行了完整的单元测试套件：

### 集成测试 (test/integration/FewV4ShellHook.t.sol)

```
Ran 50 tests
[PASS] 50 tests
[FAIL] 0 tests
[SKIP] 0 tests
```

### Mainnet Fork 测试 (test/fork/FewV4ShellHookFork.t.sol)

```
Ran 5 tests (mainnet fork at block 25,833,244)
[PASS] 5 tests
[FAIL] 0 tests
[SKIP] 0 tests
```

---

## 8. 结论

1. **Hook 部署成功** — FewV4ShellHook 已部署到 Sepolia，地址 `0xff5641ABF89a3Cd2e28ea01e65e19a5a33EB2088`，权限标志正确，所有权已转移。

2. **Shell Pool 和 LP Pool 初始化成功** — ETH/TOKEN shell pool 和 FEW_TOKEN/FEW_WETH lp pool 均在 Sepolia 上初始化，lp pool 已注册到 hook。

3. **双向 Swap 验证通过** — ETH->TOKEN 和 TOKEN->ETH 两个方向的 swap 均成功路由到 lp pool 执行，lp pool 价格移动而 shell pool 价格保持不变，符合设计预期。

4. **Hook 无残留余额** — swap 后 hook 合约的 ETH、TOKEN、FEW_WETH、FEW_TOKEN 余额均为 0。

5. **quote 和 pseudoTotalValueLocked 功能正常** — 链上 eth_call 验证了 IAggregatorHook 接口的报价和深度查询功能。

6. **单元测试全部通过** — 50 个集成测试 + 5 个 mainnet fork 测试全部通过。
