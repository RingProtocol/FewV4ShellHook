# FewV4NettingShellHook 库存估算说明

## 1. 需要存哪些库存？

Netting 版本不是只存 `fewToken`，而是要在 PoolManager 中维护 **4 个 ERC-6909 claim 库存**（以 ETH/WBTC 壳池为例）：

```text
origin ETH  claim  <->  fewWETH claim
origin WBTC claim  <->  fewWBTC claim
```

一笔 A -> B swap 同时影响 4 个库存：

| 变化 | 说明 |
|------|------|
| 消耗 `fewA` claim | 支付给真实 LP 池作为 swap 输入 |
| 增加 `fewB` claim | 从 LP 池收到的 swap 输出 |
| 增加 `originA` claim | 收到用户支付的底层 token |
| 消耗 `originB` claim | 把底层 token 付给用户 |

因此，**只存 fewA/fewB 是不够的**。例如只做 ETH -> WBTC 时，还需要有足够的 `originWBTC` claim 才能给用户付款；否则交易会 `InsufficientClaim` 失败。

## 2. 库存会不会被消耗完？

会，取决于订单流的平衡性。

### 平衡流（两种方向交易量接近）

```textnETH -> WBTC 消耗：fewWETH  + originWBTC
        增加：fewWBTC + originETH

WBTC -> ETH 消耗：fewWBTC + originETH
        增加：fewWETH  + originWBTC
```

两种方向交替发生时，四个库存大致自我对冲，可以循环很长时间。

### 单向流（连续同方向 swap）

连续 ETH -> WBTC 会把 `fewWETH` 和 `originWBTC` 一直消耗；连续 WBTC -> ETH 则相反。一旦某条库存归零，后续同方向 swap 会立即失败。

### 手续费净流出

由于 LP 池收取手续费，`amountOut < amountIn`，长期来看即使方向平衡，库存总量也会缓慢减少。需要 owner 调用 `rebalancePair()` 补充。

## 3. 存 1w 够不够？

不能一概而论，取决于三个因素：

1. **单笔最大 swap 量**  
   库存必须至少 >= 单笔最大输入，否则单笔就会失败。

2. **连续同方向笔数 / rebalance 频率**  
   例如平均单笔消耗 0.01 ETH 等值的 fewWETH，连续 1000 笔同向就需要 10 ETH。如果不希望频繁 rebalance，就要多存。

3. **再平衡成本**  
   Fork 测试里，冷状态 `rebalancePair()` 大约 **33 万 gas**（WETH/WBTC）。如果链上 gas 贵，可以适当提高库存阈值、降低 rebalance 频率。

以当前真实成交数据（单笔多在 0.003 ~ 0.08 ETH / 0.00008 ~ 0.001 WBTC 量级）粗略估算：

- 若按 1 ETH + 0.01 WBTC 各存一份，可以扛数百到上千笔同向流。
- 若存 1w 个 fewToken，则要看具体面额；对 WETH/WBTC 这类 1:1 映射的 wrapper，1w 远远超过正常需求。

## 4. 建议上线前做的事

1. **历史订单流回放**
   用 `docs/2026-09-28-mainnet-frontend-traffic.md` 中的真实成交序列，模拟连续 swap，观察哪条 claim 先耗尽、多久需要 rebalance 一次。

2. **设置 rebalance 阈值**
   不要等到库存归零才 rebalance。建议把触发线设在“最大单笔 swap 量的 2~3 倍”。

3. **监控脚本**
   在 `script/monitor-shell-pool.sh` 中增加四个 claim 库存的检查项，低于阈值时报警或自动触发 keeper。

## 5. 与旧 ShellHook 的对比

| 项目 | 旧 ShellHook | Netting ShellHook |
|------|-------------|-------------------|
| 每笔 swap 操作 | 现场 wrap/unwrap | burn/mint claim |
| 需要预先存款 | 不需要 | 需要 owner 预先 deposit claim |
| 库存维护 | 无 | 需要定期 rebalance |
| 单笔用户 gas | ~322k（当前优化后） | 节省 ~98k~137k |
| 适合场景 | 低维护、低频 | 高频、订单流可对冲 |

**结论**：Netting 能显著降低单笔 swap gas，但把成本转移到了 owner 的库存管理和再平衡上。合入前必须先通过历史订单流验证库存规模和 rebalance 频率是否可接受。
