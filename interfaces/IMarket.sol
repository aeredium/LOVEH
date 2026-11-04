// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMarket
/// @notice One LOVEH lending market: one loan token, one collateral token, one price source, one
///         borrowing limit, one rate formula. Every term is fixed at creation. Nobody owns the market,
///         nobody can pause, change or upgrade it, and a loss in this market never reaches another.
///
/// Fixed-point convention: percentages and ratios are scaled by 1e18 (1e18 = 100 percent). Prices
/// are scaled by 1e36 (see IPriceSource).
interface IMarket {
    // ------------------------------------------------------------------ events

    /// @notice Interest accrued on the loans. `fee` is the protocol fee part of `interest`.
    event Accrued(uint256 interest, uint256 fee);
    event Deposited(address indexed caller, address indexed onBehalf, uint256 amount, uint256 receipts);
    event Withdrawn(address indexed caller, address indexed receiver, uint256 amount, uint256 receipts);
    event CollateralDeposited(address indexed caller, address indexed onBehalf, uint256 amount);
    event CollateralWithdrawn(address indexed caller, address indexed receiver, uint256 amount);
    event Borrowed(address indexed borrower, address indexed receiver, uint256 amount, uint256 loanUnits);
    event Repaid(address indexed caller, address indexed onBehalf, uint256 amount, uint256 loanUnits);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 repaid, uint256 collateralSeized);
    /// @notice A loan that could not be covered by collateral was written off. `lossToLenders` reduced
    ///         the value of this market's receipts; `lossToFee` reduced the unpaid protocol fee (only
    ///         ever non-zero when the loss exceeded every deposit in the market).
    event LossWrittenOff(address indexed borrower, uint256 loan, uint256 lossToLenders, uint256 lossToFee);
    event FeePaid(address indexed recipient, uint256 amount);

    // ------------------------------------------------------------------ errors

    error ZeroAddress();
    error ZeroAmount();
    error SameToken();
    error InvalidBorrowingLimit();
    error NothingReceived();
    error InsufficientUnlent();
    error PriceUnavailable();
    error AboveBorrowingLimit();
    error NoLoan();
    error NotLiquidatable();
    error InsufficientCollateral();
    error InsufficientReceipts();

    // ------------------------------------------------------------------ terms (all fixed at creation)

    function loanToken() external view returns (address);
    function collateralToken() external view returns (address);
    function priceSource() external view returns (address);
    /// @notice Highest loan allowed as a fraction of the collateral's value, scaled by 1e18.
    function borrowingLimit() external view returns (uint256);
    function rateFormula() external view returns (address);
    /// @notice The address paid the protocol fee, fixed at deployment.
    function feeRecipient() external view returns (address);
    /// @notice Collateral value a liquidator receives per unit of loan repaid, scaled by 1e18.
    function liquidationIncentive() external view returns (uint256);
    /// @notice This market's own ERC-20 receipt token.
    function receiptToken() external view returns (address);
    /// @notice Protocol fee as a fraction of interest, scaled by 1e18. Constant: 0.1e18.
    function FEE() external view returns (uint256);

    // ------------------------------------------------------------------ lending

    /// @notice Deposit loan token and mint receipts to `onBehalf`. Credits only the amount actually received.
    function deposit(uint256 amount, address onBehalf) external returns (uint256 receipts);
    /// @notice Burn the caller's receipts and send their value in loan token to `receiver`.
    ///         Refused only when the market does not hold enough unlent loan token at that moment.
    function withdraw(uint256 receiptAmount, address receiver) external returns (uint256 amount);

    // ------------------------------------------------------------------ collateral

    /// @notice Lock collateral for `onBehalf`. Credits only the amount actually received.
    function depositCollateral(uint256 amount, address onBehalf) external;
    /// @notice Withdraw the caller's collateral to `receiver`. Refused when the price is zero or
    ///         unavailable, or when it would leave the caller's loan above the borrowing limit.
    function withdrawCollateral(uint256 amount, address receiver) external;

    // ------------------------------------------------------------------ borrowing

    /// @notice Borrow loan token against the caller's collateral, sent to `receiver`. Refused above
    ///         the borrowing limit, above the unlent loan token, or when the price is zero or unavailable.
    function borrow(uint256 amount, address receiver) external returns (uint256 loanUnits);
    /// @notice Repay up to the whole loan of `onBehalf`. Anyone may repay for anyone.
    function repay(uint256 amount, address onBehalf) external returns (uint256 repaid);

    // ------------------------------------------------------------------ liquidation

    /// @notice Repay up to the whole loan of a borrower whose loan exceeds the borrowing limit and
    ///         receive collateral worth `repaid * liquidationIncentive` at the price source. If the
    ///         collateral runs out with loan remaining, the remainder is written off against this
    ///         market's lenders.
    function liquidate(address borrower, uint256 repayAmount)
        external
        returns (uint256 repaid, uint256 collateralSeized);

    // ------------------------------------------------------------------ fee and accrual

    /// @notice Pay the protocol fee owed, up to the unlent loan token, to the fee recipient. Anyone may call.
    function payFee() external returns (uint256 paid);
    /// @notice Accrue interest up to now. Called by every state-changing function; anyone may call it.
    function accrue() external;

    // ------------------------------------------------------------------ audit views (all include interest accrued up to now)

    /// @notice Loan token owed to lenders, including interest earned.
    function deposits() external view returns (uint256);
    /// @notice Loan token owed by borrowers, including interest owed.
    function loans() external view returns (uint256);
    /// @notice Loan token held by the market and not lent.
    function unlent() external view returns (uint256);
    /// @notice Collateral token locked in the market.
    function collateral() external view returns (uint256);
    /// @notice Value of the locked collateral in loan token at the price source. `priceAvailable` is
    ///         false when the price source fails or returns zero; `value` is then zero.
    function collateralValue() external view returns (bool priceAvailable, uint256 value);
    /// @notice Protocol fee paid to the fee recipient to date.
    function feePaid() external view returns (uint256);
    /// @notice Protocol fee accrued and not yet paid.
    function feeOwed() external view returns (uint256);
    /// @notice Protocol fee written off because a loss exceeded every deposit in the market.
    function feeWrittenOff() external view returns (uint256);
    /// @notice All interest accrued to date; the fee paid, owed and written off sum to 10 percent of it.
    function totalInterest() external view returns (uint256);
    /// @notice Total loss written off against this market's lenders to date.
    function totalLoss() external view returns (uint256);
    /// @notice Timestamp of the last accrual written to storage.
    function lastAccrual() external view returns (uint256);

    /// @notice Total receipt units in existence.
    function totalReceipts() external view returns (uint256);
    /// @notice Total loan units in existence.
    function totalLoanUnits() external view returns (uint256);
    /// @notice Value in loan token of a lender's receipts.
    function depositOf(address lender) external view returns (uint256);
    /// @notice Loan token a borrower owes, including interest.
    function loanOf(address borrower) external view returns (uint256);
    /// @notice Loan units held by a borrower.
    function loanUnitsOf(address borrower) external view returns (uint256);
    /// @notice Collateral locked by a borrower.
    function collateralOf(address borrower) external view returns (uint256);
    /// @notice Highest loan a borrower may hold against their collateral at the current price.
    ///         `priceAvailable` is false when the price source fails or returns zero.
    function maxLoanOf(address borrower) external view returns (bool priceAvailable, uint256 maxLoan);
    /// @notice Loan token the market would mint receipts for right now, for an amount deposited.
    function receiptsFor(uint256 amount) external view returns (uint256);
    /// @notice Loan token the market would pay right now for an amount of receipts.
    function valueOf(uint256 receiptAmount) external view returns (uint256);

    /// @notice Number of borrowers with an open loan.
    function borrowerCount() external view returns (uint256);
    /// @notice The borrower at a position in the set of borrowers with an open loan.
    function borrowerAt(uint256 index) external view returns (address);
    /// @notice The loans above the borrowing limit among the borrowers at positions [start, start+count),
    ///         with their sizes and limits. Paged; never iterates without bound. When the price is
    ///         unavailable no loan is reported, since no price can put a loan above the limit.
    function loansAboveLimit(uint256 start, uint256 count)
        external
        view
        returns (bool priceAvailable, address[] memory borrowers, uint256[] memory loanSizes, uint256[] memory limits);
}
