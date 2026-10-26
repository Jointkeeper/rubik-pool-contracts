# Rubik pool contracts

Solidity sources of the Rubik investor pool (HyperEVM). Everything lives in [`contracts/`](contracts/):

- [`contracts/README.md`](contracts/README.md) — design notes, roles, parameters, gas, reproducible build for Sourcify;
- `contracts/src` — contracts, `contracts/test` — Foundry tests, `contracts/lib` — vendored dependencies;
- `contracts/deploy`, `contracts/diff` — deployment and differential-test tooling;
- [`contracts/LICENSE`](contracts/LICENSE) — Business Source License 1.1.

Build: `cd contracts && forge build --skip test` (see `foundry.toml`; solc 0.8.36, cancun, optimizer 200).
Source files must be taken byte-for-byte (`.gitattributes` disables line-ending conversion) — some vendored files use CRLF and their hashes are part of the contract metadata.
