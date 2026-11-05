# LOVEH

Lending markets on the AEREDIUM chain, with no owner, no administrative key and no governance.

Anyone may create a market by naming the token lent, the collateral accepted, the price source, the borrowing limit and the rate formula. Once created, a market is fixed for its whole life: nobody can change it, pause it or upgrade it. Lenders earn the interest borrowers pay, less a protocol fee of 10 percent written into the code and paid by the contract to the AEREDIUM Foundation, in the token the market lends. Liquidation is open to anyone, at a published discount.

## Build and test

The contracts are built with [Foundry](https://book.getfoundry.sh/) on Solidity 0.8.28, targeting the
Cancun EVM that the AEREDIUM chain's execution layer (EVMSO) supports. The only dependencies are
forge-std and OpenZeppelin Contracts (used for `SafeERC20`, `IERC20` and `ReentrancyGuard`), pulled in
as git submodules.

```sh
git clone --recurse-submodules <this repository>
forge build
forge test          # unit, fuzz (10,000 runs) and invariant (1,000 runs) tests, as set in foundry.toml
forge coverage
```

Layout:

- `src/` — `MarketFactory`, `Market`, `ReceiptToken`, the rate formulas under `src/rates/` (PolyForm Shield).
- `interfaces/` — the Solidity interfaces, their JSON ABIs under `interfaces/abi/`, and usage examples (MIT).
- `test/` — the Foundry tests, with mock tokens (including fee-on-transfer and freezable tokens), a
  mock price source, and the invariant handler under `test/invariant/`.

To regenerate the ABIs after a change: `forge inspect <Contract> abi --json > interfaces/abi/<Contract>.json`.

## Licences

- **Core contracts** (everything outside the `interfaces` folder): PolyForm Shield License 1.0.0. The code may be read, checked and used, but not to provide anything that competes with it. This licence does not expire. See `LICENSE`.
- **Interfaces, contract descriptions, software kit and examples** (the `interfaces` folder): MIT License, so that anyone may build wallets, dashboards and other tools on the markets from day one. See `interfaces/LICENSE`.

Required Notice: Copyright Aeredium IP Limited (https://aeredium.io)
