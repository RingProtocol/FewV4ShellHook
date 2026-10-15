# fw Pool Inventory-Balancing Dynamic Fee Hook

> Status: Requirements and design review
>
> Updated: 2026-10-16

Implementation status: `FewDynamicFeeHook` and `FwInventoryFeeMath` are implemented. See the [implementation guide](FEW_DYNAMIC_FEE_HOOK.md) for APIs, deployment steps, fee examples, and tests. The first version uses live state, a uniform fee policy for all callers, three min/base/max parameters, and maxFee when both inventories are zero. It does not include a deadband, sensitivity setting, pause, cache, or oracle. Other options below remain subjects for future review.

Confirmed requirements: restore underlying inventory balance; read pool price and backing before every swap; charge the minimum fee for replenishing an empty side. Implementation choices and suggested production parameters are distinguished from these confirmed requirements.

## 1. Objective

The Shell Pool in `FewV4ShellHook` does not execute its own curve. Swaps execute in the registered fw LP and settle through 1:1 wrap/unwrap operations. The dynamic fee objective is to **use the fw LP market price to value backing and encourage Shell trades that replenish the scarce underlying asset, moving the two sides toward equal market value.**

Fees provide an economic incentive, not a guarantee of convergence. Results also depend on order flow, pool depth, price changes, arbitrage, and whether the fee difference is meaningful.

## 2. Direction of the incentive

Define:

```text
P  = fw LP market price, expressed as token1 per token0
B0 = underlying0 backing held by the fwToken0 wrapper
B1 = underlying1 backing held by the fwToken1 wrapper
V0 = B0 * P, expressed in token1 value
V1 = B1
```

The target is `V0 = V1`, equivalently `B1/B0 = P` when B0 is nonzero.

For `P = 2500 USDC/WETH` and backing of `1 WETH + 2000 USDC`, V0 is 2500 and V1 is 2000. USDC is relatively scarce:

- `USDC -> WETH` increases USDC backing and decreases WETH backing, so it receives the lower fee.
- `WETH -> USDC` consumes more USDC backing, so it receives the higher fee.

The example `10:25000` expresses market price, not the actual token quantity ratio of a concentrated-liquidity position. The marginal price comes from slot0; position quantities also depend on the position's price range.

## 3. Linear fee model

Use a bounded value imbalance rather than dividing one inventory ratio by another:

```text
S = |V1 - V0| / (V1 + V0)       // 0 <= S <= 1
```

S is zero at equal value and one when exactly one side is empty. It never divides by an individual side's zero balance.

Conceptual configuration, including optional future parameters:

```solidity
struct FwDynamicFeeConfig {
    uint24 minFeeE6;
    uint24 baseFeeE6;
    uint24 maxFeeE6;
    uint24 deadbandE6;     // Optional
    uint24 sensitivityE6;  // Optional; 1e6 means strength = S
}
```

The implemented configuration is `FwInventoryFeeMath.Config(minFee, baseFee, maxFee)`. It exposes only three parameters, equivalent to deadband=0 and sensitivity=1. Optional parameters should be considered after simulation.

`maxReferenceAge` is excluded: live pool state and balances do not give this field a useful role in the current model.

If optional parameters are added, validate `0 <= deadband < 1` and `sensitivity >= 1` so an empty side always reaches the fee limits. Normalize E6 parameters by 1e6 before applying the formulas; 1 below means the real-number unit. Fees must satisfy `0 <= min <= base <= max` and the protocol fee ceiling.

```text
effectiveS = max(S - deadband, 0) / (1 - deadband)
strength   = min(effectiveS * sensitivity, 1)

encouragedFee  = baseFee - strength * (baseFee - minFee)
discouragedFee = baseFee + strength * (maxFee - baseFee)
```

| State | token0 -> token1 | token1 -> token0 |
|---|---:|---:|
| V0 > V1: token1 is scarce | Higher fee | Lower fee |
| V0 < V1: token0 is scarce | Lower fee | Higher fee |
| V0 == V1 > 0 | baseFee | baseFee |
| V1 == 0, V0 > 0 | maxFee; Shell output cannot unwrap | minFee |
| V0 == 0, V1 > 0 | minFee | maxFee; Shell output cannot unwrap |

When both sides are zero, the ratio is undefined. The implementation returns maxFee in both directions; existing inventory checks determine whether a Shell trade can execute. Pausing would be a separate future policy, not an existing feature.

Example with min/base/max = 0.1% / 0.2% / 0.3%, no deadband, and sensitivity=1:

```text
P=2500, B0=1, B1=2000
S=500/4500=11.111...%
USDC -> WETH = 0.188889...%
WETH -> USDC = 0.211111...%
```

These are mathematical values. A v4 E6 fee unit is 0.0001 percentage points. With final upward rounding, this example produces 1889 / 2112 pips, or 0.1889% / 0.2112%. The mapping is linear in S, not in either asset's raw quantity. See the implementation guide for intermediate quantization and its error allowance.

