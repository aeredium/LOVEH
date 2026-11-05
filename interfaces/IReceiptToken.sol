// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IReceiptToken
/// @notice The ERC-20 receipt token of one LOVEH market. One receipt unit is a claim on a growing
///         amount of the market's loan token; its value rises as interest accrues and falls only
///         when a loss is written off against the market's lenders.
/// @dev Only the market that deployed the token can mint or burn it.
interface IReceiptToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error NotMarket();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    /// @notice The market that deployed this token and alone can mint or burn it.
    function market() external view returns (address);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address holder, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);

    /// @notice Mint receipt units. Only the market.
    function mint(address to, uint256 value) external;

    /// @notice Burn receipt units. Only the market.
    function burn(address from, uint256 value) external;
}
