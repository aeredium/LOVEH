// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMarketFactory
/// @notice Creates LOVEH markets. Anyone may create a market; the factory has no owner and nothing
///         in it can be changed after construction: the fee recipient and the list of permitted rate
///         formulas are fixed forever.
interface IMarketFactory {
    event MarketCreated(
        address indexed market,
        address indexed loanToken,
        address indexed collateralToken,
        address priceSource,
        uint256 borrowingLimit,
        address rateFormula
    );

    error ZeroAddress();
    error SameToken();
    error InvalidBorrowingLimit();
    error RateFormulaNotPermitted();
    error DuplicateMarket();
    error NoRateFormulas();
    error DuplicateRateFormula();

    /// @notice The address every market created here pays its protocol fee to.
    function feeRecipient() external view returns (address);
    /// @notice The rate formulas a market may use, fixed at construction.
    function permittedRateFormulas() external view returns (address[] memory);
    function isPermittedRateFormula(address rateFormula) external view returns (bool);

    /// @notice Create a market with these five terms. Reverts on a zero address, on
    ///         `loanToken == collateralToken`, on a formula not on the permitted list, on a borrowing
    ///         limit not strictly between 0 and 1e18, and on a duplicate of an existing market.
    function createMarket(
        address loanToken,
        address collateralToken,
        address priceSource,
        uint256 borrowingLimit,
        address rateFormula
    ) external returns (address market);

    /// @notice Number of markets created.
    function marketCount() external view returns (uint256);
    /// @notice The market at a position in the list of markets created.
    function markets(uint256 index) external view returns (address);
    /// @notice The market with exactly these five terms, or the zero address if none exists.
    function marketFor(
        address loanToken,
        address collateralToken,
        address priceSource,
        uint256 borrowingLimit,
        address rateFormula
    ) external view returns (address);
    /// @notice True if `market` was created by this factory.
    function isMarket(address market) external view returns (bool);
}
