// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {Market} from "./Market.sol";

/// @title MarketFactory
/// @notice Creates LOVEH markets. Anyone may create a market. The factory has no owner and nothing in
///         it can be changed after construction: the protocol fee recipient and the list of permitted
///         rate formulas are fixed once and forever. No pause, no upgrade, no proxy, no selfdestruct,
///         no delegatecall.
contract MarketFactory is IMarketFactory {
    uint256 internal constant WAD = 1e18;

    /// @inheritdoc IMarketFactory
    address public immutable feeRecipient;

    /// @dev Fixed at construction; no function writes to these afterwards.
    address[] internal _permittedRateFormulas;
    mapping(address rateFormula => bool) public isPermittedRateFormula;

    /// @dev Every market created, in order of creation.
    address[] public markets;
    mapping(address market => bool) public isMarket;
    /// @dev keccak256 of the five terms to the market holding them.
    mapping(bytes32 termsHash => address market) internal _marketFor;

    constructor(address feeRecipient_, address[] memory permittedRateFormulas_) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (permittedRateFormulas_.length == 0) revert NoRateFormulas();
        feeRecipient = feeRecipient_;
        for (uint256 i = 0; i < permittedRateFormulas_.length; ++i) {
            address formula = permittedRateFormulas_[i];
            if (formula == address(0)) revert ZeroAddress();
            if (isPermittedRateFormula[formula]) revert DuplicateRateFormula();
            isPermittedRateFormula[formula] = true;
            _permittedRateFormulas.push(formula);
        }
    }

    /// @inheritdoc IMarketFactory
    function createMarket(
        address loanToken,
        address collateralToken,
        address priceSource,
        uint256 borrowingLimit,
        address rateFormula
    ) external returns (address market) {
        if (loanToken == address(0) || collateralToken == address(0) || priceSource == address(0)) {
            revert ZeroAddress();
        }
        if (loanToken == collateralToken) revert SameToken();
        if (borrowingLimit == 0 || borrowingLimit >= WAD) revert InvalidBorrowingLimit();
        if (!isPermittedRateFormula[rateFormula]) revert RateFormulaNotPermitted();
        bytes32 termsHash = _termsHash(loanToken, collateralToken, priceSource, borrowingLimit, rateFormula);
        if (_marketFor[termsHash] != address(0)) revert DuplicateMarket();

        market = address(new Market(loanToken, collateralToken, priceSource, borrowingLimit, rateFormula, feeRecipient));
        markets.push(market);
        isMarket[market] = true;
        _marketFor[termsHash] = market;
        emit MarketCreated(market, loanToken, collateralToken, priceSource, borrowingLimit, rateFormula);
    }

    /// @inheritdoc IMarketFactory
    function permittedRateFormulas() external view returns (address[] memory) {
        return _permittedRateFormulas;
    }

    /// @inheritdoc IMarketFactory
    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    /// @inheritdoc IMarketFactory
    function marketFor(
        address loanToken,
        address collateralToken,
        address priceSource,
        uint256 borrowingLimit,
        address rateFormula
    ) external view returns (address) {
        return _marketFor[_termsHash(loanToken, collateralToken, priceSource, borrowingLimit, rateFormula)];
    }

    function _termsHash(
        address loanToken,
        address collateralToken,
        address priceSource,
        uint256 borrowingLimit,
        address rateFormula
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(loanToken, collateralToken, priceSource, borrowingLimit, rateFormula));
    }
}
