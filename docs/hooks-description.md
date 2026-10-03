# FewV4ShellHook review description

FewV4ShellHook lets an origin-token Uniswap v4 Shell Pool execute against an explicitly approved FewToken LP. A user trades the ordinary tokens; the Hook wraps the input, swaps fwA/fwB in the registered LP, unwraps the output and returns the complete `BeforeSwapDelta` to the Shell Pool.

The Shell Pool is the Uniswap entry and settlement layer. It is not the execution venue and does not add a second LP fee. Price, active liquidity and swap fee come from the registered FewToken LP.

## Route restrictions

- The owner initializes each Shell Pool and registers one complete FewToken PoolKey for its PoolId. This prevents an unrelated account from permanently front-running the reviewed PoolKey with a misleading Shell price.
- Duplicate Shell Pools cannot advertise the same FewToken LP for the same origin-token pair from one Hook. Native ETH and WETH modes remain separate.
- Both LP currencies must be the canonical FewFactory wrappers for the Shell currencies.
- Callers and `hookData` cannot choose or override the execution pool.
- LP hooks using `beforeSwapReturnDelta` or `afterSwapReturnDelta` are rejected.
- Removing a mapping disables that Shell route; there is no automatic fallback.
- The FewToken LP must be initialized, have active liquidity and fully fill the requested exact-input or exact-output trade.

## Discovery and quote interface

```solidity
function pseudoTotalValueLocked(bytes32 poolId)
    external
    returns (uint256 amount0, uint256 amount1);

function quote(bool zeroToOne, int256 amountSpecified, bytes32 poolId)
    external
    returns (uint256 amountUnspecified);
```

`pseudoTotalValueLocked` reports a routing-depth proxy from the registered FewToken LP in origin-token order. `quote` simulates the complete Shell swap through V4Quoter, including the FewToken swap, wrap/unwrap, inventory, backing and full-fill checks. Negative `amountSpecified` is exact input; positive is exact output.

## Permissions and administration

Hook permissions: `beforeInitialize`, `beforeSwap`, `beforeSwapReturnDelta`.

The contract is non-upgradeable. It has no fee, sweep or LP-withdrawal function. A two-step owner can register/remove routes and transfer ownership. Production ownership is intended for a Safe multisig.

PoolManager, FewFactory, WETH9 and V4Quoter are immutable constructor dependencies. Each must contain code, and V4Quoter must point to the configured PoolManager. Wrap/unwrap enforce exact wrapper-backing changes; unexpected ETH senders are rejected.

## Validation status

All 97 local and fixed-block tests passed again on October 3, 2026. They cover both directions, exact input/output, native ETH/WETH, quote parity, inventory/backing failures, under-transfer rollback, forced ETH dust, fake wrappers, dependency mismatch, unauthorized initialization, duplicate routes, nested-Hook reentrancy, route removal and residual balances. A fixed-block Ethereum fork executes 24 Universal Router combinations across ETH/WBTC and WETH/WBTC and verifies slippage rollback; the three Router tests also passed with `--isolate`. The historical latest-state fork run used block `26,087,184` on September 30, 2026.

The code is unaudited. Source review, deployment approval, route discovery and default frontend selection remain separate review steps.
