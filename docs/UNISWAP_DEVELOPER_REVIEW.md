# FewV4ShellHook: Uniswap Developer Review

Date: September 1, 2026

Repository: [RingProtocol/FewV4ShellHook](https://github.com/RingProtocol/FewV4ShellHook)

## Review request

`FewV4ShellHook` creates a zero-liquidity origin-token shell pool. In `beforeSwap`, it wraps the input, swaps through one constructor-approved hookless FewToken v4 pool, unwraps the output, settles every Hook-owned PoolManager delta, and returns a delta that replaces the outer swap.

The design uses existing FewToken v4 liquidity instead of external FewV2 liquidity. It is therefore different from `RingAggregatorHook` even though both expose an origin-token shell PoolKey.

## Code scope

- `src/FewV4ShellHook.sol`
- `src/interfaces/IAggregatorHook.sol`
- `test/integration/FewV4ShellHook.t.sol`
- `test/fork/FewV4ShellHookFork.t.sol`
- `script/MineFewV4ShellHookAddress.s.sol`
- `script/DeployFewV4ShellHook.s.sol`

## Current status

- Standalone review package prepared for external review.
- Unit and integration coverage includes exact input, exact output, both directions, wrapper validation, reentry, and settlement reconciliation.
- A fixed-block fork harness uses the real fwUSDC/fwUSDT pool and checks that wrapper-pool state remains unchanged.
- No independent audit, deployment, Labs discovery, quote selection, or production traffic has been verified.

## Questions

1. Does the current Labs routing policy support a zero-liquidity shell that replaces the outer swap through `beforeSwapReturnDelta`?
2. Is this mechanism expected to use the official aggregator-hook interface even though the inner liquidity source is another v4 pool rather than an external AMM?
3. How should Ring declare the inner PoolId so the router never selects the same FewToken liquidity as a separate hop in the same route?
4. Does UniRoute allow a quote implementation to simulate the inner v4 swap through `staticcall`, and which revert format should encode the result?
5. Is constructor-fixed inner-pool allowlisting sufficient, or does Uniswap expect an assigned protocol ID, official base contract, codehash registry, or factory provenance?
6. The outer shell relies on physical origin-token inventory already held by the PoolManager singleton for the atomic conversion leg. Is this a supported invariant, or should the design source settlement inventory another way?
7. Which Universal Router exact input, exact output, split-route, and multi-hop cases must pass before this Hook can be considered for routing?
8. What PoolKey fields should be canonical for a shell whose actual price and liquidity come from the inner pool?
9. How should pseudo-TVL and gas be reported so the router sees the inner pool's real capacity without double counting it?
10. Would Uniswap prefer this implementation in `v4-hooks-public`, or should Ring keep it independent until the shared-depth routing model is supported?

## Requested outcome

Ring needs a decision on support for return-delta shell pools, the shared-depth declaration model, and the correct official code path before deployment.
