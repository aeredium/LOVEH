# LOVEH interfaces

MIT-licensed Solidity interfaces and JSON ABIs of the LOVEH markets, so that anyone may build wallets,
dashboards, liquidation bots and other tools on them. See `LICENSE` in this folder.

| Interface | Contract | What it is |
| --- | --- | --- |
| `IMarketFactory.sol` | `MarketFactory` | Creates markets. No owner; the fee recipient and the permitted rate formulas are fixed at construction. |
| `IMarket.sol` | `Market` | One market: lending, collateral, borrowing, liquidation, fee and audit views. Every term is immutable. |
| `IReceiptToken.sol` | `ReceiptToken` | The ERC-20 receipt token of one market. Only the market mints or burns. |
| `IPriceSource.sol` | (yours) | Price of one unit of collateral in loan-token units, scaled by 1e36. |
| `IRateFormula.sol` | `LinearRateFormula`, `KinkedRateFormula` | Per-second rate from utilisation. |

The JSON ABIs in `abi/` are generated from the build (`forge inspect <Contract> abi --json`); the
concrete contracts' ABIs include their constructors.

## Conventions

- Percentages and ratios are fixed-point numbers scaled by 1e18: `0.86e18` is 86 percent.
- A price is the value of one smallest unit of the collateral token in smallest units of the loan
  token, multiplied by 1e36. If one whole 18-decimal collateral token is worth 2000 whole 18-decimal
  loan tokens, the price is `2000e36`.
- The protocol fee is a constant 10 percent of interest (`FEE() == 0.1e18`), paid in the loan token
  to `feeRecipient()`, fixed at deployment.
- A lender's claim is a receipt. `deposit` mints receipt units; `withdraw` burns them. One unit's
  value grows as interest accrues and falls only when a loss is written off against the market.
- Every incoming transfer credits the amount actually received. With a token that takes a fee on
  transfer, the receipts, collateral or repayment credited are for the amount that arrived.
- A price of zero or a failing price source refuses `borrow`, `withdrawCollateral` and `liquidate`.

## Examples

All examples use Solidity; the same calls work from any library through the ABIs.

### Creating a market

```solidity
IMarketFactory factory = IMarketFactory(FACTORY);
address market = factory.createMarket(
    LOAN_TOKEN,          // the token lent, e.g. a stablecoin
    COLLATERAL_TOKEN,    // the token accepted as collateral
    PRICE_SOURCE,        // an IPriceSource for this pair, scaled by 1e36
    0.86e18,             // borrowing limit: loans may reach 86 percent of the collateral's value
    RATE_FORMULA         // one of factory.permittedRateFormulas()
);
```

Anyone may call this. The call reverts on a zero address, on `loanToken == collateralToken`, on a
formula that is not permitted, on a limit outside (0, 1e18) and on a market that already exists with
the same five terms (`factory.marketFor(...)` finds it).

### Depositing (lending)

```solidity
IMarket market = IMarket(MARKET);
IERC20(market.loanToken()).approve(MARKET, 1_000e18);
uint256 receipts = market.deposit(1_000e18, msg.sender);   // receipt units minted to msg.sender
// later
uint256 value = market.valueOf(receipts);                  // loan token the receipts are worth now
market.withdraw(receipts, msg.sender);                     // refused only if the market holds too little unlent loan token
```

### Borrowing

```solidity
IERC20(market.collateralToken()).approve(MARKET, 1e18);
market.depositCollateral(1e18, msg.sender);
(bool priceAvailable, uint256 maxLoan) = market.maxLoanOf(msg.sender);
require(priceAvailable);
market.borrow(maxLoan / 2, msg.sender);                    // loan token sent to the receiver
// later, to borrow everything the market will still lend to this borrower
(bool ok, uint256 borrowable) = market.borrowableOf(msg.sender);
require(ok && borrowable != 0);
market.borrow(borrowable, msg.sender);                     // accepted; borrowable + 1 would be refused
```

Borrowing is refused above the borrowing limit, above the unlent loan token, or when the price is
zero or unavailable. Interest accrues every second at `IRateFormula(market.rateFormula()).ratePerSecond(loans, deposits)`.

`maxLoanOf` is the limit itself; `borrowableOf` is the largest amount `borrow` accepts at this
block: the limit less the loan (with the interest pending up to now), less what the market's
roundings take, and never more than the unlent loan token. Because the market rounds the loan units
up on the way in and the loan up on the way out, `maxLoanOf - loanOf` can be refused by a unit;
`borrowableOf` is never refused. Read in the same block as the borrow, it is exact; a block later the
interest accrued since may put it a unit high.

### Repaying

```solidity
uint256 owed = market.loanOf(BORROWER);                    // includes interest up to now
IERC20(market.loanToken()).approve(MARKET, owed);
market.repay(owed, BORROWER);                              // anyone may repay for anyone; capped at the loan
```

Interest keeps accruing until the transaction executes, so `loanOf` read a block earlier may be a
little below the loan at execution; `repay` with a larger amount pulls only what is owed.

### Liquidating

```solidity
(bool priceAvailable, address[] memory borrowers, uint256[] memory loans, uint256[] memory limits) =
    market.loansAboveLimit(0, 100);                        // paged over the set of open loans
if (priceAvailable && borrowers.length != 0) {
    IERC20(market.loanToken()).approve(MARKET, loans[0]);
    (uint256 repaid, uint256 collateralSeized) = market.liquidate(borrowers[0], loans[0]);
    // collateralSeized is worth repaid * market.liquidationIncentive() / 1e18 at the price source,
    // capped at the borrower's collateral. If the collateral runs out with loan remaining, the
    // remainder is written off against this market's lenders (event LossWrittenOff).
}
```

Anyone may liquidate a loan above the borrowing limit times the collateral's value. Nobody decides or
can stop a liquidation. A zero or failing price never permits one.

### Paying the fee

```solidity
market.payFee();   // anyone; sends the fee owed, up to the unlent loan token, to market.feeRecipient()
```

## Audit views

`deposits()`, `loans()`, `unlent()`, `collateral()`, `collateralValue()`, `feePaid()`, `feeOwed()`,
`feeWrittenOff()`, `totalInterest()`, `totalLoss()`, `borrowerCount()`, `borrowerAt(i)` and
`loansAboveLimit(start, count)` describe one market completely. The identity
`unlent() + loans() == deposits() + feeOwed()` holds after every action, and
`feePaid() + feeOwed() + feeWrittenOff()` is exactly 10 percent of `totalInterest()`.
