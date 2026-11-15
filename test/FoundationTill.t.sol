// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BaseTest} from "./Base.t.sol";
import {FoundationTill} from "../src/FoundationTill.sol";
import {Market} from "../src/Market.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {FreezableToken} from "./mocks/FreezableToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReenteringCoin} from "./mocks/ReenteringCoin.sol";

/// @notice The foundation's till as the fee recipient of an unchanged factory: the markets pay the
///         till, the beneficiary alone collects, and the till is handed over in two steps.
contract FoundationTillTest is BaseTest {
    address internal foundation = makeAddr("foundation");
    address internal next = makeAddr("next beneficiary");
    address internal other = makeAddr("other candidate");

    FoundationTill internal till;

    function setUp() public override {
        till = new FoundationTill(foundation);
        // The factory and market of the base fixture are built with the till as the fee recipient.
        feeRecipient = address(till);
        super.setUp();
    }

    // ------------------------------------------------------------------ 3.1 construction

    function test_construction() public view {
        assertEq(till.beneficiary(), foundation);
        assertEq(till.successor(), address(0));
    }

    function test_constructor_rejectsZeroBeneficiary() public {
        vm.expectRevert(FoundationTill.ZeroAddress.selector);
        new FoundationTill(address(0));
    }

    function test_anyoneCanReadBeneficiaryAndSuccessor() public {
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.prank(stranger);
        assertEq(till.beneficiary(), foundation);
        vm.prank(stranger);
        assertEq(till.successor(), next);
    }

    // ------------------------------------------------------------------ 6.1 a market pays the till

    function test_marketPaysItsFeeIntoTheTill() public {
        assertEq(factory.feeRecipient(), address(till));
        assertEq(market.feeRecipient(), address(till));
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 800e18);
        skip(YEAR);
        uint256 owed = market.feeOwed();
        assertGt(owed, 0);
        assertEq(owed, market.totalInterest() / 10, "the fee is 10 percent of the interest");
        // Repay everything, then the fee is paid: the till holds exactly the 10 percent.
        _repay(market, borrower, market.loanOf(borrower), borrower);
        assertEq(loan.balanceOf(address(till)), 0, "repaying alone pays no fee");
        vm.prank(stranger);
        uint256 paid = market.payFee();
        assertEq(paid, owed);
        assertEq(loan.balanceOf(address(till)), owed, "the till holds the 10 percent");
        assertEq(loan.balanceOf(address(till)), market.feePaid());
        assertEq(market.feeOwed(), 0);
        assertEq(loan.balanceOf(foundation), 0, "nothing reaches the beneficiary until it collects");
        _assertIdentity(market);
        // The beneficiary collects the fee from the till.
        vm.prank(foundation);
        till.collect(address(loan));
        assertEq(loan.balanceOf(foundation), owed);
        assertEq(loan.balanceOf(address(till)), 0);
    }

    function test_withdrawPaysTheFeeIntoTheTill() public {
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 800e18);
        skip(YEAR);
        uint256 owed = market.feeOwed();
        uint256 receipts = receipt.balanceOf(lender) / 10;
        vm.prank(lender);
        market.withdraw(receipts, lender);
        assertEq(loan.balanceOf(address(till)), owed);
        assertEq(market.feeOwed(), 0);
        _assertIdentity(market);
    }

    // ------------------------------------------------------------------ 6.2 collection

    function test_collect_onlyTheBeneficiary_wholeBalance() public {
        loan.mint(address(till), 123e18);
        vm.prank(foundation);
        till.nameSuccessor(next);

        vm.prank(stranger);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.collect(address(loan));
        vm.prank(next);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.collect(address(loan));
        assertEq(loan.balanceOf(address(till)), 123e18, "nothing moved");

        vm.expectEmit(true, true, true, true, address(till));
        emit FoundationTill.Collected(address(loan), foundation, 123e18);
        vm.prank(foundation);
        till.collect(address(loan));
        assertEq(loan.balanceOf(foundation), 123e18, "the whole balance arrives at the beneficiary");
        assertEq(loan.balanceOf(address(till)), 0);
        assertEq(loan.balanceOf(stranger), 0);
        assertEq(loan.balanceOf(next), 0);

        vm.prank(foundation);
        vm.expectRevert(FoundationTill.NothingToCollect.selector);
        till.collect(address(loan));
    }

    function test_collect_oneAssetAtATime() public {
        loan.mint(address(till), 5e18);
        coll.mint(address(till), 7e18);
        vm.prank(foundation);
        till.collect(address(loan));
        assertEq(loan.balanceOf(foundation), 5e18);
        assertEq(coll.balanceOf(foundation), 0);
        assertEq(coll.balanceOf(address(till)), 7e18);
        vm.prank(foundation);
        till.collect(address(coll));
        assertEq(coll.balanceOf(foundation), 7e18);
    }

    function testFuzz_collectSendsExactlyTheBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        loan.mint(address(till), amount);
        vm.expectEmit(true, true, true, true, address(till));
        emit FoundationTill.Collected(address(loan), foundation, amount);
        vm.prank(foundation);
        till.collect(address(loan));
        assertEq(loan.balanceOf(foundation), amount);
        assertEq(loan.balanceOf(address(till)), 0);
    }

    // ------------------------------------------------------------------ 6.3 handover

    function test_acceptHandover_withNoSuccessorNamed_everyCallerRefused() public {
        assertEq(till.successor(), address(0));
        vm.prank(stranger);
        vm.expectRevert(FoundationTill.NotSuccessor.selector);
        till.acceptHandover();
        vm.prank(foundation);
        vm.expectRevert(FoundationTill.NotSuccessor.selector);
        till.acceptHandover();
        vm.prank(address(0));
        vm.expectRevert(FoundationTill.NotSuccessor.selector);
        till.acceptHandover();
        assertEq(till.beneficiary(), foundation);
    }

    function test_acceptHandover_strangerCannotAccept() public {
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.prank(stranger);
        vm.expectRevert(FoundationTill.NotSuccessor.selector);
        till.acceptHandover();
        vm.prank(foundation);
        vm.expectRevert(FoundationTill.NotSuccessor.selector);
        till.acceptHandover();
        assertEq(till.beneficiary(), foundation);
        assertEq(till.successor(), next);
    }

    function test_handover_twoSteps() public {
        vm.expectEmit(true, true, true, true, address(till));
        emit FoundationTill.SuccessorNamed(foundation, next);
        vm.prank(foundation);
        till.nameSuccessor(next);
        assertEq(till.beneficiary(), foundation, "naming changes nothing yet");
        assertEq(till.successor(), next);

        vm.expectEmit(true, true, true, true, address(till));
        emit FoundationTill.HandedOver(foundation, next);
        vm.prank(next);
        till.acceptHandover();
        assertEq(till.beneficiary(), next);
        assertEq(till.successor(), address(0), "the successor is cleared");

        // The earlier beneficiary can neither collect nor name.
        loan.mint(address(till), 1e18);
        vm.prank(foundation);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.collect(address(loan));
        vm.prank(foundation);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.nameSuccessor(other);
        vm.prank(foundation);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.nameSuccessor(foundation);
        // Nor accept again.
        vm.prank(next);
        vm.expectRevert(FoundationTill.NotSuccessor.selector);
        till.acceptHandover();
        // The new beneficiary can name.
        vm.prank(next);
        till.nameSuccessor(other);
        assertEq(till.successor(), other);
    }

    function test_handover_coinsBeforeAndAfterGoToTheNewBeneficiaryAlone() public {
        loan.mint(address(till), 10e18); // arrives before the handover
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.prank(next);
        till.acceptHandover();
        loan.mint(address(till), 5e18); // arrives after the handover

        vm.prank(foundation);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.collect(address(loan));
        vm.prank(stranger);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.collect(address(loan));

        vm.prank(next);
        till.collect(address(loan));
        assertEq(loan.balanceOf(next), 15e18, "coins from before and after the handover");
        assertEq(loan.balanceOf(foundation), 0);
        assertEq(loan.balanceOf(address(till)), 0);

        // And what a market pays after the handover is collected by the new beneficiary too.
        _deposit(market, lender, 1000e18);
        _openPosition(borrower, 1e18, 800e18);
        skip(YEAR);
        uint256 owed = market.feeOwed();
        market.payFee();
        assertEq(loan.balanceOf(address(till)), owed);
        vm.prank(next);
        till.collect(address(loan));
        assertEq(loan.balanceOf(next), 15e18 + owed);
    }

    function test_handover_chainOfThree() public {
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.prank(next);
        till.acceptHandover();
        vm.prank(next);
        till.nameSuccessor(other);
        vm.prank(other);
        till.acceptHandover();
        assertEq(till.beneficiary(), other);
        assertEq(till.successor(), address(0));
        loan.mint(address(till), 1e18);
        vm.prank(next);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.collect(address(loan));
        vm.prank(other);
        till.collect(address(loan));
        assertEq(loan.balanceOf(other), 1e18);
    }

    // ------------------------------------------------------------------ 6.4 naming

    function test_nameSuccessor_onlyTheBeneficiary() public {
        vm.prank(stranger);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.nameSuccessor(stranger);
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.prank(next);
        vm.expectRevert(FoundationTill.NotBeneficiary.selector);
        till.nameSuccessor(other);
        assertEq(till.successor(), next);
    }

    function test_nameSuccessor_replacedSuccessorCannotAccept_replacingOneCan() public {
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.expectEmit(true, true, true, true, address(till));
        emit FoundationTill.SuccessorNamed(foundation, other);
        vm.prank(foundation);
        till.nameSuccessor(other);
        assertEq(till.successor(), other);
        vm.prank(next);
        vm.expectRevert(FoundationTill.NotSuccessor.selector);
        till.acceptHandover();
        vm.prank(other);
        till.acceptHandover();
        assertEq(till.beneficiary(), other);
    }

    function test_nameSuccessor_clearedSuccessorCannotAccept() public {
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.expectEmit(true, true, true, true, address(till));
        emit FoundationTill.SuccessorNamed(foundation, address(0));
        vm.prank(foundation);
        till.nameSuccessor(address(0));
        assertEq(till.successor(), address(0));
        vm.prank(next);
        vm.expectRevert(FoundationTill.NotSuccessor.selector);
        till.acceptHandover();
        assertEq(till.beneficiary(), foundation);
    }

    function test_nameSuccessor_beneficiaryCannotNameItself() public {
        vm.prank(foundation);
        vm.expectRevert(FoundationTill.SuccessorIsBeneficiary.selector);
        till.nameSuccessor(foundation);
        assertEq(till.successor(), address(0));
        // Nor after a handover.
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.prank(next);
        till.acceptHandover();
        vm.prank(next);
        vm.expectRevert(FoundationTill.SuccessorIsBeneficiary.selector);
        till.nameSuccessor(next);
    }

    // ------------------------------------------------------------------ 6.5 awkward coins

    function test_feeOnTransferCoin_eventStatesWhatTheTillSent() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(100); // 1 percent
        fot.mint(address(till), 1000e18);
        vm.expectEmit(true, true, true, true, address(till));
        emit FoundationTill.Collected(address(fot), foundation, 1000e18);
        vm.prank(foundation);
        till.collect(address(fot));
        assertEq(fot.balanceOf(address(till)), 0, "the till sent the whole balance");
        assertEq(fot.balanceOf(foundation), 1000e18 - 10e18, "the coin delivered less, as it dictates");
    }

    function test_freezableCoin_frozenTillCannotPay_otherCoinStillPays() public {
        FreezableToken frz = new FreezableToken();
        frz.mint(address(till), 50e18);
        loan.mint(address(till), 20e18);

        frz.setFrozen(address(till), true);
        vm.prank(foundation);
        vm.expectRevert(bytes("frozen"));
        till.collect(address(frz));
        assertEq(frz.balanceOf(address(till)), 50e18);

        // The refused coin does not stop the till paying out a different coin.
        vm.prank(foundation);
        till.collect(address(loan));
        assertEq(loan.balanceOf(foundation), 20e18);

        // Unfrozen, the coin moves as it dictates.
        frz.setFrozen(address(till), false);
        vm.expectEmit(true, true, true, true, address(till));
        emit FoundationTill.Collected(address(frz), foundation, 50e18);
        vm.prank(foundation);
        till.collect(address(frz));
        assertEq(frz.balanceOf(foundation), 50e18);
    }

    function test_freezableCoin_frozenBeneficiaryCannotReceive_handoverMovesItOn() public {
        FreezableToken frz = new FreezableToken();
        frz.mint(address(till), 50e18);
        frz.setFrozen(foundation, true);
        vm.prank(foundation);
        vm.expectRevert(bytes("frozen"));
        till.collect(address(frz));
        // A handover to an unfrozen successor lets the coin out, to the new beneficiary alone.
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.prank(next);
        till.acceptHandover();
        vm.prank(next);
        till.collect(address(frz));
        assertEq(frz.balanceOf(next), 50e18);
        assertEq(frz.balanceOf(foundation), 0);
    }

    function test_collect_coinThatDoesNotMoveIsRefused_noFalseEvent() public {
        // A coin that answers false is refused by SafeERC20; nothing is recorded as collected.
        FalseCoin falseCoin = new FalseCoin();
        falseCoin.mint(address(till), 1e18);
        vm.prank(foundation);
        vm.expectRevert();
        till.collect(address(falseCoin));
        assertEq(falseCoin.balanceOf(address(till)), 1e18);
    }

    function test_collect_nonCoinAddressIsRefused() public {
        vm.prank(foundation);
        vm.expectRevert();
        till.collect(stranger);
    }

    // ------------------------------------------------------------------ 6.6 re-entry

    function test_collect_coinCallingBackCannotTakeAnythingTwice() public {
        ReenteringCoin coin = new ReenteringCoin();
        // The coin is made the beneficiary, so its callback is the one call that passes the
        // beneficiary check: only the guard against re-entry stands between it and a second collection.
        FoundationTill guarded = new FoundationTill(address(coin));
        coin.setTill(guarded);
        coin.mint(address(guarded), 100e18);

        vm.expectEmit(true, true, true, true, address(guarded));
        emit FoundationTill.Collected(address(coin), address(coin), 100e18);
        coin.drain();

        assertTrue(coin.reentered(), "the coin did call back");
        assertFalse(coin.innerSucceeded(), "the inner collect was refused");
        assertEq(
            coin.innerRevert(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "refused by the guard against re-entry"
        );
        assertEq(coin.balanceOf(address(coin)), 100e18, "collected exactly once");
        assertEq(coin.balanceOf(address(guarded)), 0);
        assertEq(coin.totalSupply(), 100e18);
    }

    // ------------------------------------------------------------------ 6.7 the chain's own currency

    function test_refusesTheChainsOwnCurrency() public {
        vm.deal(stranger, 10 ether);
        vm.deal(foundation, 10 ether);

        // Sent plainly.
        vm.prank(stranger);
        (bool ok,) = address(till).call{value: 1 ether}("");
        assertFalse(ok, "plain send refused");

        // Sent with data that matches no function.
        vm.prank(stranger);
        (ok,) = address(till).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok, "send with unknown data refused");
        vm.prank(stranger);
        (ok,) = address(till).call(hex"deadbeef");
        assertFalse(ok, "unknown data without value refused: no fallback");
        vm.prank(stranger);
        (ok,) = address(till).call("");
        assertFalse(ok, "empty call refused: no receive");

        // Sent with data that matches a function: none is payable.
        vm.prank(foundation);
        (ok,) = address(till).call{value: 1 ether}(abi.encodeCall(FoundationTill.nameSuccessor, (next)));
        assertFalse(ok, "nameSuccessor refuses value");
        vm.prank(foundation);
        (ok,) = address(till).call{value: 1 ether}(abi.encodeCall(FoundationTill.collect, (address(loan))));
        assertFalse(ok, "collect refuses value");
        vm.prank(foundation);
        till.nameSuccessor(next);
        vm.deal(next, 1 ether);
        vm.prank(next);
        (ok,) = address(till).call{value: 1 ether}(abi.encodeCall(FoundationTill.acceptHandover, ()));
        assertFalse(ok, "acceptHandover refuses value");
        vm.prank(stranger);
        (ok,) = address(till).call{value: 1 ether}(abi.encodeCall(till.beneficiary, ()));
        assertFalse(ok, "beneficiary refuses value");

        assertEq(address(till).balance, 0);
        assertEq(till.beneficiary(), foundation, "nothing changed");
        assertEq(till.successor(), next);
    }

    // ------------------------------------------------------------------ 6.8 fuzz: any sequence, any callers

    /// @notice For any sequence of naming, accepting, collecting and paying in, by any callers: coins
    ///         leave the till only to the beneficiary of that moment, and the beneficiary changes
    ///         only by an acceptance from the successor the beneficiary named.
    function testFuzz_coinsLeaveOnlyToTheBeneficiaryOfTheMoment(bytes32 seed) public {
        Model memory model;
        model.actors = [foundation, next, other, stranger, lender, address(0)];
        model.beneficiary = foundation;
        for (uint256 i = 0; i < 24; ++i) {
            _fuzzStep(model, uint256(keccak256(abi.encode(seed, i))));
        }
    }

    /// @dev The model the fuzz test keeps beside the till: the five callers (and the zero address as a
    ///      sixth argument), and who the beneficiary and the successor should be.
    struct Model {
        address[6] actors;
        address beneficiary;
        address successor;
    }

    function _fuzzStep(Model memory model, uint256 r) internal {
        address caller = model.actors[r % 5];
        uint256 op = (r >> 8) % 4;
        address beneficiaryAtStart = model.beneficiary;

        uint256[5] memory before = _balances(model);
        uint256 tillBefore = loan.balanceOf(address(till));

        if (op == 0) {
            // Anyone may pay in: a market, a stranger, anyone.
            loan.mint(address(till), ((r >> 32) % 1000e18) + 1);
        } else {
            (bytes memory data, bool shouldSucceed) =
                _fuzzCall(model, op, caller, model.actors[(r >> 16) % 6], tillBefore);
            vm.prank(caller);
            (bool ok,) = address(till).call(data);
            assertEq(ok, shouldSucceed, "the call ended as the model says");
        }

        uint256 left = op == 0 ? 0 : tillBefore - loan.balanceOf(address(till));
        uint256[5] memory after_ = _balances(model);
        for (uint256 a = 0; a < 5; ++a) {
            if (model.actors[a] == beneficiaryAtStart) {
                assertEq(after_[a] - before[a], left, "what left the till reached the beneficiary of that moment");
            } else {
                assertEq(after_[a], before[a], "nobody else received anything");
            }
        }
        assertEq(till.beneficiary(), model.beneficiary, "the beneficiary is as the model says");
        assertEq(till.successor(), model.successor, "the successor is as the model says");
    }

    /// @dev The call for `op`, and whether the till should accept it; the model moves if it should.
    function _fuzzCall(Model memory model, uint256 op, address caller, address arg, uint256 tillBefore)
        internal
        view
        returns (bytes memory data, bool shouldSucceed)
    {
        if (op == 1) {
            data = abi.encodeCall(FoundationTill.nameSuccessor, (arg));
            shouldSucceed = caller == model.beneficiary && arg != model.beneficiary;
            if (shouldSucceed) model.successor = arg;
        } else if (op == 2) {
            data = abi.encodeCall(FoundationTill.acceptHandover, ());
            shouldSucceed = model.successor != address(0) && caller == model.successor;
            if (shouldSucceed) {
                model.beneficiary = caller;
                model.successor = address(0);
            }
        } else {
            data = abi.encodeCall(FoundationTill.collect, (address(loan)));
            shouldSucceed = caller == model.beneficiary && tillBefore != 0;
        }
    }

    function _balances(Model memory model) internal view returns (uint256[5] memory balances) {
        for (uint256 a = 0; a < 5; ++a) {
            balances[a] = loan.balanceOf(model.actors[a]);
        }
    }
}

/// @notice ERC-20 whose transfers answer false without moving anything.
contract FalseCoin {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 value) external {
        balanceOf[to] += value;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
