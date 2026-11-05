// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IMarket} from "../interfaces/IMarket.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IRateFormula} from "../interfaces/IRateFormula.sol";
import {IReceiptToken} from "../interfaces/IReceiptToken.sol";
import {FixedPoint} from "./FixedPoint.sol";
import {ReceiptToken} from "./ReceiptToken.sol";

/// @title Market
/// @notice One LOVEH lending market. Holds the deposits, loans and collateral of this market and
///         nothing else. Every term is immutable. No owner, no administrative key, no pause, no
///         upgrade. A loss in this market is written off against this market's lenders only.
///
/// Accounting (all in loan-token units):
///   deposits  D  owed to lenders, including interest earned (90 percent of interest accrued)
///   loans     L  owed by borrowers, including interest owed
///   unlent    U  loan token held by the market and not lent
///   feeOwed   F  protocol fee accrued (10 percent of interest) and not yet paid
/// and the identity  U + L == D + F  holds after every action, so that U equals the loan token the
/// market holds (absent tokens sent to it directly, which are credited to nobody).
///
/// Receipts: a lender's claim is a receipt unit of this market's own ERC-20 receipt token. Units are
/// converted with a virtual offset (VIRTUAL_RECEIPTS and VIRTUAL_DEPOSITS added to both sides), so
/// nobody can inflate the value of a receipt by sending tokens to an empty market. Loans use the same
/// device with loan units. Every rounding favours the market: down when minting receipts or paying
/// out, up when charging a borrower.
///
/// Incoming transfers credit the balance difference actually received, never the amount requested,
/// so a token that takes a fee on transfer cannot create unbacked receipts, collateral or repayments.
/// For that reason an incoming transfer is measured before the effects that depend on it; every
/// state-changing function is guarded against reentrancy, and every outgoing transfer follows the
/// effects it settles.
contract Market is IMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using FixedPoint for uint256;

    uint256 internal constant WAD = FixedPoint.WAD;
    uint256 internal constant PRICE_SCALE = FixedPoint.PRICE_SCALE;

    /// @inheritdoc IMarket
    uint256 public constant FEE = 0.1e18;
    /// @dev Highest liquidation incentive, scaled by 1e18.
    uint256 internal constant MAX_INCENTIVE = 1.15e18;
    /// @dev Virtual offsets for the receipt and loan unit conversions.
    uint256 internal constant VIRTUAL_RECEIPTS = 1e6;
    uint256 internal constant VIRTUAL_DEPOSITS = 1;
    uint256 internal constant VIRTUAL_LOAN_UNITS = 1e6;
    uint256 internal constant VIRTUAL_LOANS = 1;
    /// @dev Receipt token decimals are the loan token's plus this (the virtual offset's magnitude).
    uint8 internal constant RECEIPT_DECIMALS_OFFSET = 6;

    // ------------------------------------------------------------------ terms

    address public immutable loanToken;
    address public immutable collateralToken;
    address public immutable priceSource;
    uint256 public immutable borrowingLimit;
    address public immutable rateFormula;
    address public immutable feeRecipient;
    uint256 public immutable liquidationIncentive;
    address public immutable receiptToken;

    // ------------------------------------------------------------------ accounting

    uint256 internal _deposits;
    uint256 internal _loans;
    uint256 internal _unlent;
    uint256 internal _feeOwed;
    uint256 internal _totalInterest;
    uint256 public feePaid;
    uint256 public feeWrittenOff;
    uint256 public totalLoss;
    uint256 public lastAccrual;

    uint256 public totalLoanUnits;
    uint256 public collateral;
    mapping(address borrower => uint256) public loanUnitsOf;
    mapping(address borrower => uint256) public collateralOf;

    /// @dev Enumerable set of borrowers with an open loan. `_borrowerIndex` is one-based; zero means absent.
    address[] internal _borrowers;
    mapping(address borrower => uint256) internal _borrowerIndex;

    // ------------------------------------------------------------------ construction

    constructor(
        address loanToken_,
        address collateralToken_,
        address priceSource_,
        uint256 borrowingLimit_,
        address rateFormula_,
        address feeRecipient_
    ) {
        if (
            loanToken_ == address(0) || collateralToken_ == address(0) || priceSource_ == address(0)
                || rateFormula_ == address(0) || feeRecipient_ == address(0)
        ) revert ZeroAddress();
        if (loanToken_ == collateralToken_) revert SameToken();
        if (borrowingLimit_ == 0 || borrowingLimit_ >= WAD) revert InvalidBorrowingLimit();

        loanToken = loanToken_;
        collateralToken = collateralToken_;
        priceSource = priceSource_;
        borrowingLimit = borrowingLimit_;
        rateFormula = rateFormula_;
        feeRecipient = feeRecipient_;

        // incentive = min(1.15, 1 / (0.3 * borrowingLimit + 0.7)), fixed for the life of the market.
        uint256 divisor = (0.3e18 * borrowingLimit_) / WAD + 0.7e18;
        liquidationIncentive = FixedPoint.min(MAX_INCENTIVE, (WAD * WAD) / divisor);

        receiptToken = address(
            new ReceiptToken("LOVEH Receipt", "LOVEH-R", _loanTokenDecimals(loanToken_) + RECEIPT_DECIMALS_OFFSET)
        );
        lastAccrual = block.timestamp;
    }

    // ------------------------------------------------------------------ lending

    /// @inheritdoc IMarket
    function deposit(uint256 amount, address onBehalf) external nonReentrant returns (uint256 receipts) {
        if (onBehalf == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _accrue();

        uint256 received = _pull(loanToken, amount);
        receipts = _toReceiptsDown(received, _deposits, _totalReceipts());
        if (receipts == 0) revert ZeroAmount();

        _deposits += received;
        _unlent += received;
        IReceiptToken(receiptToken).mint(onBehalf, receipts);
        emit Deposited(msg.sender, onBehalf, received, receipts);
    }

    /// @inheritdoc IMarket
    function withdraw(uint256 receiptAmount, address receiver) external nonReentrant returns (uint256 amount) {
        if (receiver == address(0)) revert ZeroAddress();
        if (receiptAmount == 0) revert ZeroAmount();
        _accrue();

        if (IReceiptToken(receiptToken).balanceOf(msg.sender) < receiptAmount) revert InsufficientReceipts();
        amount = _toDepositsDown(receiptAmount, _deposits, _totalReceipts());
        if (amount > _unlent) revert InsufficientUnlent();

        _deposits -= amount;
        _unlent -= amount;
        // The fee is paid automatically when the unlent funds left allow it.
        uint256 fee = FixedPoint.min(_feeOwed, _unlent);
        if (fee != 0) _recordFeePayment(fee);
        emit Withdrawn(msg.sender, receiver, amount, receiptAmount);

        IReceiptToken(receiptToken).burn(msg.sender, receiptAmount);
        IERC20(loanToken).safeTransfer(receiver, amount);
        if (fee != 0) IERC20(loanToken).safeTransfer(feeRecipient, fee);
    }

    // ------------------------------------------------------------------ collateral

    /// @inheritdoc IMarket
    function depositCollateral(uint256 amount, address onBehalf) external nonReentrant {
        if (onBehalf == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _accrue();

        uint256 received = _pull(collateralToken, amount);
        collateralOf[onBehalf] += received;
        collateral += received;
        emit CollateralDeposited(msg.sender, onBehalf, received);
    }

    /// @inheritdoc IMarket
    function withdrawCollateral(uint256 amount, address receiver) external nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _accrue();

        (bool priceAvailable, uint256 price) = _price();
        if (!priceAvailable) revert PriceUnavailable();
        uint256 held = collateralOf[msg.sender];
        if (amount > held) revert InsufficientCollateral();

        held -= amount;
        collateralOf[msg.sender] = held;
        collateral -= amount;
        if (_loanOf(msg.sender, _loans, totalLoanUnits) > _maxLoan(held, price)) revert AboveBorrowingLimit();
        emit CollateralWithdrawn(msg.sender, receiver, amount);

        IERC20(collateralToken).safeTransfer(receiver, amount);
    }

    // ------------------------------------------------------------------ borrowing

    /// @inheritdoc IMarket
    function borrow(uint256 amount, address receiver) external nonReentrant returns (uint256 loanUnits) {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _accrue();

        (bool priceAvailable, uint256 price) = _price();
        if (!priceAvailable) revert PriceUnavailable();
        if (amount > _unlent) revert InsufficientUnlent();

        loanUnits = _toLoanUnitsUp(amount, _loans, totalLoanUnits);
        if (loanUnitsOf[msg.sender] == 0) _addBorrower(msg.sender);
        loanUnitsOf[msg.sender] += loanUnits;
        totalLoanUnits += loanUnits;
        _loans += amount;
        _unlent -= amount;
        if (_loanOf(msg.sender, _loans, totalLoanUnits) > _maxLoan(collateralOf[msg.sender], price)) {
            revert AboveBorrowingLimit();
        }
        emit Borrowed(msg.sender, receiver, amount, loanUnits);

        IERC20(loanToken).safeTransfer(receiver, amount);
    }

    /// @inheritdoc IMarket
    function repay(uint256 amount, address onBehalf) external nonReentrant returns (uint256 repaid) {
        if (onBehalf == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _accrue();

        uint256 loan = _loanOf(onBehalf, _loans, totalLoanUnits);
        if (loan == 0) revert NoLoan();

        repaid = _pull(loanToken, FixedPoint.min(amount, loan));
        uint256 loanUnits = _settleRepayment(onBehalf, repaid, loan);
        emit Repaid(msg.sender, onBehalf, repaid, loanUnits);
    }

    // ------------------------------------------------------------------ liquidation

    /// @inheritdoc IMarket
    function liquidate(address borrower, uint256 repayAmount)
        external
        nonReentrant
        returns (uint256 repaid, uint256 collateralSeized)
    {
        if (borrower == address(0)) revert ZeroAddress();
        if (repayAmount == 0) revert ZeroAmount();
        _accrue();

        // A price of zero or a failing price source never permits a liquidation by itself.
        (bool priceAvailable, uint256 price) = _price();
        if (!priceAvailable) revert PriceUnavailable();
        uint256 loan = _loanOf(borrower, _loans, totalLoanUnits);
        if (loan == 0) revert NoLoan();
        uint256 held = collateralOf[borrower];
        if (loan <= _maxLoan(held, price)) revert NotLiquidatable();

        repaid = _pull(loanToken, FixedPoint.min(repayAmount, loan));
        // Collateral worth repaid * incentive at the price source, rounded down, never more than held.
        collateralSeized = repaid.mulDivDown(liquidationIncentive, WAD).mulDivDown(PRICE_SCALE, price);
        if (collateralSeized > held) collateralSeized = held;

        _settleRepayment(borrower, repaid, loan);
        held -= collateralSeized;
        collateralOf[borrower] = held;
        collateral -= collateralSeized;
        emit Liquidated(msg.sender, borrower, repaid, collateralSeized);

        // Collateral exhausted with loan remaining: the remainder is written off against this market's lenders.
        if (held == 0 && loanUnitsOf[borrower] != 0) _writeOff(borrower);

        IERC20(collateralToken).safeTransfer(msg.sender, collateralSeized);
    }

    // ------------------------------------------------------------------ fee and accrual

    /// @inheritdoc IMarket
    function payFee() external nonReentrant returns (uint256 paid) {
        _accrue();
        paid = FixedPoint.min(_feeOwed, _unlent);
        if (paid == 0) return 0;
        _recordFeePayment(paid);
        IERC20(loanToken).safeTransfer(feeRecipient, paid);
    }

    /// @inheritdoc IMarket
    function accrue() external nonReentrant {
        _accrue();
    }

    // ------------------------------------------------------------------ audit views

    /// @inheritdoc IMarket
    function deposits() external view returns (uint256) {
        (uint256 interest, uint256 fee) = _pendingAccrual();
        return _deposits + interest - fee;
    }

    /// @inheritdoc IMarket
    function loans() external view returns (uint256) {
        (uint256 interest,) = _pendingAccrual();
        return _loans + interest;
    }

    /// @inheritdoc IMarket
    function unlent() external view returns (uint256) {
        return _unlent;
    }

    /// @inheritdoc IMarket
    function collateralValue() external view returns (bool priceAvailable, uint256 value) {
        uint256 price;
        (priceAvailable, price) = _price();
        if (priceAvailable) value = collateral.mulDivDown(price, PRICE_SCALE);
    }

    /// @inheritdoc IMarket
    function feeOwed() external view returns (uint256) {
        (, uint256 fee) = _pendingAccrual();
        return _feeOwed + fee;
    }

    /// @inheritdoc IMarket
    function totalInterest() external view returns (uint256) {
        (uint256 interest,) = _pendingAccrual();
        return _totalInterest + interest;
    }

    /// @inheritdoc IMarket
    function totalReceipts() external view returns (uint256) {
        return _totalReceipts();
    }

    /// @inheritdoc IMarket
    function depositOf(address lender) external view returns (uint256) {
        return valueOf(IReceiptToken(receiptToken).balanceOf(lender));
    }

    /// @inheritdoc IMarket
    function loanOf(address borrower) public view returns (uint256) {
        (uint256 interest,) = _pendingAccrual();
        return _loanOf(borrower, _loans + interest, totalLoanUnits);
    }

    /// @inheritdoc IMarket
    function maxLoanOf(address borrower) external view returns (bool priceAvailable, uint256 maxLoan) {
        uint256 price;
        (priceAvailable, price) = _price();
        if (priceAvailable) maxLoan = _maxLoan(collateralOf[borrower], price);
    }

    /// @inheritdoc IMarket
    function borrowableOf(address borrower) external view returns (bool priceAvailable, uint256 amount) {
        uint256 price;
        (priceAvailable, price) = _price();
        if (!priceAvailable) return (false, 0);
        (uint256 interest,) = _pendingAccrual();
        uint256 totalLoans = _loans + interest;
        uint256 totalUnits = totalLoanUnits;
        uint256 units = loanUnitsOf[borrower];
        uint256 maxLoan = _maxLoan(collateralOf[borrower], price);

        // Borrowing `a` raises the loan charged by at least `a` (units are rounded up on the way in and
        // the loan on the way out), so nothing above the limit less the loan, nor above the unlent
        // balance, is ever accepted. That bound is usually the answer; the two roundings may push the
        // loan charged for it over the limit by a unit or so.
        uint256 loan = units == 0 ? 0 : _toLoansUp(units, totalLoans, totalUnits);
        uint256 high = FixedPoint.min(maxLoan.zeroFloorSub(loan), _unlent);
        if (high == 0) return (true, 0);
        if (_loanAfterBorrow(units, high, totalLoans, totalUnits) <= maxLoan) return (true, high);

        // The roundings cost at most the worth of one loan unit, rounded up. With x = T + 1e6 units
        // and y = L + 1 loans, the units minted for `a` are below a·x/y + 1, and a borrower's share
        // of the units grows with the units minted, so the loan charged after the borrow is at most
        // ceil(u·y/x + a + y/x) <= loanOf + a + ceil(y/x). Hence `high - unitPrice` is accepted (or
        // is zero, which is), and the answer lies in [high - unitPrice, high). The loan charged never
        // falls as the amount rises, so the largest accepted amount is found by bisection over that
        // range: no step at all while a unit is worth a token or less, never more than 256, each a
        // few multiplications. Should the bound ever be off, the search starts from zero instead and
        // is exact all the same.
        uint256 unitPrice = _toLoansUp(1, totalLoans, totalUnits);
        uint256 low = high.zeroFloorSub(unitPrice);
        if (low != 0 && _loanAfterBorrow(units, low, totalLoans, totalUnits) > maxLoan) low = 0;
        // invariant: `low` is accepted and `high` is refused
        while (high - low > 1) {
            uint256 mid = low + (high - low) / 2;
            if (_loanAfterBorrow(units, mid, totalLoans, totalUnits) <= maxLoan) {
                low = mid;
            } else {
                high = mid;
            }
        }
        amount = low;
    }

    /// @inheritdoc IMarket
    function receiptsFor(uint256 amount) external view returns (uint256) {
        (uint256 interest, uint256 fee) = _pendingAccrual();
        return _toReceiptsDown(amount, _deposits + interest - fee, _totalReceipts());
    }

    /// @inheritdoc IMarket
    function valueOf(uint256 receiptAmount) public view returns (uint256) {
        (uint256 interest, uint256 fee) = _pendingAccrual();
        return _toDepositsDown(receiptAmount, _deposits + interest - fee, _totalReceipts());
    }

    /// @inheritdoc IMarket
    function borrowerCount() external view returns (uint256) {
        return _borrowers.length;
    }

    /// @inheritdoc IMarket
    function borrowerAt(uint256 index) external view returns (address) {
        return _borrowers[index];
    }

    /// @inheritdoc IMarket
    function loansAboveLimit(uint256 start, uint256 count)
        external
        view
        returns (bool priceAvailable, address[] memory borrowers, uint256[] memory loanSizes, uint256[] memory limits)
    {
        uint256 price;
        (priceAvailable, price) = _price();
        uint256 end = FixedPoint.min(start + count, _borrowers.length);
        if (!priceAvailable || start >= end) {
            return (priceAvailable, new address[](0), new uint256[](0), new uint256[](0));
        }
        (uint256 interest,) = _pendingAccrual();
        uint256 totalLoans = _loans + interest;

        uint256 found = 0;
        for (uint256 i = start; i < end; ++i) {
            if (_isAboveLimit(_borrowers[i], price, totalLoans)) ++found;
        }
        borrowers = new address[](found);
        loanSizes = new uint256[](found);
        limits = new uint256[](found);
        uint256 k = 0;
        for (uint256 i = start; i < end; ++i) {
            address borrower = _borrowers[i];
            if (!_isAboveLimit(borrower, price, totalLoans)) continue;
            borrowers[k] = borrower;
            loanSizes[k] = _loanOf(borrower, totalLoans, totalLoanUnits);
            limits[k] = _maxLoan(collateralOf[borrower], price);
            ++k;
        }
    }

    // ------------------------------------------------------------------ internals: accrual

    /// @dev Interest and fee accrued since `lastAccrual` but not yet written. The fee is the difference
    ///      between 10 percent of all interest including this accrual and 10 percent of all interest
    ///      before it, so that the fee paid, owed and written off always sum to exactly 10 percent of
    ///      all interest accrued.
    function _pendingAccrual() internal view returns (uint256 interest, uint256 fee) {
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0 || _loans == 0) return (0, 0);
        uint256 rate = IRateFormula(rateFormula).ratePerSecond(_loans, _deposits);
        interest = _loans.mulDivDown(rate * elapsed, WAD);
        if (interest == 0) return (0, 0);
        uint256 before = _totalInterest;
        fee = (before + interest).mulDivDown(FEE, WAD) - before.mulDivDown(FEE, WAD);
    }

    function _accrue() internal {
        (uint256 interest, uint256 fee) = _pendingAccrual();
        lastAccrual = block.timestamp;
        if (interest == 0) return;
        _loans += interest;
        _deposits += interest - fee;
        _feeOwed += fee;
        _totalInterest += interest;
        emit Accrued(interest, fee);
    }

    // ------------------------------------------------------------------ internals: effects

    /// @dev Burn loan units for a repayment of `received` against a loan of `loan`, and credit the
    ///      tokens received to the unlent balance. A repayment of the whole loan burns every unit.
    ///      The loan is rounded up when charged, so `received` may exceed the loans recorded by one
    ///      unit; that excess is credited to the lenders rather than lost.
    function _settleRepayment(address borrower, uint256 received, uint256 loan) internal returns (uint256 loanUnits) {
        loanUnits = received >= loan ? loanUnitsOf[borrower] : _toLoanUnitsDown(received, _loans, totalLoanUnits);
        loanUnitsOf[borrower] -= loanUnits;
        totalLoanUnits -= loanUnits;
        uint256 excess = received.zeroFloorSub(_loans);
        _loans -= received - excess;
        _deposits += excess;
        _unlent += received;
        if (loanUnitsOf[borrower] == 0) _removeBorrower(borrower);
    }

    /// @dev Write off the remaining loan of a borrower whose collateral is exhausted. The loss reduces
    ///      the deposits of this market's lenders; only if it exceeds every deposit does the remainder
    ///      reduce the unpaid protocol fee. It never reaches any other market.
    function _writeOff(address borrower) internal {
        uint256 loanUnits = loanUnitsOf[borrower];
        uint256 loan = FixedPoint.min(_loanOf(borrower, _loans, totalLoanUnits), _loans);
        loanUnitsOf[borrower] = 0;
        totalLoanUnits -= loanUnits;
        _loans -= loan;
        _removeBorrower(borrower);

        uint256 lossToLenders = FixedPoint.min(loan, _deposits);
        uint256 lossToFee = loan - lossToLenders;
        _deposits -= lossToLenders;
        _feeOwed -= lossToFee;
        totalLoss += lossToLenders;
        feeWrittenOff += lossToFee;
        emit LossWrittenOff(borrower, loan, lossToLenders, lossToFee);
    }

    function _recordFeePayment(uint256 amount) internal {
        _feeOwed -= amount;
        _unlent -= amount;
        feePaid += amount;
        emit FeePaid(feeRecipient, amount);
    }

    function _addBorrower(address borrower) internal {
        _borrowers.push(borrower);
        _borrowerIndex[borrower] = _borrowers.length;
    }

    function _removeBorrower(address borrower) internal {
        uint256 index = _borrowerIndex[borrower];
        if (index == 0) return;
        uint256 last = _borrowers.length;
        if (index != last) {
            address moved = _borrowers[last - 1];
            _borrowers[index - 1] = moved;
            _borrowerIndex[moved] = index;
        }
        _borrowers.pop();
        delete _borrowerIndex[borrower];
    }

    // ------------------------------------------------------------------ internals: transfers and external reads

    /// @dev Pull `amount` of `token` from the caller and return the balance difference actually received.
    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();
    }

    /// @dev Read the price source without letting a failure revert the caller. A failed call, a
    ///      malformed answer or a price of zero all report the price as unavailable.
    function _price() internal view returns (bool priceAvailable, uint256 price) {
        (bool ok, bytes memory data) = priceSource.staticcall(abi.encodeCall(IPriceSource.price, ()));
        if (!ok || data.length < 32) return (false, 0);
        price = abi.decode(data, (uint256));
        priceAvailable = price != 0;
    }

    /// @dev The loan token's decimals, or 18 when it does not answer sensibly.
    function _loanTokenDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) return 18;
        uint256 d = abi.decode(data, (uint256));
        // casting to 'uint8' is safe because d is at most 77 here
        // forge-lint: disable-next-line(unsafe-typecast)
        return d <= 77 ? uint8(d) : 18;
    }

    function _totalReceipts() internal view returns (uint256) {
        return IReceiptToken(receiptToken).totalSupply();
    }

    // ------------------------------------------------------------------ internals: pure conversions

    function _toReceiptsDown(uint256 amount, uint256 totalDeposits, uint256 totalReceipts_)
        internal
        pure
        returns (uint256)
    {
        return amount.mulDivDown(totalReceipts_ + VIRTUAL_RECEIPTS, totalDeposits + VIRTUAL_DEPOSITS);
    }

    function _toDepositsDown(uint256 receipts, uint256 totalDeposits, uint256 totalReceipts_)
        internal
        pure
        returns (uint256)
    {
        return receipts.mulDivDown(totalDeposits + VIRTUAL_DEPOSITS, totalReceipts_ + VIRTUAL_RECEIPTS);
    }

    function _toLoanUnitsUp(uint256 amount, uint256 totalLoans, uint256 totalUnits) internal pure returns (uint256) {
        return amount.mulDivUp(totalUnits + VIRTUAL_LOAN_UNITS, totalLoans + VIRTUAL_LOANS);
    }

    function _toLoanUnitsDown(uint256 amount, uint256 totalLoans, uint256 totalUnits) internal pure returns (uint256) {
        return amount.mulDivDown(totalUnits + VIRTUAL_LOAN_UNITS, totalLoans + VIRTUAL_LOANS);
    }

    function _toLoansUp(uint256 units, uint256 totalLoans, uint256 totalUnits) internal pure returns (uint256) {
        return units.mulDivUp(totalLoans + VIRTUAL_LOANS, totalUnits + VIRTUAL_LOAN_UNITS);
    }

    function _loanOf(address borrower, uint256 totalLoans, uint256 totalUnits) internal view returns (uint256) {
        uint256 units = loanUnitsOf[borrower];
        return units == 0 ? 0 : _toLoansUp(units, totalLoans, totalUnits);
    }

    /// @dev The loan `borrow` would charge a borrower holding `units` after borrowing `amount` more:
    ///      the same two roundings as `borrow`, units up on the way in and the loan up on the way out.
    function _loanAfterBorrow(uint256 units, uint256 amount, uint256 totalLoans, uint256 totalUnits)
        internal
        pure
        returns (uint256)
    {
        uint256 newUnits = _toLoanUnitsUp(amount, totalLoans, totalUnits);
        return _toLoansUp(units + newUnits, totalLoans + amount, totalUnits + newUnits);
    }

    /// @dev The highest loan allowed against `amount` of collateral at `price`: value times the borrowing limit.
    function _maxLoan(uint256 amount, uint256 price) internal view returns (uint256) {
        return amount.mulDivDown(price, PRICE_SCALE).mulDivDown(borrowingLimit, WAD);
    }

    function _isAboveLimit(address borrower, uint256 price, uint256 totalLoans) internal view returns (bool) {
        return _loanOf(borrower, totalLoans, totalLoanUnits) > _maxLoan(collateralOf[borrower], price);
    }
}
