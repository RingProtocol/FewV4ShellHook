# ShellHook release sync — 2026-10-09

The direct-settlement optimization is already in upstream main. Merge main `3713ea7` into the existing release candidate and retain deletion of six obsolete deployment scripts/reports. The candidate now permits registered LP hooks that return swap deltas, as upstream intends; pool-level route validation remains in force. No new netting or keeper contract is part of this release.

## Local verification

- `forge test --force --json`: 106 passed, 0 failed, 0 skipped (93 integration, 10 fork, 3 deployer).
- `forge fmt --check`: passed.
- `forge build --sizes`: passed; runtime 15,871 bytes, initcode 17,332 bytes.
- Foundry 1.5.1-stable; Solidity 0.8.26; optimizer 200 runs, via IR.

The previous 107-test count included a rejection behavior removed by upstream's swap-delta support. This is a fixed-fork local proof, not current routing acceptance or deployment. The review diff against main is cleanup and release documentation; do not present it as an additional gas optimization awaiting merge. Deployment still requires approved immutable addresses, owner, final constructor-bound codehash and routing acceptance.
