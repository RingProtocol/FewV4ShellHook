# FewToken v4 Shell Pool

Updated: 2026-09-16. PR #10 is based on `optimize@3e100adc09ed277c97e6f61954a50a2a574afc8c`, after PR #9 merged. Its deployed bytecode, external audit and production routing have not been verified. Older deployment or test statements do not certify this candidate.

## Execution and fees

An origin-token A/B shell routes all swaps through its configured FewToken fwA/fwB v4 LP pool. The inner swap creates the input/output deltas; the hook takes origin input from PoolManager, wraps and settles the FewToken input, takes the FewToken output, unwraps it and settles origin output. The returned before-swap delta consumes the entire shell request. The shell never becomes the fallback execution venue.

All swap execution and LP fees remain in the internal LP pool. The hook adds no fee. Shell LP is permissionless and does not earn fees from these redirected swaps; it supplies origin inventory to the shared PoolManager. Its position holder can remove it through v4 core.

## Routing and settlement behavior

| Property | Behavior |
|---|---|
| Routes | Owner-set LP mapping, or FewFactory inference when the mapping is absent |
| Explicit LP pool | May use a different fee/tick spacing and its own hook; the existing beforeSwapReturnDelta registration restriction remains |
| Automatic route | FewFactory wrappers, shell fee/tick spacing, hookless LP pool |
| LP depth | The internal pool must have active liquidity; shell liquidity is not the execution depth |
| Native ETH | Atomic ETH/WETH/FewWETH conversion remains supported |
| Trade types | Exact-input and exact-output; both must fill completely |
| Caller data | `hookData` is ignored and cannot select a route; the calling router enforces deadlines and amount limits |
| Price limits | Shell limits are mapped into the internal pool's currency order |
| Administration | Transferable owner can set/remove LP mappings; no upgrade, sweep, added fee, or pause |
| Permissions | `beforeInitialize`, `beforeSwap`, `beforeSwapReturnDelta` (`0x2088`) |

## Quote and payment order

`quote(bool,int256,PoolId)` now calls V4Quoter with the shell key. It checks the same wrapping, backing, input inventory and full-fill conditions as a standard postpaid shell swap. Failed execution is not returned as a successful quote. Zero amounts and magnitudes above `type(int128).max` are rejected before casting.

The quoter's callback runs the actual shell hook, then reverts to recover the price. Inner hooks receive the shell hook as their sender in both quotes and execution, including when their fees depend on that sender. Pool state, wrapper balances, allowances and settlement writes made during that callback do not persist.

For a PoolManager starting with 1 input token and an order spending 10:

- `SWAP -> SETTLE -> TAKE` fails the input inventory check. A standard shell quote also fails.
- `SETTLE -> SWAP -> TAKE` can succeed after the router deposits the user's 10 tokens. No extra protocol capital is implied by this execution order.
- The output does not come from the shell's initial output-token balance. It comes from redeeming the internal swap's FewToken output, so that wrapper must have sufficient underlying backing.
- Native ETH and WETH balances are separate. The relevant balance is the exact shell currency in the entire shared PoolManager.

A successful internal LP price alone cannot establish that a prepaid production transaction is executable. Integrators must simulate their complete calldata; this hook's standard `quote()` does not promise prepaid discovery when starting inventory is insufficient. Supporting postpayment with zero origin inventory requires a separate capital/settlement design and is outside this patch.

## Discovery and acceptance

`pseudoTotalValueLocked` remains an active-liquidity depth proxy in shell-token units, not withdrawable TVL or a settlement limit. `AggregatorPoolRegistered` is emitted during shell initialization. `LpSwap` identifies shell and actual execution pool. PR #7's `HookSwap` ABI declaration is not an emitted fill event in this candidate.

Uniswap must approve the actual deployment and configure its discovery/retention path. A zero-liquidity shell may need ZLCA/TVL-bypass treatment or explicit external-depth integration. None of these configurations funds a swap or guarantees a competitive quote.

Validation is recorded in [PR7_SETTLEMENT_FIX.md](PR7_SETTLEMENT_FIX.md). Final production acceptance requires the target shell to be discovered, the exact transaction to simulate successfully with measured gas and slippage, and a frontend fill that executes in the intended FewToken pool.

## Deployment boundary

Source publication does not deploy or fund a contract. Any source change changes deployment bytecode; mine and verify a fresh compatible address for the final reviewed build. Use the owner-aware deployment script and explicitly verify its constructor inputs and owner. Existing deployment addresses do not inherit this source update.
