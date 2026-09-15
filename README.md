# FewV4ShellHook

`FewV4ShellHook` exposes an origin-token Uniswap v4 `shellPool` while executing each swap against a configured or factory-derived FewToken `lpPool`.

The `shellPool` is never used as the swap execution venue: the Hook wraps the origin input, executes the swap against the `lpPool`, unwraps the output, and replaces the `shellPool` swap with a `beforeSwap` return delta. Exact input and exact output must fill completely or the whole transaction reverts.

The owner can register or remove an explicit `lpPool` mapping. The route is otherwise derived from the FewFactory. The owner has no upgrade, pause, fee, or sweep privilege; `shellPool` liquidity is handled by the v4 core and the `lpPool` is the actual execution venue.

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

## Deploy hook

The owner-aware deployment script is the supported deployment path. It deploys the hook through a helper contract and transfers ownership to `HOOK_OWNER` in the same transaction sequence. It does not initialize a pool.

```sh
source .env
forge script script/DeployFewV4ShellHookWithOwner.s.sol:DeployFewV4ShellHookWithOwner \
  --rpc-url "$MAINNET_RPC_URL" \
  --private-key "$ETH_PRIVATE_KEY" \
  --broadcast
```

Required environment variables:

- `ETH_PRIVATE_KEY`
- `HOOK_OWNER`

The old `DeployFewV4ShellHook.s.sol` deployment path is deprecated and must not be used because the canonical CREATE2 deployer becomes the hook owner. Pool initialization and swap validation are separate operations; use the local deployment scripts and Foundry integration tests for those checks.

## License

The project is licensed under GPL-2.0-or-later. See [LICENSE](LICENSE).
