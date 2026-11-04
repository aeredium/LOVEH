// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Market} from "../../src/Market.sol";
import {ReceiptToken} from "../../src/ReceiptToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceSource} from "../mocks/MockPriceSource.sol";

/// @notice Drives one market through random sequences of every action: deposit, withdraw, collateral
///         in and out, borrow, repay, liquidate, payFee, accrue, time passing, price moves and price
///         outages. Records ghosts the invariants check.
contract Handler is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant PRICE_SCALE = 1e36;

    Market public market;
    MockERC20 public loan;
    MockERC20 public coll;
    MockPriceSource public price;
    ReceiptToken public receipt;
    uint256 public immutable basePrice;

    address[] public actors;
    address public liquidator = makeAddr("liquidator");

    // ghosts
    uint256 public calls;
    uint256 public successes;
    address public lastBorrowerActor;
    bool public lastWasBorrowerAction;
    uint256 public ghostLossEvents;
    uint256 public ghostLiquidations;
    uint256 public ghostBorrows;
    uint256 public ghostDeposits;
    uint256 public ghostCollateralDeposits;
    uint256 public ghostFeePaidByHandler;
    bool public ghostLossExceededDeposits;

    constructor(Market market_, MockPriceSource price_, uint256 basePrice_) {
        market = market_;
        loan = MockERC20(market_.loanToken());
        coll = MockERC20(market_.collateralToken());
        price = price_;
        receipt = ReceiptToken(market_.receiptToken());
        basePrice = basePrice_;
        for (uint256 i = 0; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.startPrank(a);
            loan.approve(address(market), type(uint256).max);
            coll.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
        vm.startPrank(liquidator);
        loan.approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------ helpers

    modifier countCall() {
        ++calls;
        lastWasBorrowerAction = false;
        _;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _rawPrice() internal view returns (uint256) {
        if (price.reverting() || price.malformed()) return 0;
        (bool ok, bytes memory data) = address(price).staticcall(abi.encodeWithSignature("price()"));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    // ------------------------------------------------------------------ actions

    function deposit(uint256 seed, uint256 amount) external countCall {
        address a = _actor(seed);
        amount = bound(amount, 1, 1_000_000e18);
        loan.mint(a, amount);
        vm.prank(a);
        try market.deposit(amount, a) {
            ++successes;
            ++ghostDeposits;
        } catch {}
    }

    function withdraw(uint256 seed, uint256 fraction) external countCall {
        address a = _actor(seed);
        uint256 bal = receipt.balanceOf(a);
        if (bal == 0) return;
        uint256 amount = bound(fraction, 1, bal);
        vm.prank(a);
        try market.withdraw(amount, a) {
            ++successes;
        } catch {}
    }

    function depositCollateral(uint256 seed, uint256 amount) external countCall {
        address a = _actor(seed);
        amount = bound(amount, 1, 1000e18);
        coll.mint(a, amount);
        vm.prank(a);
        try market.depositCollateral(amount, a) {
            ++successes;
            ++ghostCollateralDeposits;
        } catch {}
    }

    function withdrawCollateral(uint256 seed, uint256 fraction) external countCall {
        address a = _actor(seed);
        uint256 held = market.collateralOf(a);
        if (held == 0) return;
        uint256 amount = bound(fraction, 1, held);
        vm.prank(a);
        try market.withdrawCollateral(amount, a) {
            ++successes;
            lastWasBorrowerAction = true;
            lastBorrowerActor = a;
        } catch {}
    }

    function borrow(uint256 seed, uint256 fraction) external countCall {
        address a = _actor(seed);
        (bool ok, uint256 maxLoan) = market.maxLoanOf(a);
        if (!ok) {
            vm.prank(a);
            try market.borrow(1, a) {
                revert("borrow with no price must fail");
            } catch {}
            return;
        }
        // Prefer an actor with room to borrow, so borrowing actually happens often.
        uint256 room;
        for (uint256 i = 0; i < actors.length; ++i) {
            address candidate = actors[(seed % actors.length + i) % actors.length];
            (, uint256 candidateMax) = market.maxLoanOf(candidate);
            uint256 candidateOwed = market.loanOf(candidate);
            if (candidateMax > candidateOwed) {
                a = candidate;
                maxLoan = candidateMax;
                room = candidateMax - candidateOwed;
                break;
            }
        }
        uint256 unlent = market.unlent();
        uint256 cap = room < unlent ? room : unlent;
        // Mostly within reach, sometimes deliberately above the limit to prove the refusal.
        uint256 amount = fraction % 10 == 0 ? bound(fraction, cap + 1, cap + 1e24) : bound(fraction, 0, cap);
        if (amount == 0) return;
        vm.prank(a);
        try market.borrow(amount, a) {
            ++successes;
            ++ghostBorrows;
            lastWasBorrowerAction = true;
            lastBorrowerActor = a;
            require(amount <= cap, "borrow above the limit or unlent succeeded");
        } catch {
            require(amount > cap, "borrow within the limit failed");
        }
    }

    function repay(uint256 seed, uint256 fraction) external countCall {
        address a = _actor(seed);
        address target = _actor(fraction);
        uint256 owed = market.loanOf(target);
        if (owed == 0) return;
        uint256 amount = bound(fraction, 1, owed + owed / 10);
        loan.mint(a, amount);
        vm.prank(a);
        try market.repay(amount, target) {
            ++successes;
        } catch {}
    }

    function liquidate(uint256 seed, uint256 fraction) external countCall {
        address target = _actor(seed);
        // Prefer a borrower actually above the limit, if there is one; otherwise prove the refusal.
        (bool okAll, address[] memory above,,) = market.loansAboveLimit(0, 16);
        if (okAll && above.length != 0 && seed % 4 != 0) target = above[seed % above.length];
        uint256 owed = market.loanOf(target);
        if (owed == 0) return;
        uint256 amount = bound(fraction, 1, owed);
        loan.mint(liquidator, amount);
        (bool ok, uint256 maxLoan) = market.maxLoanOf(target);
        bool liquidatable = ok && owed > maxLoan;
        uint256 depositsBefore = market.deposits();
        uint256 lossBefore = market.totalLoss();
        uint256 feeWrittenBefore = market.feeWrittenOff();
        vm.prank(liquidator);
        try market.liquidate(target, amount) {
            ++successes;
            ++ghostLiquidations;
            require(liquidatable, "liquidation of a sound loan succeeded");
            if (market.totalLoss() > lossBefore || market.feeWrittenOff() > feeWrittenBefore) {
                ++ghostLossEvents;
                require(market.collateralOf(target) == 0, "loss without exhausted collateral");
                require(market.loanOf(target) == 0, "loss with loan remaining");
            }
            if (market.feeWrittenOff() > feeWrittenBefore) {
                ghostLossExceededDeposits = true;
                require(market.deposits() == 0, "fee written off while deposits remain");
                require(market.totalLoss() - lossBefore == depositsBefore, "fee written off before every deposit");
            }
        } catch {
            require(!liquidatable, "liquidation of an unsound loan failed");
        }
    }

    function payFee() external countCall {
        uint256 before = loan.balanceOf(market.feeRecipient());
        uint256 paid = market.payFee();
        ++successes;
        ghostFeePaidByHandler += paid;
        require(loan.balanceOf(market.feeRecipient()) == before + paid, "fee not received");
    }

    function accrue() external countCall {
        market.accrue();
        ++successes;
    }

    function warp(uint256 secs) external countCall {
        secs = bound(secs, 1, 30 days);
        vm.warp(block.timestamp + secs);
        ++successes;
    }

    function movePrice(uint256 pct) external countCall {
        pct = bound(pct, 20, 180);
        uint256 current = _rawPrice();
        if (current == 0) current = basePrice;
        uint256 next = current * pct / 100;
        if (next < basePrice / 1000) next = basePrice / 1000;
        if (next > basePrice * 1000) next = basePrice * 1000;
        price.setReverting(false);
        price.setMalformed(false);
        price.setPrice(next);
        ++successes;
    }

    function priceCrash(uint256 pct) external countCall {
        pct = bound(pct, 5, 70);
        uint256 current = _rawPrice();
        if (current == 0) current = basePrice;
        uint256 next = current * pct / 100;
        if (next < basePrice / 1000) next = basePrice / 1000;
        price.setReverting(false);
        price.setMalformed(false);
        price.setPrice(next);
        ++successes;
    }

    function priceOutage(uint256 kind) external countCall {
        kind = kind % 6;
        if (kind == 0) {
            price.setPrice(0);
        } else if (kind == 1) {
            price.setReverting(true);
        } else if (kind == 2) {
            price.setMalformed(true);
        } else {
            // Half the time the outage ends instead.
            price.setReverting(false);
            price.setMalformed(false);
            if (_rawPrice() == 0) price.setPrice(basePrice);
        }
        ++successes;
    }

    function donate(uint256 amount) external countCall {
        // Tokens sent directly to the market are credited to nobody; the handler records them so the
        // balance identity can account for them.
        amount = bound(amount, 1, 1e24);
        loan.mint(address(market), amount);
        ghostDonations += amount;
        ++successes;
    }

    uint256 public ghostDonations;
}
