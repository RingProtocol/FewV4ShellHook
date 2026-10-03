# FewV4NettingShellHook 使用与运维手册

本文档面向两类读者：**用户/前端**（把 swap 打进 hook）与 **Owner/Keeper**（维护库存、跑监控面板）。
设计层解释见 `NETTING_SHELL_HOOK.md`；库存容量估算见 `neting_estimation.md`。本文只讲"怎么用"和"要盯什么"。

适用版本：`feat/netting-shell-rebased @ ac4c1f4`（含 auto-fallback）。

---

## 1. 结算路径与省 gas 的语义

Netting hook 每笔 swap 会二选一：

```text
路径 A · Netting（省 gas ~98k-137k / 笔）
  条件： claimBalance(fewIn) ≥ amountIn  AND  claimBalance(originOut) ≥ amountOut
  动作： burn/mint 4 条 claim，不做 wrap/unwrap

路径 B · Fallback（不省 gas，也不 revert）
  条件： A 里任一 claim 不够，但 PoolManager 有对应实物 origin 现金
  动作： 走父类 FewV4ShellHook.convertAndSettle → 现场 wrap + LP swap + unwrap

路径 C · Revert（真正缺货）
  条件： A 不成立 且 B 也不成立 → super._requireSettlementInventory 抛
        LpInsufficientInventory(token, available, required)
```

**关键结论**：省 gas 不是 hook 属性，是**库存健康度属性**。库存撑得住时省，撑不住时退化到 baseline 成本，只有两条腿都空才炸。

---

## 2. 库存清单（4 条腿，一个都不能少）

单个 Shell 池 A/B 需要预置 **4 条 PoolManager ERC-6909 claim**（不是 hook 地址上的 ERC20 余额）：

| Currency | 说明 | 何时消耗 | 何时积累 |
|---|---|---|---|
| `originA` claim | 底层 A（ETH 用 `Currency.wrap(address(0))`） | 反向 swap（B→A）给用户付款时 | A→B 收下用户支付时 |
| `fewA` claim | fwA 封装代币 | A→B 输入付给 LP 时 | B→A 从 LP 收到时 |
| `originB` claim | 底层 B | A→B 给用户付款时 | B→A 收下用户支付时 |
| `fewB` claim | fwB 封装代币 | B→A 输入付给 LP 时 | A→B 从 LP 收到时 |

一个 Shell 池 = 4 条 claim 腿。多池共享 hook 时，claim **不隔离**（已知生产 gate 未完成项，见 §9），一条路由的单向流可以把另一条路由的 buffer 抽干。

**读取方式**：
```solidity
hook.claimBalance(Currency.wrap(addr)) → uint256
// 等价 on-chain 读：
poolManager.balanceOf(hook, currencyId)
//   native: currencyId = bytes32(0)
//   ERC20:  currencyId = uint256(uint160(token)) 左对齐到 bytes32
```

---

## 3. 用户 / 前端接口（透明，不用改）

用户 swap 走 **Uniswap V4 PoolManager**，跟直接结算版 hook 完全一致：

```text
Universal Router / v4-actions ActionsRouter / Permit2
  → poolManager.swap(shellPoolKey, SwapParams{...}, hookData)
  → hook._beforeSwap / _afterSwap 自动选路径
```

前端唯一要用的 view 是报价：
```solidity
function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
    external returns (uint256 amountOut);
```
（非 view，内部走模拟；返回该方向给定数量下的对侧数量。）

**前端 UX 建议**：报价时同时读一次 4 条 claim 余额，若路径会走 fallback，可以标注"本笔不享 netting gas 折扣"。

---

## 4. Owner / Keeper 接口

所有函数 modifier：`onlyOwner + isNotLocked`。**当前无 bounded keeper role**，keeper 只能走"外部合约代理 + owner multisig 授权"或"signer-based 后端 + 严格白名单"。

### 4.1 库存维护

```solidity
function depositClaim(Currency currency, uint256 amount) external payable;
// native 需 msg.value == amount；ERC20 需先 approve(hook)，hook 内部 safeTransferFrom(msg.sender, address(this), amount)

function withdrawClaim(Currency currency, address recipient, uint256 amount) external;
// recipient ≠ 0；一次性走 PoolManager.take 打给 recipient

function rebalanceOriginToFew(Currency origin, address fewToken, uint256 amount) external;
// 把 origin claim 打包 wrap 成 few claim（补 few 侧）

function rebalanceFewToOrigin(Currency origin, address fewToken, uint256 amount) external;
// 反向：把 few claim unpack unwrap 回 origin claim（补 origin 侧）

function rebalancePair(
    Currency accumulatedOrigin, address depletedFew,   uint256 wrapAmount,
    Currency depletedOrigin,    address accumulatedFew, uint256 unwrapAmount
) external;
// 一次 unlock 修两条腿，冷态约 331k gas（WETH/WBTC）/ 339k（ETH/WBTC）
// 约束：accumulatedOrigin 与 depletedOrigin 不能是同一币种
```

