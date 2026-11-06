// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekPredict} from "../src/SqueekPredict.sol";
import {SqueekMetrics} from "../src/SqueekMetrics.sol";
import {BlockHeader} from "../src/libraries/BlockHeader.sol";
import {MockCore} from "./mocks/MockCore.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {Headers} from "./helpers/Headers.sol";

contract PaymentReceiver {
    SqueekPredict public market;
    uint256 public id;
    bool public rejecting = true;
    bool public reenter;

    constructor(SqueekPredict m) {
        market = m;
    }

    function place(uint256 id_, uint8 side) external payable {
        id = id_;
        market.bet{value: msg.value}(id_, side);
    }

    function configure(bool reject_, bool reenter_) external {
        rejecting = reject_;
        reenter = reenter_;
    }

    function withdraw(address payable to) external {
        market.claim(id, to);
    }

    receive() external payable {
        require(!rejecting, "reject payment");
        if (reenter) {
            (bool success,) = address(market).call(abi.encodeCall(market.claim, (id, payable(address(this)))));
            require(!success, "reentry succeeded");
        }
    }
}

contract SqueekPredictTest is Test {
    uint64 constant GENESIS = 1_728_000_000;
    uint80 constant ROUND = (uint80(1) << 64) | 100;
    SqueekPredict predict;
    SqueekMetrics metrics;
    MockCore core;
    MockFeed eth;
    MockFeed btc;
    address alice;
    address bob;
    address carol;

    function setUp() public {
        vm.warp(GENESIS + 1 days + 1);
        vm.roll(1000);
        vm.fee(10 gwei);
        core = new MockCore(GENESIS);
        core.setFrontier(144);
        metrics = new SqueekMetrics(address(core));
        eth = new MockFeed();
        btc = new MockFeed();
        eth.put(ROUND, 2000e8, block.timestamp);
        btc.put(ROUND, 60000e8, block.timestamp);
        predict = new SqueekPredict(address(metrics), address(eth), address(btc));
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(address(this), 1000 ether);
        predict.maintain();
    }

    function _bet(address who, uint256 id, uint8 side, uint256 amount) internal {
        vm.prank(who);
        predict.bet{value: amount}(id, side);
    }

    function _price(uint256 id, int256 value) internal {
        uint64 end = predict.getMarket(id).endsAt;
        vm.warp(end + 60);
        MockFeed feed =
            predict.getMarket(id).templateId == 7 || predict.getMarket(id).templateId == 12 ? btc : eth;
        feed.put(ROUND + 1, value, end - 60);
        feed.put(ROUND + 2, value + 1e8, end + 1);
        predict.settlePrice(id, ROUND + 1);
    }

    function _accounted() internal view {
        assertEq(
            address(predict).balance,
            predict.totalLiability() + predict.retainedFees() + predict.retainedDust()
        );
    }

    function testConstructorNoCallsNoOwnerAndFourteenLanes() public {
        address empty = makeAddr("empty");
        SqueekPredict isolated = new SqueekPredict(empty, empty, empty);
        assertEq(isolated.nextMarketId(), 15);
        assertEq(isolated.activeMarketIds().length, 14);
        assertEq(address(isolated).balance, 0);
        (bool exists,) = address(isolated).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(exists);
        vm.expectRevert(SqueekPredict.InvalidDependency.selector);
        new SqueekPredict(address(0), empty, empty);
        for (uint256 i = 1; i <= 14; ++i) {
            assertEq(uint8(predict.getMarket(i).status), uint8(SqueekPredict.Status.Open));
        }
    }

    function testApplicationRuntimeSizeAndNoEscapeOpcodes() public view {
        _checkRuntime(address(predict));
        _checkRuntime(address(metrics));
    }

    function _checkRuntime(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            if (op == 0 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }

    function testFeeOddsAndRepeatedPositionIndex() public {
        (uint256 no, uint256 yes) = predict.odds(6);
        assertEq(no, 5000);
        assertEq(yes, 5000);
        _bet(alice, 6, 1, 2 ether);
        _bet(bob, 6, 0, 1 ether);
        _bet(alice, 6, 1, 1 ether);
        (no, yes) = predict.odds(6);
        assertEq(yes, 7500);
        assertEq(no, 2500);
        assertEq(predict.retainedFees(), 0.04 ether);
        assertEq(predict.getMarket(6).volume, 4 ether);
        assertEq(predict.totalLiability(), 3.96 ether);
        assertEq(predict.bettorCount(6), 2);
        assertEq(predict.userMarketCount(alice), 1);
        assertEq(predict.positionIds(alice, 0, 10)[0], 6);
        _accounted();
    }

    function testInvalidBetsAndExactClosingBoundary() public {
        vm.expectRevert(SqueekPredict.InvalidSide.selector);
        predict.bet{value: 1 ether}(6, 2);
        vm.expectRevert(SqueekPredict.InvalidAmount.selector);
        predict.bet{value: 1}(6, 1);
        vm.expectRevert(SqueekPredict.InvalidAmount.selector);
        predict.bet{value: 101 ether}(6, 1);
        vm.expectRevert(SqueekPredict.InvalidMarket.selector);
        predict.bet{value: 1 ether}(999, 1);
        uint64 close = predict.getMarket(6).closesAt;
        vm.warp(close - 1);
        _bet(alice, 6, 1, 1 ether);
        vm.warp(close);
        vm.expectRevert(SqueekPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(6, 1);
        _accounted();
    }

    function testProportionalAutomaticPayoutAndReplacement() public {
        _bet(alice, 6, 1, 1 ether);
        _bet(bob, 6, 1, 3 ether);
        _bet(carol, 6, 0, 4 ether);
        uint256 a = alice.balance;
        uint256 b = bob.balance;
        _price(6, 2100e8);
        assertEq(alice.balance - a, 1.98 ether);
        assertEq(bob.balance - b, 5.94 ether);
        assertEq(predict.totalLiability(), 0);
        assertEq(predict.retainedFees(), 0.08 ether);
        assertEq(predict.claimable(6, alice), 0);
        uint256 replacement = predict.activeMarketIds()[5];
        assertGt(replacement, 14);
        assertEq(predict.getMarket(replacement).templateId, 5);
        (uint256 no, uint256 yes) = predict.odds(replacement);
        assertEq(no, yes);
        vm.expectRevert(SqueekPredict.InvalidStatus.selector);
        predict.settlePrice(6, ROUND + 1);
        vm.prank(alice);
        vm.expectRevert(SqueekPredict.NothingToClaim.selector);
        predict.claim(6, payable(alice));
        _accounted();
    }

    function testTieResolvesUnderAndBothSidesPerWallet() public {
        _bet(alice, 6, 1, 1 ether);
        _bet(alice, 6, 0, 1 ether);
        _bet(bob, 6, 0, 2 ether);
        uint256 a = alice.balance;
        uint256 b = bob.balance;
        _price(6, 2000e8);
        assertEq(predict.getMarket(6).winner, 0);
        assertEq(alice.balance - a, 1.32 ether);
        assertEq(bob.balance - b, 2.64 ether);
        _accounted();
    }

    function testNoWinningBetsRefundNetNotFee() public {
        _bet(alice, 6, 1, 1 ether);
        _bet(bob, 6, 1, 2 ether);
        uint256 a = alice.balance;
        uint256 b = bob.balance;
        _price(6, 1900e8);
        assertEq(uint8(predict.getMarket(6).status), uint8(SqueekPredict.Status.Refunded));
        assertEq(alice.balance - a, 0.99 ether);
        assertEq(bob.balance - b, 1.98 ether);
        _accounted();
    }

    function testEmptySettlementAndSingleSidedWinner() public {
        _price(6, 2100e8);
        assertEq(predict.totalLiability(), 0);
        uint256 id = predict.activeMarketIds()[5];
        _bet(alice, id, 1, 1 ether);
        uint64 end = predict.getMarket(id).endsAt;
        vm.warp(end + 60);
        eth.put(ROUND + 3, 2200e8, end - 60);
        eth.put(ROUND + 4, 2300e8, end + 1);
        predict.settlePrice(id, ROUND + 3);
        assertEq(alice.balance, 1000 ether - 0.01 ether);
        _accounted();
    }

    function testRejectedPushCannotBlockOthersOrStealClaims() public {
        PaymentReceiver rejector = new PaymentReceiver(predict);
        rejector.place{value: 1 ether}(6, 1);
        _bet(alice, 6, 1, 1 ether);
        _bet(bob, 6, 0, 2 ether);
        uint256 a = alice.balance;
        _price(6, 2100e8);
        assertEq(alice.balance - a, 1.98 ether);
        assertEq(predict.claimable(6, address(rejector)), 1.98 ether);
        vm.prank(carol);
        vm.expectRevert(SqueekPredict.NothingToClaim.selector);
        predict.claim(6, payable(carol));
        vm.expectRevert(SqueekPredict.TransferFailed.selector);
        rejector.withdraw(payable(address(rejector)));
        uint256 c = carol.balance;
        rejector.withdraw(payable(carol));
        assertEq(carol.balance - c, 1.98 ether);
        assertEq(predict.totalLiability(), 0);
        _accounted();
    }

    function testReentrancyDuringPushAndClaimIsRejected() public {
        PaymentReceiver attacker = new PaymentReceiver(predict);
        attacker.place{value: 1 ether}(6, 1);
        _bet(alice, 6, 0, 1 ether);
        attacker.configure(false, true);
        _price(6, 2100e8);
        assertEq(address(attacker).balance, 1.98 ether);
        assertEq(predict.totalLiability(), 0);
        _accounted();
    }

    function testManyWinnersPaidInBoundedBatchesExactlyOnce() public {
        for (uint256 i; i < 45; ++i) {
            address user = address(uint160(10000 + i));
            vm.deal(user, 1 ether);
            _bet(user, 6, 1, 0.1 ether);
        }
        _bet(alice, 6, 0, 4.5 ether);
        _price(6, 2100e8);
        assertEq(predict.getMarket(6).paymentCursor, 20);
        assertGt(predict.totalLiability(), 0);
        predict.pay(6, 40);
        predict.pay(6, 40);
        for (uint256 i; i < 45; ++i) {
            assertEq(address(uint160(10000 + i)).balance, 1.098 ether);
        }
        assertEq(predict.totalLiability(), 0);
        vm.expectRevert(SqueekPredict.InvalidBatch.selector);
        predict.pay(6, 41);
        _accounted();
    }

    function testEarlySettlementCannotResolveAndTimeoutIsFixed() public {
        _bet(alice, 6, 1, 1 ether);
        vm.expectRevert(SqueekPredict.NotEnded.selector);
        predict.settlePrice(6, ROUND);
        uint64 end = predict.getMarket(6).endsAt;
        vm.warp(end + 2 days - 1);
        vm.expectRevert(SqueekPredict.TimeoutNotReached.selector);
        predict.expire(6);
        vm.warp(end + 2 days);
        vm.expectRevert(SqueekPredict.ResolutionExpired.selector);
        predict.settlePrice(6, ROUND);
        predict.expire(6);
        assertEq(alice.balance, 999.99 ether);
        _accounted();
    }

    function testMaintainRollsFixedSlotsEvenWithBrokenOracles() public {
        vm.warp(block.timestamp + 8 days);
        eth.setBroken(true);
        core.setBroken(true);
        predict.maintain();
        uint256[14] memory ids = predict.activeMarketIds();
        for (uint256 i; i < 14; ++i) {
            assertGt(ids[i], 14);
            assertEq(predict.getMarket(ids[i]).templateId, i);
        }
        assertEq(uint8(predict.getMarket(ids[5]).status), uint8(SqueekPredict.Status.Scheduled));
        assertEq(uint8(predict.getMarket(ids[9]).status), uint8(SqueekPredict.Status.Open));
        uint256 next = predict.nextMarketId();
        predict.maintain();
        assertEq(predict.nextMarketId(), next);
        vm.expectRevert(SqueekPredict.OnlySelf.selector);
        predict.activate(ids[5]);
        core.setBroken(false);
        eth.setBroken(false);
        core.setFrontier(uint64((block.timestamp - GENESIS) / 600));
        eth.put(ROUND + 1, 2100e8, block.timestamp);
        btc.put(ROUND + 1, 65000e8, block.timestamp);
        predict.performUpkeep("");
        (bool needed,) = predict.checkUpkeep("");
        assertFalse(needed);
    }

    function testStaleOpeningPriceCannotTakeFundsAndOtherLanesWork() public {
        SqueekPredict fresh = new SqueekPredict(address(metrics), address(eth), address(btc));
        vm.warp(block.timestamp + 2 hours + 1);
        vm.expectRevert(SqueekPredict.StalePrice.selector);
        fresh.bet{value: 1 ether}(6, 1);
        assertEq(address(fresh).balance, 0);
        fresh.maintain();
        assertEq(uint8(fresh.getMarket(10).status), uint8(SqueekPredict.Status.Open));
        eth.put(ROUND + 1, 2100e8, block.timestamp);
        fresh.bet{value: 1 ether}(6, 1);
        assertEq(fresh.totalLiability(), 0.99 ether);
    }

    function testInvalidFeedAnswerTimestampDecimalsAndAnsweredRound() public {
        SqueekPredict fresh = new SqueekPredict(address(metrics), address(eth), address(btc));
        eth.put(ROUND, 0, block.timestamp);
        vm.expectRevert(SqueekPredict.InvalidPrice.selector);
        fresh.open(6);
        eth.put(ROUND, -1, block.timestamp);
        vm.expectRevert(SqueekPredict.InvalidPrice.selector);
        fresh.open(6);
        eth.put(ROUND, 2000e8, block.timestamp + 1);
        vm.expectRevert(SqueekPredict.InvalidPrice.selector);
        fresh.open(6);
        eth.put(ROUND, 2000e8, block.timestamp);
        eth.setDecimals(18);
        vm.expectRevert(SqueekPredict.InvalidPrice.selector);
        fresh.open(6);
        eth.setDecimals(8);
        eth.corrupt(ROUND, MockFeed.Round(ROUND, 2000e8, block.timestamp, block.timestamp, ROUND - 1));
        vm.expectRevert(SqueekPredict.InvalidPrice.selector);
        fresh.open(6);
    }

    function testCannotChooseLaterPriceOrSkipDeadlineRound() public {
        uint64 end = predict.getMarket(6).endsAt;
        vm.warp(end + 120);
        eth.put(ROUND + 1, 1900e8, end - 60);
        eth.put(ROUND + 2, 2200e8, end + 1);
        eth.put(ROUND + 3, 2400e8, end + 60);
        vm.expectRevert(SqueekPredict.InvalidPriceBoundary.selector);
        predict.settlePrice(6, ROUND + 2);
        vm.expectRevert(SqueekPredict.InvalidPriceBoundary.selector);
        predict.settlePrice(6, ROUND);
        predict.settlePrice(6, ROUND + 1);
        assertEq(predict.getMarket(6).result, 1900e8);
    }

    function testExactExpiryFeedTimestampWinsOverPrevious() public {
        uint64 end = predict.getMarket(6).endsAt;
        vm.warp(end + 120);
        eth.put(ROUND + 1, 1900e8, end - 60);
        eth.put(ROUND + 2, 2200e8, end);
        eth.put(ROUND + 3, 2400e8, end + 60);
        vm.expectRevert(SqueekPredict.InvalidPriceBoundary.selector);
        predict.settlePrice(6, ROUND + 1);
        predict.settlePrice(6, ROUND + 2);
        assertEq(predict.getMarket(6).result, 2200e8);
    }

    function testStaleBoundaryPhaseChangeAndMissingRoundFailClosed() public {
        uint64 end = predict.getMarket(6).endsAt;
        vm.warp(end + 60);
        eth.put(ROUND + 1, 2100e8, end - 2 hours - 1);
        eth.put(ROUND + 2, 2200e8, end + 1);
        vm.expectRevert(SqueekPredict.StalePrice.selector);
        predict.settlePrice(6, ROUND + 1);
        vm.expectRevert(SqueekPredict.InvalidPriceBoundary.selector);
        predict.settlePrice(6, (uint80(2) << 64) | 1);
        eth.put(ROUND + 3, 2100e8, end - 1);
        vm.expectRevert();
        predict.settlePrice(6, ROUND + 3);
    }

    function testSqueekSettlementReadsExactCertifiedWindowAndPays() public {
        _bet(alice, 1, 1, 1 ether);
        _bet(bob, 1, 0, 1 ether);
        SqueekPredict.Market memory m = predict.getMarket(1);
        uint64 first = (m.startsAt - GENESIS) / 600;
        uint64 last = (m.endsAt - GENESIS) / 600;
        core.add(first, 1, 900_000_000);
        core.add(last, 1000, 100_200_000_000);
        core.add(last + 1, 10000, 10000e9); // Must not leak into the measured interval.
        core.setFrontier(last + 1);
        vm.warp(m.endsAt + 600);
        predict.settleSqueek(1);
        assertEq(predict.getMarket(1).result, 101);
        assertEq(alice.balance, 1000.98 ether);
        _accounted();
    }

    function testMissingSqueekCertificationThenRecoveryOrRefund() public {
        _bet(alice, 1, 0, 1 ether);
        SqueekPredict.Market memory m = predict.getMarket(1);
        vm.warp(m.endsAt);
        vm.expectRevert();
        predict.settleSqueek(1);
        predict.maintain();
        assertGt(predict.activeMarketIds()[0], 14);
        vm.warp(m.endsAt + 2 days);
        predict.expire(1);
        assertEq(alice.balance, 999.99 ether);
        _accounted();
    }

    function _headers(uint256 id, uint256 number, uint256 fee)
        internal
        returns (bytes memory parent, bytes memory target)
    {
        uint256 end = predict.getMarket(id).endsAt;
        parent = Headers.make(bytes32(uint256(1)), number - 1, end - 1, 1 gwei);
        target = Headers.make(keccak256(parent), number, end + 3, fee);
        vm.roll(number + 1);
        vm.warp(end + 15);
        vm.setBlockhash(number, keccak256(target));
    }

    function testNativeGasAndBlockMarketsUseAuthenticatedBoundary() public {
        _bet(alice, 9, 1, 1 ether);
        _bet(bob, 9, 0, 1 ether);
        (bytes memory parent, bytes memory target) = _headers(9, 8201, 11 gwei);
        predict.settleNative(9, parent, target);
        predict.settleNative(10, parent, target);
        assertEq(predict.getMarket(9).result, 11 gwei);
        assertEq(predict.getMarket(10).result, 7201);
        assertEq(alice.balance, 1000.98 ether);
        _accounted();
    }

    function testForgedHeaderLaterSampleAndExpiredHashAreRejected() public {
        (bytes memory parent, bytes memory target) = _headers(9, 8201, 11 gwei);
        bytes memory fake = Headers.make(keccak256(parent), 8201, predict.getMarket(9).endsAt + 3, 100 gwei);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        predict.settleNative(9, parent, fake);
        bytes memory later = Headers.make(keccak256(target), 8202, predict.getMarket(9).endsAt + 15, 100 gwei);
        vm.roll(8203);
        vm.setBlockhash(8202, keccak256(later));
        vm.expectRevert(BlockHeader.NotBoundaryBlock.selector);
        predict.settleNative(9, target, later);
        vm.roll(8458);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        predict.settleNative(9, parent, target);
    }

    function testInvalidBatchRecipientAndUnknownMarket() public {
        vm.expectRevert(SqueekPredict.InvalidRecipient.selector);
        predict.claim(6, payable(address(0)));
        vm.expectRevert(SqueekPredict.InvalidRecipient.selector);
        predict.claim(6, payable(address(predict)));
        vm.expectRevert(SqueekPredict.InvalidBatch.selector);
        predict.positionIds(alice, 0, 101);
        vm.expectRevert(SqueekPredict.InvalidMarket.selector);
        predict.getMarket(0);
        vm.expectRevert(SqueekPredict.InvalidMarket.selector);
        predict.marketTemplate(14);
        vm.expectRevert(SqueekPredict.InvalidStatus.selector);
        predict.pay(6, 10);
        vm.expectRevert(SqueekPredict.OnlySelf.selector);
        predict.activate(6);
    }

    function testPausedAndStaleCoreRejectNewStakesButPreserveRefunds() public {
        _bet(alice, 1, 1, 1 ether);
        core.setPaused(true);
        vm.expectRevert(SqueekMetrics.CorePaused.selector);
        predict.bet{value: 1 ether}(1, 1);
        core.setPaused(false);
        vm.warp(block.timestamp + 6 hours + 1);
        vm.expectRevert();
        predict.bet{value: 1 ether}(2, 1);
        assertEq(predict.totalLiability(), 0.99 ether);
        vm.warp(predict.getMarket(1).endsAt + 2 days);
        predict.expire(1);
        assertEq(alice.balance, 999.99 ether);
        _accounted();
    }

    function testFuzzConservationProportionalPayoutAndRounding(uint96 x, uint96 y, uint96 z, bool yesWins)
        public
    {
        uint256 a = bound(x, 0.001 ether, 100 ether);
        uint256 b = bound(y, 0.001 ether, 100 ether);
        uint256 c = bound(z, 0.001 ether, 100 ether);
        uint256 netA = a - a / 100;
        uint256 netB = b - b / 100;
        uint256 netC = c - c / 100;
        _bet(alice, 6, 1, a);
        _bet(bob, 6, 1, b);
        _bet(carol, 6, 0, c);
        _accounted();
        uint256 beforeA = alice.balance;
        uint256 beforeB = bob.balance;
        uint256 beforeC = carol.balance;
        _price(6, yesWins ? int256(2100e8) : int256(1900e8));
        uint256 pool = netA + netB + netC;
        assertEq(alice.balance - beforeA, yesWins ? netA * pool / (netA + netB) : 0);
        assertEq(bob.balance - beforeB, yesWins ? netB * pool / (netA + netB) : 0);
        assertEq(carol.balance - beforeC, yesWins ? 0 : pool);
        assertEq(predict.retainedFees(), a / 100 + b / 100 + c / 100);
        assertEq(predict.getMarket(6).volume, a + b + c);
        assertLe(predict.retainedDust(), 1);
        assertEq(predict.totalLiability(), 0);
        _accounted();
    }
}
