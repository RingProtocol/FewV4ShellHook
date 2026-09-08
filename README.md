# FewV4ShellHook

`FewV4ShellHook` exposes an origin-token Uniswap v4 shell pool while executing each swap against one constructor-approved, hookless FewToken v4 pool.

The outer pool is never swapped against: the Hook wraps the origin input, executes the inner FewToken swap, unwraps the output, and replaces the outer swap with a `beforeSwap` return delta. Exact input and exact output must fill completely or the whole transaction reverts.

Only the immutable `owner` may add outer-pool liquidity, either directly or through the canonical v4 `PositionManager` (the path the Uniswap interface uses, resolved against the position's ERC-721 holder). That liquidity is inert — it never trades and earns no fee — and exists so the owner can seed the physical origin-token inventory the atomic wrap leg takes from the PoolManager. The owner has no other privilege: no upgrade, pause, fee, sweep, or route setter.

This package is pre-production. It is not audited, deployed, funded, indexed, or proven to receive Uniswap Labs traffic.

## Review material

- [Design note](docs/FEW_V4_SHELL_HOOK.md)
- Main contract: `src/FewV4ShellHook.sol`
- Integration tests: `test/integration/FewV4ShellHook.t.sol`
- Fixed-block fork tests: `test/fork/FewV4ShellHookFork.t.sol`

## Build and test

```sh
git submodule update --init --recursive
forge fmt --check
forge build --sizes
forge test --match-path 'test/integration/FewV4ShellHook.t.sol'
```

The fixed-block mainnet tests run only when `ETH_RPC_URL` is available locally:

```sh
forge test --match-path 'test/fork/FewV4ShellHookFork.t.sol'
```

## Repository status

The review repository is [RingProtocol/FewV4ShellHook](https://github.com/RingProtocol/FewV4ShellHook). Publishing this source does not imply an audit, deployment, official Uniswap routing support, or production approval.

## License

The project is licensed under GPL-2.0-or-later. See [LICENSE](LICENSE).