### 4.2 池管理（继承自基类）

```solidity
function setLpPool(PoolKey calldata shellPoolKey, PoolKey calldata lpPoolKey) external onlyOwner;
function rescueToken(address token, uint256 amount, address to) external onlyOwner;
function transferOwner(address newOwner) external onlyOwner;
function acceptOwner() external;
```

### 4.3 校验点

`_validatePair`（src/experimental/FewV4NettingShellHook.sol:249）在每次 rebalance 前跑：
- `fewToken == fewFactory.getWrappedToken(underlying)` 非规范 wrapper 抛 `NonCanonicalWrapper`
- `IFewWrappedToken(fewToken).token() == underlying` 不匹配抛 `WrapperUnderlyingMismatch`

面板要报这两类错就直接反解 revert data 前 4 字节。

---

## 5. 事件清单（面板 topic0 索引）

### Netting 独有（`src/experimental/FewV4NettingShellHook.sol`）

```solidity
ClaimDeposited(address indexed currency, uint256 amount)                                     // 库存进
ClaimWithdrawn(address indexed currency, address indexed recipient, uint256 amount)          // 库存出（对账重点）
OriginWrapped(address indexed origin, address indexed fewToken, uint256 amount)              // rebalanceOriginToFew / rebalancePair 侧 1
FewTokenUnwrapped(address indexed fewToken, address indexed origin, uint256 amount)          // rebalanceFewToOrigin / rebalancePair 侧 2
```

### 基类（继承）

```solidity
LpSwap(...)                                                       // 每笔真实成交都会打，是净流量统计的主来源
LpPoolSet(PoolId indexed shellPoolId, PoolKey lpPoolKey)
LpPoolRemoved(PoolId indexed shellPoolId)
OwnerTransferStarted / OwnerChanged                                // 正常应极少触发，OwnerChanged 一旦出=安全事件
```

---

## 6. 错误选择器（revert 分类）

面板遇到 tx revert 时按 4-byte selector 归类：

| Selector 名 | 出处 | 语义 | 严重度 |
|---|---|---|---|
| `InsufficientClaim(Currency,uint256,uint256)` | Netting | 库存操作路径不足（`_burnClaim` 里），非 swap 主路径 | 一般 |
| `ClaimBalanceMismatch(Currency,uint256,uint256)` | Netting | claim 增减与预期不符，理论上不该出现 | 高（异常） |
| `InvalidClaimRequest()` | Netting | unlock 回调数据 hash 不匹配 / pair 相同币种 | 一般 |
| `InvalidClaimAmount()` | Netting | 0 金额 / msg.value 与 amount 不匹配 / fewToken 无代码 | 一般 |
| `InvalidClaimRecipient()` | Netting | recipient = 0 | 一般 |
| `LpInsufficientInventory(address,uint256,uint256)` | 基类 | **fallback 也失败**，两条腿都没货 → 需要立刻 page | 严重 |
| `NonCanonicalWrapper(address,address)` | 基类 | 试图用非 fewFactory 注册的 wrapper | 严重 |
| `WrapperUnderlyingMismatch(address,address,address)` | 基类 | wrapper 的底层与 origin 不符 | 严重 |
| `LpSwapPartialFill(uint256,uint256)` | 基类 | LP 池只吃了部分 | 中 |
| `LpRouteUnavailable()` | 基类 | 池未 setLpPool 或已移除 | 中 |
| `LpSwapDirectionMismatch()` | 基类 | 方向不对 | 中 |
| `ShellPoolNotInitialized(PoolId)` | 基类 | 池没初始化 | 中 |
| `QuoteAmountTooLarge(uint256,uint256)` | 基类 | 报价超上限 | 低 |

---

## 7. 监控面板指标（分优先级）

### P0 — 每 15~60s 采样，直接决定能否省 gas

1. **4 条 claim 余额**：`claimBalance(Currency.wrap(token))` × N 池
2. **PoolManager cash**（fallback 兜底能力）：`getPoolCash(poolId, currencyId)`
3. **双向 quote 探针**：小量 `quote(true, -PROBE, SHELL_POOL)` 正反两向，任一 revert = 路由死

### P1 — 判断"该 rebalance 了吗"

4. **净流量速率**：从 `LpSwap` 事件按 (tokenIn, tokenOut) 汇总，估算每条 claim 每小时净消耗
5. **ETA 到阈值**：`claimBalance / 净消耗`；建议阈值 = 单笔最大 swap × 2~3（`neting_estimation.md` §4）
6. **Fallback 命中率**：hook 本身没有直接事件，反推三选一：
   - **推荐**：caller/前端 swap 前 `claimBalance` 快照、swap 后 diff，未变 = fallback
   - 或 receipt.gasUsed：netting ≈ 220k，fallback ≈ 320k，用 100k 阈值分
   - 或在 caller 侧加 view `willUseNetting(fewIn, originOut, amountIn, amountOut)`

