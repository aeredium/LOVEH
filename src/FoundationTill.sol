// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FoundationTill
/// @notice The foundation's till: the address a market factory fixes for ever as the recipient of the
///         protocol fee. The markets pay the till; the till knows one beneficiary, who alone can take
///         out what is in it, and who can hand the till over to a successor in two steps (the
///         beneficiary names the successor, the successor accepts). So the party that receives the
///         fee can change without touching any factory or any market.
///
///         Nothing in the till can be owned, paused, upgraded or redirected: nobody but the beneficiary
///         can move anything out, and nothing can go anywhere but to the beneficiary of that moment.
///         The till never holds the chain's own currency: no receive, no fallback, no payable function.
contract FoundationTill is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ events

    /// @notice The till sent `amount` of `asset` to `beneficiary`. The amount is what the till sent;
    ///         a coin that takes a fee on transfer delivers less.
    event Collected(address indexed asset, address indexed beneficiary, uint256 amount);
    /// @notice `beneficiary` named `successor` to take over; the zero address clears the name.
    event SuccessorNamed(address indexed beneficiary, address indexed successor);
    /// @notice `previous` handed the till over to `beneficiary`, who accepted.
    event HandedOver(address indexed previous, address indexed beneficiary);

    // ------------------------------------------------------------------ errors

    error ZeroAddress();
    error NotBeneficiary();
    error NotSuccessor();
    error NothingToCollect();
    error SuccessorIsBeneficiary();

    // ------------------------------------------------------------------ state

    /// @notice The one party that can collect from the till and name a successor.
    address public beneficiary;
    /// @notice The party named to take over, or the zero address when none is named.
    address public successor;

    // ------------------------------------------------------------------ construction

    constructor(address beneficiary_) {
        if (beneficiary_ == address(0)) revert ZeroAddress();
        beneficiary = beneficiary_;
    }

    // ------------------------------------------------------------------ collection

    /// @notice Send the till's whole balance of `asset` to the beneficiary. Beneficiary only.
    function collect(address asset) external nonReentrant {
        address to = beneficiary;
        if (msg.sender != to) revert NotBeneficiary();
        uint256 amount = IERC20(asset).balanceOf(address(this));
        if (amount == 0) revert NothingToCollect();
        emit Collected(asset, to, amount);
        IERC20(asset).safeTransfer(to, amount);
    }

    // ------------------------------------------------------------------ handover

    /// @notice Name the party that may take the till over, replacing any earlier name. The zero
    ///         address clears it. Beneficiary only; the beneficiary cannot name itself.
    function nameSuccessor(address successor_) external {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (successor_ == msg.sender) revert SuccessorIsBeneficiary();
        successor = successor_;
        emit SuccessorNamed(msg.sender, successor_);
    }

    /// @notice Take the till over. Named successor only; with no successor named, every caller is
    ///         refused. The caller becomes the beneficiary and the name is cleared.
    function acceptHandover() external {
        address next = successor;
        if (next == address(0) || msg.sender != next) revert NotSuccessor();
        address previous = beneficiary;
        beneficiary = next;
        successor = address(0);
        emit HandedOver(previous, next);
    }
}
