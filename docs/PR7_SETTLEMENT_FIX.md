# PR #7 报价与结算修复

日期：2026-09-16。已 rebase 到合并 PR #9 后的 `optimize@3e100adc09ed277c97e6f61954a50a2a574afc8c`。本补丁保持原资金模式：修复完整报价，验证预付款成交，未引入独立 FewToken 周转库存或 Claims 回收系统。

## 已修复的问题

原 PR 的 `quote()` 仅模拟内部 FewToken 池，PoolManager 输入原币不足或输出 FewToken 缺底层资产时仍可能返回报价，而实际壳池交易会回滚。

现在 `quote()` 使用原币 Shell PoolKey 调用官方 V4Quoter，执行完整内部交易、库存检查、wrap、unwrap 和 full-fill 检查，再由 Quoter 回滚模拟状态。报价和 swap 共用非零、signed-int128 金额范围约束，避免报价金额截断。壳池初始化恢复 `AggregatorPoolRegistered` 事件，供依赖该 ABI 的发现程序使用；这不代表 Uniswap 已配置接入。

原补丁覆盖缺输入原币、缺可解包输出的错误报价。此次针对 PR #9 的两个未完成修复补充回归：

- Quoter 的 exact-in 会先转成 int128，原 uint128.max 检查仍可能让 `2^128-1` 输入变成 exact-out 1。现在 quote 与 swap 在取绝对值和转换之前共同校验非零 signed-int128 范围，覆盖双方向、正负边界和 int256.min。
- 内池 Hook 可以按 sender 调整费率。完整壳池模拟让内池收到的 sender 与实际交易相同，都是 FewV4ShellHook。新增测试使用对直接 Quoter 调用优惠、对壳池收费更高的动态费率内池，在双向 exact-in/out 四种组合中验证报价与钱包收付完全一致，并确认报价状态回滚。

## 保留的行为

| 项目 | 本地验证 |
|---|---|
| 全部成交走 FewToken v4 池 | 原有自动/手工配置路由测试通过，壳池价格不参与执行 |
| 内池报价优势、无新增手续费 | 内池执行函数未改，报价与实付实收逐单位相符 |
| 不同 fee/tickSpacing 的内池 | 显式映射保留，新增报价与成交对照 |
| 带 Hook 的内池 | 保留当前基线允许的显式映射；no-op 与按 sender 定费的 Hook 均验证报价对照；PR #9 的 beforeSwapReturnDelta 注册限制未在本补丁中修改 |
| 原生 ETH | 保留 ETH/WETH/FewWETH 转换，双向 exact-in/out 对照通过 |
| 任意人添加 Shell LP | 权限与行为不变，原有测试通过 |
| Exact-in / exact-out 全额成交 | 无部分成交兜底，双向验证 |
| 预付款接大于初始库存的订单 | 初始 0 或 1 个输入币，先付款再成交 10 个币；原生 ETH 零余额也验证通过 |
| 管理与资金权限 | 路由配置、owner、结算、资金去向不变，无新增 sweep/upgrade/fee 权限 |

相对最新 optimize，`setLpPool`、`_deriveLpRoute`、`_executeLpSwap`、`getHookPermissions`、`pseudoTotalValueLocked`、`_requireSettlementInventory` 保持原样。构造参数 owner、部署脚本、LpOwner、LpSettlement 和内池注册限制也保留基线行为；旧版补丁中的纯格式差异已由基线吸收。

## 尚未解决的资金边界

本补丁不承诺“PoolManager 原币为零时，任何付款顺序都能成交”。

- 标准 `quote()` 模拟先 swap 后付款，因此资金不足就不报价，避免虚假可执行价格。
- 先付款路径可以用用户当笔资金成交；该路径应通过完整交易模拟进入官方路由，不能将内池单独报价当作执行证明。
- 先 swap 后付款仍需要已有输入库存。支持这种情况下的零原币余额，需要独立周转资金和结算/回收机制；这会改变资本占用和运营方式。
- 独立周转库存与 Claims 回收不在本 PR 范围；本补丁不能描述为完整零余额后付款修复。
- ZLCA/外部深度发现、报价分流、生产交易编码及真实前端成交仍需 Uniswap 验证。

## 验证

- Rebase 后本地集成：74 passed、0 failed、0 skipped（71 个壳池测试、3 个部署 owner 测试），含 10,000 次金额/方向/交易类型 fuzz。
- 主网固定区块 `25,833,244`：真实 fwUSDC/fwUSDT 池 7 个 fork 测试通过，覆盖双向 exact-in/out 报价与成交、零输入原币时预付款成交、壳池零 LP、原币库存恢复与余额检查。
- `forge build --sizes` 通过，FewV4ShellHook runtime 13,320 bytes；编译有原有风格/类型转换提示，不等于外部安全审计。
- `forge fmt --check`、`git diff --check` 通过。
- 使用真实 v4 PoolManager、官方 V4Quoter、v4 测试 router 和逐项执行 SETTLE/SWAP/TAKE 的测试 router；没有声称测试过生产前端实际 calldata。

## 合并顺序与接入条件

本 PR 以已合并 #9 的 `optimize` 为目标分支，供 #7 纳入本次报价与金额边界修复。它不直接合并到 main。上述测试验证的是代码行为，不代表合约已部署或 Uniswap 已接入。

Uniswap 接入时仍需明确实际使用的报价与付款路径。若后续要求完整零余额后付款支持，需要另行设计并审查周转库存/Claims 方案，保留上述路由和成交回归测试；不能直接删除余额检查。

## 参考

- Uniswap UniRoute `d586000d618314861ec1f5a9fd10568120f1fa2a`，`src/core/swap/SwapStepsFactory.ts:477-535`：exact-in 先付款，exact-out 后付款。
- 项目固定依赖 `v4-periphery@ad04c9f24a170accf5ea1b2836bbafd514537ca6`，`src/lens/V4Quoter.sol` 与 `src/base/BaseV4Quoter.sol`：完整 swap/revert 报价及 full-fill 校验。
- PR #7：<https://github.com/RingProtocol/FewV4ShellHook/pull/7>。
