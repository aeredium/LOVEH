// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IReceiptToken} from "../interfaces/IReceiptToken.sol";

/// @title ReceiptToken
/// @notice The ERC-20 receipt token of one LOVEH market. Deployed by the market in its constructor;
///         only that market can mint or burn. No owner, no pause, no upgrade.
contract ReceiptToken is IReceiptToken {
    address public immutable market;
    uint8 public immutable decimals;
    string public name;
    string public symbol;

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address holder => mapping(address spender => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        market = msg.sender;
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    modifier onlyMarket() {
        if (msg.sender != market) revert NotMarket();
        _;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function mint(address to, uint256 value) external onlyMarket {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint256 value) external onlyMarket {
        uint256 balance = balanceOf[from];
        if (balance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - value;
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[from];
        if (balance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - value;
        }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
