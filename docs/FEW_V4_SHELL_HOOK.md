# FewToken v4 壳池

> 更新日期：2026-09-01
> 状态：review package 已整理；未部署、未审计，也未确认被 Uniswap routing 自动发现

## 结论

`FewV4ShellHook` 可以把指定的 hookless `fwA/fwB` v4 池暴露为 origin token `A/B` 壳池：用户和通用 v4 router 只看到 `A -> B`，实际成交和 LP fee 全部发生在现有 FewToken v4 池。

```text
A/B outer pool（零 LP）
  -> take A from PoolManager
  -> A.wrap() -> fwA
  -> allowlisted hookless fwA/fwB v4 swap
  -> fwB.unwrap() -> B
  -> settle B to PoolManager
```

这条路线不需要再复制一份 A/B 流动性，也不会调用现有 `A/fwA`、`B/fwB` 1:1 wrapper 池。wrapper 池放在同一个 PoolManager 后，其 origin token 物理余额可以支持 Hook 在 router 最终付款前的原子 `take`；router 完成结算后，该余额恢复原值。余额不足时 quote 和 swap 都会回滚。

## 固定设计

| 项目 | V1 选择 |
|---|---|
| 流动性来源 | constructor allowlist 中唯一、精确的 inner PoolId |
| inner key | canonical FewToken、hookless、static fee、已初始化且当前有 active liquidity |
| outer pool | 相同 fee / tick spacing、零 LP、禁止 add liquidity 和 donate |
| 路由输入 | 不接受 caller 提供的 target、PoolKey 或非空 hookData |
| 成交 | exact-in 和 exact-out 都必须完整成交，少 1 wei 即整笔回滚 |
| price limit | V1 只接受 v4 canonical extreme；反序 token 采用严格 reciprocal rounding |
| wrap / unwrap | 返回值和真实余额变化同时检查，approval 每次归零 |
| 管理权限 | 无 owner、proxy、pause、route setter、fee setter、sweep |
| 额外收费 | 无；用户只支付 inner v4 池现有 LP/protocol fee |
| native ETH | V1 不支持；WETH 作为普通 ERC-20 可以支持 |

Hook 权限 mask 是 `0x2888`：

- `beforeInitialize`
- `beforeAddLiquidity`
- `beforeSwap`
- `beforeSwapReturnDelta`

outer pool 永久禁止 add liquidity，因此 active liquidity 始终为 0；donate 会由 v4 core 自身因无流动性拒绝，不需要额外启用 `beforeDonate` 权限。

`beforeSwapReturnDelta` 必须为 `true` 才能让零流动性的 outer pool 完全由 inner pool 结算。因此，这个设计不满足“四个 return-delta flag 全为 false”的免人工检查条件，不能把它描述为绕过 Uniswap 审核。

## 报价与发现边界

Hook 实现通用 `IAggregatorHook` ABI：

- `quote(bool,int256,PoolId)` 调用官方 V4Quoter 模拟完整 outer route，而不是只计算 inner swap。PoolManager 物理库存、wrap、unwrap 和 full-fill 检查都会进入报价。
- `pseudoTotalValueLocked(PoolId)` 返回 inner 当前 active liquidity 的 virtual-depth proxy。它不是可提款 TVL，也不是 PoolManager 全局 token balance。
- `AggregatorPoolRegistered` 和 `HookSwap` 保留通用索引事件。

这些接口和标准 `PoolKey` 足以让通用 v4 quoter 执行该池，但不等于 0x、Uniswap 或其他 solver 一定会自动发现并放入候选集。部署后的验收必须读取真实 API quote response，确认 route 中出现 outer PoolId / Hook 地址；“交易能成功”与“聚合器已收录”是两个状态。

## 已验证

本地真实 PoolManager 集成覆盖：

- wrapper 地址排序同向和反向；
- exact-in / exact-out × 双向；
- Hook quote、direct inner quote 和实际成交逐 wei 一致；
- outer liquidity 为 0，outer slot0 不移动，inner slot0 确实移动；
- Hook 四种 ERC-20 余额和四种 transient delta 回到 0；
- 现有 origin/FewToken wrapper 池的 slot0 和 liquidity 不变化；
- PoolManager origin token 物理余额在 router 结算后恢复；
- partial fill、库存不足、非极值 limit、非空 hookData、恶意 wrapper 重入和假返回值全部原子回滚。

Ethereum mainnet 固定块 `25,833,244` 还验证了真实：

- inner `fwUSDC/fwUSDT` PoolId `0x6199c1a871328a693bbc9cd80a7e4874a4a7e2ebc862b51fa04bb6b587dbac47`；
- wrapper pools `fwUSDC/USDC` 和 `USDT/fwUSDT`；
- USDC/USDT 双向 exact-in / exact-out 四组 quote 与实际成交一致；
- 两个 wrapper pool 的 slot0 和 liquidity 均未变化。

以上只证明固定块上的合约执行和会计，不代表当前流动性、部署安全或聚合器收录。

## 部署顺序

本节只在完成独立安全审计并确认官方 routing 接入方式后执行。

1. 审计 `src/FewV4ShellHook.sol`，不要沿用现有 FewV2 Hook 的审计结论。
2. 在目标块重新跑 fork、库存和各 size quote 矩阵。
3. 用 `script/MineFewV4ShellHookAddress.s.sol` 读取 inner 池并生成当前 init code 对应的 salt/address。
4. 人工核对 factory、quoter、PoolManager、inner PoolId、fee、tick spacing 和 Hook mask。
5. 用 `script/DeployFewV4ShellHook.s.sol` 部署并初始化 outer pool；先只做 USDC/USDT 单 pair。
6. source verify 后，用 Universal Router 和生产 0x quote API 做双向、多个金额档的 read-only 验证。
7. 只有 API 返回结果明确包含该 Hook route，才能把状态改成“已被聚合器考虑”；看到真实成交后才能改成“已有流量”。

CREATE2 地址绑定完整 init code，也包含 Solidity metadata。挖地址和部署必须使用完全相同的 Foundry、Solc、optimizer、`bytecode_hash` 和源码；任一项变化都要重新挖 salt。本机 Foundry 1.5.1 默认运行 script 若报 `No contract bytecode`，已验证可在挖地址和部署 dry-run 两步都加 `FOUNDRY_BYTECODE_HASH=bzzr1 --force`，不能只在其中一步加。

停止条件：任何残余 delta/余额、partial fill 被接受、wrapper 非严格 1:1、inner PoolId 可变、PoolManager origin 库存不足、quote 与执行不一致，或生产 solver 不返回该 route，均不进入资金部署阶段。