A future sensitivity parameter can strengthen the incentive at the same imbalance without introducing asymmetric division by a potentially empty inventory.

## 4. Price source and numerical requirements

Each fw Hook `beforeSwap` reads the current `slot0.sqrtPriceX96` and both wrappers' current backing. There is no start-of-block fee, price, or inventory snapshot. Every subsequent call reads again, including calls within the same block or transaction.

The price represents a raw token unit ratio. With strict raw-unit 1:1 conversion between wrappers and underlyings, it can be combined directly with raw backing balances; decimals affect display formatting.

Do not square sqrtPriceX96 without range checks. Use common scaling or wide-precision arithmetic. A single mulDiv does not automatically solve a V0 larger than uint256, an overflowing V0+V1, or a nonzero value rounding to zero. Identify empty inventories from the original B0/B1 balances, not truncated values. Specify supported price/balance ranges and error bounds, and test extreme prices, 6/8/18 decimals, reversed token order, and rounding. Unsupported inputs must fail explicitly.

Spot prices can be manipulated. Fee limits bound fee exposure and canonical validation establishes wrapper identity; neither proves the price is economically accurate. Manipulation costs and benefits require evaluation. TWAP/oracle dependencies are outside the MVP, and split versus unsplit trades are not promised identical fees.

The actual execution order is:

1. Shell calls the inner fw swap.
2. fw beforeSwap reads pre-swap state.
3. The fw curve executes.
4. Shell checks inventory.
5. convertAndSettle wraps the input and unwraps the output.

The current input has not been wrapped when the fee is calculated. This is explicitly pre-swap pricing. The inner afterSwap also runs before final backing settlement and cannot verify the final inventory recovery. By the next normal Shell call, the previous settlement has completed.

## 5. Limitations and design tradeoffs

### 5.1 The target moves during a recovery trade

When USDC is scarce, USDC -> WETH increases the backing ratio and usually also increases the fw LP token1/token0 price. The actual ratio and its target may rise together. If the pool is shallow relative to backing, P can move faster and the imbalance can increase.

A discounted direction therefore does not guarantee improvement after every swap. The approach is to:

1. Re-read P and backing for each swap and price the pre-swap relative shortage.
2. Simulate state evolution across different pool depths and backing sizes.
3. Consider post-swap simulation in a later version, granting recovery discounts only when predicted S_after is below S_before.

### 5.2 A single fee does not handle crossing the balance point

beforeSwap returns one fee for the entire swap. A large trade may restore balance and then make the other asset scarce while retaining its original discount. The MVP accepts this limitation. A later version could simulate the final state, limit execution near balance, or calculate an equivalent fee across the path.

### 5.3 Direct fw swaps do not necessarily replenish backing

Direct fwToken0 <-> fwToken1 swaps do not themselves wrap or unwrap. Two policies are possible:

- Apply the same inventory fee to all swaps, accepting that a discount does not always replenish backing immediately.
- Apply inventory fees only to swaps initiated by trusted FewV4ShellHook contracts and charge baseFee otherwise.

The implementation adopts the first policy. It supports permissionless integration, separate wrap/swap/unwrap paths, and router compatibility. Shell-only discounts would tie the incentive to verifiable atomic inventory changes, but introduce trusted-caller administration, route-dependent pricing, and more complex quoting.

If caller-specific pricing is introduced, verify sender behavior through integration tests. sender identifies the contract calling PoolManager, not the end user. Do not trust tx.origin or user-provided hookData as proof of Shell identity.

A direct fw swap changes P and may change the imbalance signal without changing backing. Pre-wrapping before a swap and swapping before unwrapping can produce different fee states; uniform caller policy does not imply identical economic outcomes for both sequences.

### 5.4 Global backing versus a per-pool price

underlying.balanceOf(wrapper) is global, while P belongs to one PoolId. Shared wrappers create cross-pool fee effects. The MVP accepts this global inventory definition rather than imposing a one-wrapper/one-pool restriction. A Hook allowlist could not prevent the wrapper from being used elsewhere anyway.

Per-pool isolation requires asset ownership and settlement accounting; it cannot be inferred by simply allocating global backing according to pool fw balances. Consistent cross-pair prices may make the equal-value targets compatible. Divergent prices may create conflicting incentives and require cross-pool testing.

### 5.5 Backing and total supply have different meanings

The supplied requirements state that fw supply and backing are not necessarily equal. A 1:1 conversion for an individual wrap/unwrap does not imply global backing equals totalSupply.

The working interpretation is that total fw supply may be greater than or equal to underlying inventory, while the fw quantity associated with a particular pool may be smaller than that inventory. The exact relationship and its mechanism need verification against the production FewToken implementation.

Verify:

- The permitted relationship between fwToken.totalSupply() and underlying.balanceOf(wrapper).
- Whether direct donations change backing without changing supply.
- Whether lending, losses, shared accounting, or other mechanisms explain differences.

