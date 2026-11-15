// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";

/// @notice ERC-20 that refuses a transfer to a refused address without reverting: by returning false,
///         or by returning a word that is neither true nor false. For tests only; anyone can set it.
contract RefusingToken is MockERC20 {
    mapping(address => bool) public refused;
    bool public answerWithOddWord;

    constructor() MockERC20("Refusing Token", "RFS", 18) {}

    function setRefused(address account, bool value) external {
        refused[account] = value;
    }

    function setAnswerWithOddWord(bool value) external {
        answerWithOddWord = value;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        if (refused[to]) {
            if (answerWithOddWord) {
                assembly {
                    mstore(0, 2)
                    return(0, 32)
                }
            }
            return false;
        }
        _transfer(msg.sender, to, value);
        return true;
    }
}
