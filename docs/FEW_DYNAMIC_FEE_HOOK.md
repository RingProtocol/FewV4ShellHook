# FewDynamicFeeHook Implementation and Tests

## Behavior

`src/FewDynamicFeeHook.sol` is an independent, non-upgradeable fw LP Hook. It uses two-step ownership transfer. The owner can configure and update each pool's min/base/max LP fees. Its permissions are limited to beforeInitialize and beforeSwap; it has no asset custody, withdrawal method, or return delta.

All callers use the same fee policy, including FewV4ShellHook and direct fw swaps. Each beforeSwap reads the current pool price and the wrappers' actual underlying balances. It does not use a cache, oracle, totalSupply, or caller-supplied balances. A direct fw swap does not itself wrap/unwrap, so a discount does not guarantee replenishment.

Configuration contains only three E6 fees (1000 = 0.1%). There is no sensitivity setting, deadband, or pause. Both inventories being zero returns maxFee. Fee queries do not guarantee sufficient underlying assets for unwrapping.

## Formula and boundaries

Under the raw-unit 1:1 conversion convention, let P be the fw LP raw token1/token0 price, V0=B0*P, and V1=B1:

```text
signedSkew = (V1 - V0) / (V1 + V0)
strength = abs(signedSkew)
lowFee = baseFee - strength*(baseFee-minFee)
highFee = baseFee + strength*(maxFee-baseFee)
```

Positive signedSkew means token1 is relatively abundant, so token0->token1 receives the lower fee. Negative signedSkew reverses the assignment.

| P | B0 | B1 | token0 -> token1 | token1 -> token0 |
|---:|---:|---:|---:|---:|
| 1 | 100 | 0 | 0.3000% | 0.1000% |
| 1 | 100 | 25 | 0.2600% | 0.1400% |
| 1 | 100 | 50 | 0.2334% | 0.1667% |
| 1 | 100 | 100 | 0.2000% | 0.2000% |
| 1 | 100 | 200 | 0.1667% | 0.2334% |
| 1 | 100 | 400 | 0.1400% | 0.2600% |
| 2500 | 1 | 2000 | 0.2112% | 0.1889% |
| Any valid price | 0 | 0 | 0.3000% | 0.3000% |

The table uses 1000/2000/3000 pips. Different trade sizes receive the same fee at the same pre-swap state, but produce different amounts, price impact, and subsequent fee states.

## Numerical implementation

FwInventoryFeeMath scales both balances by a common power of two so the larger balance occupies 224 bits, then converts the cheaper asset into units of the more expensive asset. Each conversion ratio is no greater than one. Two mulDiv operations use sqrtPrice without squaring it; the sum of values occupies at most 225 bits.

The valid price range is [TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE). Even at the extremes, the conversion ratio is greater than approximately 2^-128, leaving a scaled total value of at least approximately 2^95. Two nonzero inventories therefore cannot both truncate to zero. Common-scaling and conversion errors are much smaller than one E18 skew unit; skew is then truncated toward zero to E18 precision. The final fee allows up to one pip of rounding difference from ideal real-number arithmetic. Exact rounding at every real-number boundary is not claimed.

Zero inventory is detected using the original balances. Final fees round upward relative to the quantized skew. The maximum LP fee is 999998 pips to avoid the combined protocol fee reaching 100%. Applications should still choose their intended narrow fee range.

## Integration

1. Use HookMiner with BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG to mine an address and deploy FewDynamicFeeHook(manager, factory, owner).
2. Create a PoolKey with fwToken addresses in ascending order, fee=DYNAMIC_FEE_FLAG, and hooks set to the new Hook.
3. The owner calls configurePool(key, Config(1000,2000,3000)). This validates canonical wrapper/underlying identity, not equality between global supply and inventory.
4. The owner calls PoolManager.initialize directly, then adds fw LP liquidity.
5. The Shell owner calls the existing setLpPool(shellKey,key) to route trades to the new pool.

An existing static pool cannot change its PoolKey in place; create a dynamic pool and migrate liquidity. A multisig owner can perform these calls directly. A third-party initialization router is not the owner and will be rejected.

getFee(key) returns the two E6 fees. getFeeState(key) additionally returns E18 signed skew, sqrtPrice, and both raw backing balances. Queries revert for unconfigured or uninitialized pools.

## Running tests

```sh
forge test --match-path test/FwInventoryFeeMath.t.sol -vv
forge test --match-path test/integration/FewDynamicFeeHook.t.sol --match-test test_dynamic -vv
forge test --no-match-path 'test/fork/*'
```

Mathematical tests cover the inventory table, WETH/USDC decimal differences, asymmetric fee ranges, zero/fixed fees, extreme prices, and uint256 balances. Fuzz tests cover bounds, monotonicity, reversed-direction symmetry, and an independent rational-arithmetic oracle.

Integration tests cover 3 inventory ratios × 5 amounts × 2 directions × exact-input/exact-output, totaling 60 Shell execution scenarios. Additional checks cover fee overrides for different callers and signed amounts, same-block live inventory, replenishing an empty side, atomic failure, and configuration permissions.

Local validation on 2026-10-16: forge test --no-match-path 'test/fork/*' -vv completed with 201 passing tests and zero failures. Additions include 7 mathematical tests (3 fuzz tests with 10,000 runs each) and 5 dynamic Hook integration tests. The total includes inherited Shell regression tests executed again to reuse their fixture; it does not represent 201 new tests. The 60 trade combinations are contained in one matrix test. RPC-dependent fork tests were not run. New Solidity files passed forge fmt checks. Compilation still reports that the existing Shell pseudoTotalValueLocked function could be marked view.

This is the recorded implementation validation; translating these documents does not constitute a new test run.

## Known limitations

The fee is fixed for each swap and is not recalculated during execution. Large trades may cross inventory balance. Both pool price and backing change with trades, so imbalance is not guaranteed to decrease after every swap.

Shared global wrappers, spot manipulation, splitting, and wrapping before swapping affect outcomes. Full economic evaluation and production auditing remain outstanding. Test mocks permit artificial low-backing states to cover non-fully-backed conditions; this does not establish the mechanics of production FewToken contracts.