This model uses physical underlying inventory and does not depend on supply equality. Conversion rate, global backing coverage, and pool execution depth are separate metrics. totalSupply may support coverage diagnostics but is not part of the fee formula.

### 5.6 The fee spread may be too small to change behavior

The 0.1%–0.3% range creates at most a 20 bps difference. Market spreads, gas, MEV, or opportunities in other pools may dominate this incentive. Fee ranges and any future sensitivity setting need calibration using realistic simulations.

## 6. Architecture and deployment

An independent FewDynamicFeeHook is attached to the actual fw LP:

- Shell custom accounting bypasses the Shell's own curve and LP fee.
- The current Shell rejects dynamic-fee Shell Pools.
- setLpPool preserves the inner Hook, so nested swaps invoke the fw Hook.

The implementation consolidates the proposed responsibilities into:

```text
FewDynamicFeeHook.sol       // Configuration, permissions, initialization, live reads, fee queries
FwInventoryFeeMath.sol     // Safe value conversion, imbalance, direction, linear fees
```

The local v4-hooks-public/src/stable/StablePairHook.sol provides a useful reference for zero return delta, bidirectional fee queries, and OVERRIDE_FEE_FLAG. Its block cache, exponential decay, and UUPS governance are not requirements for this Hook.

The new Hook requires a separate deployment with matching permission bits. An existing static-fee fw LP cannot change its PoolKey fee/hooks in place. Deploy a new dynamic-fee fw LP, migrate liquidity, and update the Shell route through setLpPool. This migration is part of deployment planning.

## 7. Functional requirements

1. Configure only dynamic-fee fw PoolKeys; validate the Hook, canonical wrappers, underlyings, and dependency code.
2. Preserve getFee(PoolKey)'s two E6 fee returns. Provide a separate diagnostic view for imbalance, raw backing, and price. Any future caller-dependent policy needs caller-aware quoting.
3. beforeSwap returns a fee override without modifying swap deltas.
4. With one empty side, replenishing it receives minFee and consuming it receives maxFee.
5. Define an explicit fallback for two empty sides.
6. Emit configuration-change events. Any future pause feature must emit events and must not block LP exits. There is no snapshot reset.
7. Shell retains wrap/unwrap, full-fill, backing, and settlement inventory checks.
8. Combined LP and protocol fees must remain below v4's non-executable boundary; StableFeeCalculation's ceiling is a useful reference.

## 8. Acceptance criteria and testing

Mathematical properties:

- minFee <= fee <= maxFee.
- Equal positive values produce baseFee in both directions.
- Increasing scarcity lowers the replenishing fee and raises the consuming fee.
- A single zero inventory reaches the exact fee limits.
- Reversing token order preserves economic symmetry within documented rounding tolerance.
- Supported ticks and balances do not cause overflow, division by zero, or unbounded truncation error.

Integration scenarios:

- Both Shell directions and exact-input/exact-output swaps.
- Fee quotes agree with execution for the same state, configuration, and path.
- getFee reports fees, not executable capacity. Use full Shell quote simulation and router slippage limits.
- Same-block sequential Shell trades read backing after the previous settlement; an empty USDC inventory immediately yields the minimum fee for replenishing USDC.
- Backing increases by the input and decreases by the output.
- Insufficient backing or settlement inventory reverts atomically.
- Direct fw swaps, same-block splitting, block transitions, spot manipulation, donations, and shared wrappers.
- Large trades crossing balance, tick crossings, and rollback.

Economic simulations should cover backing larger than, comparable to, and smaller than fw LP depth; stable and volatile pairs; and one-way, alternating, and arbitrage flow. Compare average imbalance, depletion probability, failed trades, and user/LP costs against fixed fees. Formula correctness alone does not establish economic effectiveness.

These are acceptance and review targets. The implementation guide records which automated tests have actually been executed.

## 9. Development stages

1. Verify production economic mechanics: backing versus supply, donations, shared wrappers, and direct fw swap behavior.
2. Validate the mathematical library and simulate realistic depth to calibrate fees.
3. Implement live reads, configuration, permissions, diagnostics, Shell integration tests, and a new-LP migration plan.
4. Evaluate future TWAP/oracle checks, post-swap simulation, balance-crossing treatment, and per-pool accounting.

## 10. Implementation choices and remaining production decisions

The first implementation uses:

- Live spot price and live backing, without block snapshots.
- Uniform fees for Shell and direct callers.
- Three min/base/max parameters; suggested deployment values are 1000/2000/3000 pips.
- No deadband or sensitivity setting.
- maxFee in both directions when both inventories are zero.
- One fixed fee per swap, recalculated for the next call.
- No simulation of a large trade crossing the balance point.

Before production deployment, verify the actual FewToken supply/backing mechanism, enumerate pools sharing wrappers, review the uniform caller policy, select fee parameters, and assess the accepted large-trade and spot-price limitations. Future oracle integration is a separate enhancement, not an unresolved MVP price-source choice.
