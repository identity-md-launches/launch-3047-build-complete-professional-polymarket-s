// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IndependentSetup, DeferredWallet, ForcedDonation} from "./helpers/IndependentSetup.sol";
import {SqueekPredict} from "src/SqueekPredict.sol";

contract ClaimReentryProbe {
    SqueekPredict internal immutable engine;
    bytes internal payload;
    uint256 public callbacks;

    constructor(SqueekPredict engine_) {
        engine = engine_;
    }

    function arm(bytes memory data) external {
        payload = data;
    }

    receive() external payable {
        (bool success, bytes memory result) = address(engine).call(payload);
        require(!success && bytes4(result) == SqueekPredict.ReentrantCall.selector, "guard missing");
        ++callbacks;
    }
}

contract ExhaustsPushGas {
    receive() external payable {
        assembly { invalid() }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract PayoutPropertiesTest is IndependentSetup {
    function testRejectedClaimRollsBackEveryDebitThenCanRetry() public {
        DeferredWallet w = wallet();
        w.place(6, 1, 1 ether);
        place(alice, 6, 0, 1 ether);
        finishPrice(6, 2_100e8);
        SqueekPredict.Market memory beforeMarket = engine.getMarket(6);
        uint256 beforeBalance = address(engine).balance;
        uint256 beforeLiability = engine.totalLiability();
        vm.expectRevert(SqueekPredict.TransferFailed.selector);
        w.withdraw(6, payable(address(w)));
        assertEq(abi.encode(engine.getMarket(6)), abi.encode(beforeMarket));
        assertFalse(engine.getPosition(6, address(w)).paid);
        assertEq(engine.totalLiability(), beforeLiability);
        assertEq(address(engine).balance, beforeBalance);
        assertEq(engine.claimable(6, address(w)), 1.98 ether);
        uint256 balance = carol.balance;
        w.withdraw(6, payable(carol));
        assertEq(carol.balance - balance, 1.98 ether);
        vm.expectRevert(SqueekPredict.NothingToClaim.selector);
        w.withdraw(6, payable(carol));
        assertAccounting(0);
    }

    function testClaimSurvivesManyGenerationsAndHasNoExpiry() public {
        DeferredWallet w = wallet();
        w.place(6, 1, 1 ether);
        place(alice, 6, 0, 2 ether);
        finishPrice(6, 2_100e8);
        uint256 owed = engine.claimable(6, address(w));
        for (uint256 i; i < 4; ++i) {
            uint256 next = engine.nextMarketId();
            vm.warp(vm.getBlockTimestamp() + 90 days);
            engine.maintain();
            assertGt(engine.nextMarketId(), next, "a later generation must actually be created");
        }
        assertEq(engine.claimable(6, address(w)), owed);
        uint256 beforeBalance = bob.balance;
        w.withdraw(6, payable(bob));
        assertEq(bob.balance - beforeBalance, 2.97 ether);
        assertEq(engine.getMarket(6).remaining, 0);
        assertAccounting(0);
    }

    function testClaimBeforeItsBatchTurnIsSkippedWithoutPayingTwice() public {
        for (uint256 i; i < 22; ++i) {
            address actor = makeAddr(string.concat("batch actor ", vm.toString(i)));
            vm.deal(actor, 1 ether);
            place(actor, 6, 1, 0.1 ether);
        }
        place(alice, 6, 0, 2.2 ether);
        finishPrice(6, 2_100e8);
        address later = makeAddr("batch actor 21");
        uint256 preview = engine.claimable(6, later);
        assertEq(preview, 0.198 ether);
        uint256 balance = carol.balance;
        vm.prank(later);
        engine.claim(6, payable(carol));
        assertEq(carol.balance - balance, preview);
        engine.pay(6, 1);
        assertEq(engine.getMarket(6).paymentCursor, 21);
        engine.pay(6, 40);
        engine.pay(6, 40);
        assertEq(engine.getMarket(6).paymentCursor, 23);
        assertEq(later.balance, 0.9 ether);
        assertEq(engine.totalLiability(), 0);
        assertEq(engine.claimable(6, later), 0);
        assertAccounting(0);
    }

    function testAllRejectingWinnersRetainDustUntilLastClaim() public {
        DeferredWallet a = wallet();
        DeferredWallet b = wallet();
        a.place(6, 1, 0.001 ether);
        b.place(6, 1, 0.002 ether);
        place(alice, 6, 0, 0.001 ether + 1);
        finishPrice(6, 2_100e8);
        assertEq(engine.retainedDust(), 0);
        uint256 claimA = engine.claimable(6, address(a));
        uint256 claimB = engine.claimable(6, address(b));
        assertEq(engine.getMarket(6).remaining, claimA + claimB + 1);
        b.withdraw(6, payable(bob));
        assertEq(engine.retainedDust(), 0);
        assertEq(engine.getMarket(6).remaining, claimA + 1);
        a.withdraw(6, payable(carol));
        assertEq(engine.retainedDust(), 1);
        assertEq(engine.totalLiability(), 0);
        assertAccounting(0);
    }

    function testGasExhaustingRecipientCannotFreezeFollowingBettors() public {
        ExhaustsPushGas gasSink = new ExhaustsPushGas();
        vm.deal(address(gasSink), 1 ether);
        place(address(gasSink), 6, 1, 1 ether);
        place(alice, 6, 1, 1 ether);
        place(bob, 6, 0, 2 ether);
        uint256 balance = alice.balance;
        finishPrice(6, 2_100e8);
        assertEq(alice.balance - balance, 1.98 ether);
        assertEq(engine.claimable(6, address(gasSink)), 1.98 ether);
        vm.prank(address(gasSink));
        engine.claim(6, payable(carol));
        assertEq(engine.totalLiability(), 0);
        assertAccounting(0);
    }

    function testFuzzClaimCannotReenterAnyGuardedEntryPoint(uint8 action) public {
        DeferredWallet w = wallet();
        w.place(6, 1, 1 ether);
        place(alice, 6, 0, 1 ether);
        finishPrice(6, 2_100e8);
        ClaimReentryProbe probe = new ClaimReentryProbe(engine);
        bytes[10] memory payloads = [
            abi.encodeCall(engine.claim, (6, payable(address(probe)))),
            abi.encodeCall(engine.bet, (6, uint8(1))),
            abi.encodeCall(engine.open, (6)),
            abi.encodeCall(engine.maintain, ()),
            abi.encodeCall(engine.performUpkeep, (bytes(""))),
            abi.encodeCall(engine.settlePrice, (6, START_ROUND + 1)),
            abi.encodeCall(engine.settleSqueek, (1)),
            abi.encodeCall(engine.settleNative, (9, bytes(""), bytes(""))),
            abi.encodeCall(engine.expire, (6)),
            abi.encodeCall(engine.pay, (6, 1))
        ];
        probe.arm(payloads[action % 10]);
        w.withdraw(6, payable(address(probe)));
        assertEq(probe.callbacks(), 1);
        assertEq(address(probe).balance, 1.98 ether);
        assertTrue(engine.getPosition(6, address(w)).paid);
        assertAccounting(0);
    }

    function testForcedEtherDoesNotChangeOddsEntitlementsOrFees() public {
        DeferredWallet w = wallet();
        w.place(6, 1, 1 ether);
        place(alice, 6, 0, 1 ether);
        bytes memory marketBefore = abi.encode(engine.getMarket(6));
        new ForcedDonation{value: 7 ether}(payable(address(engine)));
        assertEq(abi.encode(engine.getMarket(6)), marketBefore);
        (uint256 no, uint256 yes) = engine.odds(6);
        assertEq(no, 5_000);
        assertEq(yes, 5_000);
        finishPrice(6, 2_100e8);
        assertEq(engine.claimable(6, address(w)), 1.98 ether);
        w.withdraw(6, payable(bob));
        assertEq(engine.retainedFees(), 0.02 ether);
        assertEq(address(engine).balance, 7.02 ether);
        assertAccounting(7 ether);
    }

    function testOtherMarketsCannotConsumePendingWinnerLiability() public {
        DeferredWallet w = wallet();
        w.place(6, 1, 1 ether);
        place(alice, 6, 0, 1 ether);
        place(bob, 8, 0, 4 ether);
        finishPrice(6, 2_100e8);
        uint256 debt = engine.claimable(6, address(w));
        vm.warp(engine.getMarket(8).endsAt + 2 days);
        engine.expire(8);
        assertEq(engine.totalLiability(), debt);
        assertEq(engine.claimable(6, address(w)), debt);
        w.withdraw(6, payable(carol));
        assertAccounting(0);
    }

    function testFuzzPayoutBoundsAndOrderIndependence(uint96 x, uint96 y, uint96 z, bool reverse) public {
        uint256 a = bound(x, 0.001 ether, 100 ether);
        uint256 b = bound(y, 0.001 ether, 100 ether);
        uint256 c = bound(z, 0.001 ether, 100 ether);
        DeferredWallet first = wallet();
        DeferredWallet second = wallet();
        first.place(6, 1, a);
        second.place(6, 1, b);
        place(alice, 6, 0, c);
        SqueekPredict.Market memory m = engine.getMarket(6);
        uint256 stakeA = engine.getPosition(6, address(first)).yesStake;
        uint256 stakeB = engine.getPosition(6, address(second)).yesStake;
        finishPrice(6, 2_100e8);
        uint256 previewA = engine.claimable(6, address(first));
        uint256 previewB = engine.claimable(6, address(second));
        uint256 total = uint256(m.noPool) + m.yesPool;
        // Cross-products specify exact proportionality with <1 wei truncation,
        // independently of the contract's division implementation.
        assertLe(previewA * m.yesPool, stakeA * total);
        assertGt((previewA + 1) * m.yesPool, stakeA * total);
        assertLe(previewB * m.yesPool, stakeB * total);
        assertGt((previewB + 1) * m.yesPool, stakeB * total);
        uint256 balanceA = bob.balance;
        uint256 balanceB = carol.balance;
        if (reverse) {
            second.withdraw(6, payable(carol));
            assertEq(engine.claimable(6, address(first)), previewA);
            first.withdraw(6, payable(bob));
        } else {
            first.withdraw(6, payable(bob));
            assertEq(engine.claimable(6, address(second)), previewB);
            second.withdraw(6, payable(carol));
        }
        assertEq(bob.balance - balanceA, previewA);
        assertEq(carol.balance - balanceB, previewB);
        assertEq(previewA + previewB + engine.retainedDust(), total);
        assertLt(engine.retainedDust(), 2);
        assertEq(engine.totalLiability(), 0);
        assertAccounting(0);
    }

    function testFuzzSameWalletOnBothSidesCannotProfitFromRefund(uint96 x, uint96 y) public {
        uint256 a = bound(x, 0.001 ether, 100 ether);
        uint256 b = bound(y, 0.001 ether, 100 ether);
        place(alice, 6, 0, a);
        place(alice, 6, 1, b);
        vm.warp(engine.getMarket(6).endsAt + 2 days);
        engine.expire(6);
        assertLt(alice.balance, 1_000 ether);
        assertEq(1_000 ether - alice.balance, engine.retainedFees());
        assertEq(engine.totalLiability(), 0);
        assertEq(engine.retainedDust(), 0);
        assertEq(engine.bettorCount(6), 1);
        assertAccounting(0);
    }
}