### P2 — 池健康（沿用现有 `testresult/monitor-shell-pool.sh` 结构）

7. LP 池 `slot0.tick` 是否在 `[LP_TICK_LOWER, LP_TICK_UPPER]` 范围内
8. LP 池与壳池的 active liquidity
9. Wrapper  backing：`IERC20(WBTC).balanceOf(FWWBTC)`、`IERC20(WETH).balanceOf(FWWETH)`
10. LP 池价格 vs UniV3 参考池偏差

### P3 — 安全事件

11. `withdrawClaim` 频率 + `recipient` 白名单：出现陌生地址 = 立即报警（可能 owner key 泄漏）
12. `OwnerChanged` 事件：正常应永不触发，触发 = 紧急响应

---

## 8. Caller 合约能力清单（推荐）

用于"使用 + 监控 + Keeper 门面"三层。不改 hook 本体。

```solidity
interface IFewV4NettingShellHook {
    function claimBalance(Currency) external view returns (uint256);
    function depositClaim(Currency, uint256) external payable;
    function withdrawClaim(Currency, address, uint256) external;
    function rebalanceOriginToFew(Currency, address, uint256) external;
    function rebalanceFewToOrigin(Currency, address, uint256) external;
    function rebalancePair(Currency, address, uint256, Currency, address, uint256) external;
    function quote(bool, int256, PoolId) external returns (uint256);
}
```

建议 caller 至少提供：

- **`getInventoryHealth(PoolId shellPoolId)` view**：返回 4 条腿余额、阈值、`willUseNetting`、`fallbackAvailable`。前端每次报价顺便调，展示"这笔预计省多少 gas"。
- **Keeper 门面**：`requestRebalance(...)` 走 signer-based 后端，加 **per-epoch cap**（例 24h 内累计 wrapAmount ≤ X ETH）+ **禁止 withdraw** 的白名单 selector。这是 hook 生产 gate #2 的过渡方案，先在 caller 层做。
- **紧急退出**：`emergencyWithdrawAll(Currency[] memory legs)` 只允许 owner multisig，循环 `withdrawClaim` 逐条清空。
- **观测写入**：swap 前后 claim 快照 → 上链后 diff → 上报到面板 DB。这样你能独立统计 netting vs fallback 命中率，不依赖 gas 反推。

---

## 9. 已知缺口 / 上线前必做（对齐 `NETTING_SHELL_HOOK.md#production-gates`）

以下都不是"部署即可用"，需要 caller/面板层至少覆盖：

1. **Claim 池间不隔离**：多池共享 hook 库存，一条路由可吞掉别的池 buffer。→ 面板必须有"hook 全局库存视图 + 按池净流量视图"两层，不能只看单池。
2. **无 bounded keeper role**：只有 owner。→ caller 层加白名单 selector + 频次/金额上限。
3. **无 pause**：不能"拒新单 / 允许提现"。→ 面板告警 → 手动 `setLpPool` 移除路由或走 owner multisig 紧急流程。
4. **fallback 无直接事件**：面板要自己算 netting/fallback 分类。→ 走 §7 P1 #6 三选一。
5. **无多 provider share accounting**：deposit 全归 owner。→ 别把 keeper 钱包当 LP 存款口。
6. **未做历史订单流回放**：`neting_estimation.md` §4 建议用真实成交序列跑一次，得到每池最小库存与 rebalance 频率。相关原始数据在 `testresult/2026-09-28-mainnet-frontend-traffic.md` 与 `testresult/2026-10-21-anvil-mainnet-fork-verification.md`。

---

## 10. 快速参考

**"这笔省不省 gas"** 一句话判定：
```
省 ⇔ claimBalance(fewIn) ≥ amountIn  且  claimBalance(originOut) ≥ amountOut
```

**"库存告急"** 判定（面板阈值参考，非硬阈值）：
- `claimBalance < 单笔最大 swap × 3` → 黄
- `claimBalance < 单笔最大 swap × 1` → 红，`rebalancePair` 立即执行
- `claimBalance == 0` 且 PoolManager cash 也覆盖不了该 swap → 深红（fallback 也失败）

**"多久必须补一次"**：
`ETA = 当前 claimBalance / 观察到的净消耗速率`。冷 rebalancePair ~331k gas，热 rebalance 更便宜；把 ETA 阈值定在"下一次 gas 高峰前"比定在"库存归零前"更省。

**"要不要立刻换路径"**：Netting 无内部路由，用户 swap 只走一个 shellPoolKey → 一个 lpPoolKey。真要停路由用 `setLpPool` 卸载或走 owner 紧急流程，hook 没有 pause 开关。
