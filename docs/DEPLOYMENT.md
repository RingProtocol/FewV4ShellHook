# Deployment runbook

Updated: 2026-10-03

This runbook deploys a new Hook address. It does not modify the current `0xadef...2088` deployment.

## 1. Prepare

Use a dedicated deployer with enough ETH for gas. Keep the private key and RPC URL outside this repository. Set production ownership to a Safe multisig.

Required local environment variables:

```text
ETH_RPC_URL
ETH_PRIVATE_KEY
HOOK_OWNER
```

The script defaults to the current Ethereum mainnet PoolManager, FewFactory, WETH9 and V4Quoter addresses. If any default is overridden, verify it against the intended network before continuing.

## 2. Test the exact source

```sh
git submodule update --init --recursive
forge fmt --check
forge build --sizes
forge test --offline
forge test --match-path 'test/fork/FewV4ShellHookFork.t.sol' -vv
forge test --match-path 'test/fork/FewV4ShellHookMainnet.t.sol' -vv
forge test --isolate --match-contract FewV4ShellHookMainnetTest -vv
```

Stop if any test fails or if the contract exceeds the EIP-170 runtime-size limit.

## 3. Mine and simulate the Hook address

The mined address depends on the exact bytecode, constructor arguments, deployer and deployer nonce. Do not send another transaction from the deployer between preflight and deployment.

```sh
forge script script/MineFewV4ShellHookAddress.s.sol:MineFewV4ShellHookAddress \
  --rpc-url "$ETH_RPC_URL"

# Save the printed values before continuing:
export HOOK_SALT=<PRINTED_HOOK_SALT>
export EXPECTED_HOOK_ADDRESS=<PRINTED_EXPECTED_HOOK_ADDRESS>

forge script script/DeployFewV4ShellHookWithOwner.s.sol:DeployFewV4ShellHookWithOwner \
  --rpc-url "$ETH_RPC_URL" -vvvv
```

The deployment script recomputes the address from the reviewed salt, current deployer nonce, exact bytecode and constructor arguments. It reverts if anything would produce a different Hook address. The simulation must also verify PoolManager, FewFactory, WETH9, V4Quoter and owner.

## 4. Deploy and verify

Only after simulation and multisig review:

```sh
forge script script/DeployFewV4ShellHookWithOwner.s.sol:DeployFewV4ShellHookWithOwner \
  --rpc-url "$ETH_RPC_URL" --broadcast -vvvv
```

Verify the Hook source using the exact five constructor arguments from the deployment. Record the deployment transaction, bytecode hash, constructor arguments, Hook permission bits and final owner.

Do not fund or announce the Hook until explorer verification matches the local build.

## 5. Create a Shell Pool and FewToken LP

1. Create or select the canonical FewToken LP and add a small canary amount of active liquidity.
2. From the Hook owner Safe, call PoolManager `initialize()` for the origin-token Shell Pool with the new Hook address. Use a static fee. The initial Shell price is metadata only, but it is permanent, so derive and review it immediately before execution. Calls from any other sender revert. Execution price comes from the registered FewToken LP.
3. Add only the origin-token inventory needed for settlement testing. Shell liquidity does not improve the FewToken quote or earn the redirected swap fee.
4. Record both complete PoolKeys: currency order, fee, tick spacing and Hook address.

Multiple Shell Pools with different fee/tick metadata may share the same FewToken LP. Record each Shell Pool independently and avoid double-counting their shared LP depth. Native ETH and WETH Shell Pools may also share one FewToken LP.

Liquidity can use the Uniswap interface where it supports the selected Hook. Shell Pool initialization and the Hook-to-LP mapping are owner transactions and are not normal LP actions.

## 6. Register the FewToken LP

Set these variables with the exact sorted PoolKeys:

```text
SHELL_HOOK
SHELL_CURRENCY0
SHELL_CURRENCY1
SHELL_FEE
SHELL_TICK_SPACING
LP_CURRENCY0
LP_CURRENCY1
LP_FEE
LP_TICK_SPACING
LP_HOOK
```

For native ETH, `currency0` is `0x0000000000000000000000000000000000000000`. Use `LP_HOOK=0x0000000000000000000000000000000000000000` for a hookless FewToken LP.

Prepare and validate the Safe call without broadcasting:

```sh
forge script script/ConfigureLpPool.s.sol:ConfigureLpPool \
  --rpc-url "$ETH_RPC_URL" -vvvv
```

The script checks that both pools are initialized and that the FewToken LP has active liquidity, then prints the target and `setLpPool` calldata. Submit that call through the owner Safe.

If the owner is intentionally an EOA during a local/canary deployment only:

```sh
BROADCAST_CONFIG=true forge script script/ConfigureLpPool.s.sol:ConfigureLpPool \
  --rpc-url "$ETH_RPC_URL" --broadcast -vvvv
```

## 7. Acceptance checks

Before increasing capital:

1. `owner()` equals the intended Safe and `pendingOwner()` is zero.
2. Only the owner Safe can initialize a Shell Pool; an unrelated address fails.
3. `lpPools(shellPoolId)` returns the reviewed LP PoolId, Hook, fee, tick spacing, ordering and wrappers. This release keeps main's cached-field getter ABI; use `LpPoolSet` to recover the original complete PoolKey.
4. Every intended Shell PoolId has its reviewed LP mapping, including any fee/tick variants sharing the same LP.
5. `pseudoTotalValueLocked(shellPoolId)` is nonzero and tracks the FewToken LP's active liquidity.
6. `quote()` works in both directions for exact input and exact output.
7. Complete Universal Router calldata succeeds through `eth_call` with user slippage limits.
8. One small signed canary trade emits `LpSwap` with the expected Shell and FewToken PoolIds.
9. Hook balances return to their starting values.
10. Removing the LP mapping makes quote and swap fail; restoring it resumes trading.
11. Both origin-token allowances from Hook to wrappers are zero after each swap, including WETH for a native input.

Update event consumers for the shorter `LpSwap` ABI: Shell PoolId, LP PoolId, sender, direction, amountIn and amountOut. It no longer includes `usedLp` or `amountSpecified`. The new deployment does not change the old address or its ABI.

## 8. Stop conditions

Remove the affected LP mapping and stop routing if any of these occurs:

- wrapper backing or 1:1 conversion fails;
- the registered PoolKey differs from the approved configuration;
- quote and execution diverge outside normal block-state movement;
- the Hook retains unexpected balances;
- the FewToken LP Hook changes behavior or becomes unsafe;
- monitoring detects repeated partial-fill, inventory or settlement failures.
