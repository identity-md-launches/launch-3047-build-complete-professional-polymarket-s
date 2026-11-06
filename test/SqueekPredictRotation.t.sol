// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekPredict} from "../src/SqueekPredict.sol";
import {SqueekMetrics} from "../src/SqueekMetrics.sol";
import {BlockHeader} from "../src/libraries/BlockHeader.sol";
import {MockCore} from "./mocks/MockCore.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockHistory} from "./mocks/MockHistory.sol";
import {Headers} from "./helpers/Headers.sol";

/// A bettor on both sides whose receive() reverts with a 116 kB payload (return-data bomb).
contract ReturnBomb {
    function place(SqueekPredict p, uint256 id) external payable {
        p.bet{value: msg.value / 2}(id, 0);
        p.bet{value: msg.value / 2}(id, 1);
    }

    receive() external payable {
        assembly {
            revert(0, 116000)
        }
    }
}

/// Lane rotation, the Squeek betting cutoff, settlement gas bounds, upkeep reporting, history-contract
/// proofs, per-kind grace periods and the Core genesis guard.
contract SqueekPredictRotationTest is Test {
    uint64 constant GENESIS = 1_728_000_000;
    uint80 constant ROUND = (uint80(1) << 64) | 100;
    SqueekPredict predict;
    SqueekMetrics metrics;
    MockCore core;
    MockFeed eth;
    MockFeed btc;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint80 round = ROUND;

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
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        predict.maintain();
    }

    function _bet(address who, uint256 id, uint8 side, uint256 amount) internal {
        vm.prank(who);
        predict.bet{value: amount}(id, side);
    }

    /// Healthy sources: feeds refreshed and the Core frontier tracking the clock.
    function _hour() internal {
        uint256 now_ = vm.getBlockTimestamp() + 1 hours;
        vm.warp(now_);
        vm.roll(vm.getBlockNumber() + 300);
        core.setFrontier(uint64((now_ - GENESIS) / 600));
        ++round;
        eth.put(round, 2000e8, now_);
        btc.put(round, 60000e8, now_);
        predict.maintain();
    }

    function _bettable() internal view returns (uint256 n) {
        uint256[14] memory ids = predict.activeMarketIds();
        for (uint256 i; i < 14; ++i) {
            SqueekPredict.Market memory m = predict.getMarket(ids[i]);
            if (m.status == SqueekPredict.Status.Open && vm.getBlockTimestamp() < m.closesAt) ++n;
        }
    }

    function testEveryLaneKeepsABettableMarketWhileThePreviousOneObserves() public {
        assertEq(_bettable(), 14);
        SqueekPredict.Market memory first = predict.getMarket(1);
        // Squeek lanes: one full duration of betting, then the window starts and betting is closed.
        assertEq(first.closesAt, first.startsAt);
        assertGe(first.startsAt, vm.getBlockTimestamp() + 6 hours);
        assertEq((first.startsAt - GENESIS) % 600, 0);
        for (uint256 h = 1; h <= 48; ++h) {
            _hour();
            assertEq(_bettable(), 14, "a lane lost its bettable market");
            uint256[14] memory active = predict.activeMarketIds();
            uint256[14] memory observing = predict.observingMarketIds();
            for (uint256 i; i < 14; ++i) {
                if (observing[i] == 0) continue;
                SqueekPredict.Market memory o = predict.getMarket(observing[i]);
                assertEq(o.templateId, i);
                assertTrue(o.status == SqueekPredict.Status.Open && vm.getBlockTimestamp() >= o.closesAt);
                assertLt(vm.getBlockTimestamp(), o.endsAt);
                assertTrue(active[i] != observing[i]);
                // The successor never closes before its predecessor ends: one observing slot suffices.
                assertGe(predict.getMarket(active[i]).closesAt, o.endsAt);
            }
        }
        // Lane 0 (6h) has rotated several times; the first market is long settled or awaiting evidence.
        assertTrue(predict.getMarket(1).status == SqueekPredict.Status.Awaiting);
        assertGt(predict.activeMarketIds()[0], 14);
    }

    function testClosedMarketObservesAndSettlesWithoutDisturbingItsSuccessor() public {
        _bet(alice, 6, 1, 1 ether);
        _bet(bob, 6, 0, 1 ether);
        SqueekPredict.Market memory m = predict.getMarket(6);
        vm.warp(m.closesAt);
        eth.put(ROUND + 1, 2050e8, block.timestamp);
        vm.expectEmit(true, false, false, false);
        emit SqueekPredict.MarketClosed(6, 0);
        predict.maintain();
        assertEq(predict.observingMarketIds()[5], 6);
        uint256 successor = predict.activeMarketIds()[5];
        assertGt(successor, 14);
        assertEq(predict.getMarket(successor).templateId, 5);
        assertEq(predict.getMarket(successor).strike, 2050e8);
        assertGe(predict.getMarket(successor).closesAt, m.endsAt);
        vm.expectRevert(SqueekPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(6, 1);
        _bet(alice, successor, 1, 1 ether);
        // Nothing to do until the observing market ends; then settling it clears the observing slot.
        (bool needed,) = predict.checkUpkeep("");
        assertFalse(needed);
        vm.warp(m.endsAt + 60);
        (needed,) = predict.checkUpkeep("");
        assertTrue(needed);
        eth.put(ROUND + 2, 2100e8, m.endsAt - 60);
        eth.put(ROUND + 3, 2100e8, m.endsAt + 1);
        uint256 a = alice.balance;
        predict.settlePrice(6, ROUND + 2);
        assertEq(alice.balance - a, 1.98 ether);
        assertEq(predict.observingMarketIds()[5], 0);
        assertEq(predict.activeMarketIds()[5], successor);
        assertEq(uint8(predict.getMarket(successor).status), uint8(SqueekPredict.Status.Open));
    }

    function testSqueekStakesAreRefusedOnceTheWindowCanBeCertified() public {
        _bet(alice, 1, 0, 10 ether);
        _bet(bob, 1, 1, 10 ether);
        SqueekPredict.Market memory m = predict.getMarket(1);
        vm.warp(m.startsAt);
        core.setFrontier(uint64((m.startsAt - GENESIS) / 600));
        vm.expectRevert(SqueekPredict.BettingClosed.selector);
        predict.bet{value: 1 ether}(1, 1);
        // Part of the window is certified and already exceeds the strike: still no stake is accepted.
        vm.warp(m.startsAt + 2 hours);
        uint64 startRound = (m.startsAt - GENESIS) / 600;
        core.add(startRound + 1, 5000, 101e9);
        core.setFrontier(startRound + 12);
        vm.expectRevert(SqueekPredict.BettingClosed.selector);
        predict.bet{value: 100 ether}(1, 1);
        vm.warp(m.endsAt);
        core.setFrontier(startRound + 36);
        uint256 b = bob.balance;
        predict.settleSqueek(1);
        assertEq(bob.balance - b, 19.8 ether);
    }

    function testSettlementGasIsBoundedWhenPushedRecipientsRevertWithLargePayloads() public {
        for (uint256 i; i < 20; ++i) {
            new ReturnBomb().place{value: 0.002 ether}(predict, 6);
        }
        _bet(alice, 6, 1, 10 ether);
        _bet(bob, 6, 0, 10 ether);
        uint64 end = predict.getMarket(6).endsAt;
        vm.warp(end + 60);
        eth.put(ROUND + 1, 2100e8, end - 60);
        eth.put(ROUND + 2, 2100e8, end + 1);
        uint256 before = gasleft();
        predict.settlePrice(6, ROUND + 1);
        uint256 used = before - gasleft();
        assertLt(used, 3_000_000, "settlement gas depends on recipients' revert data");
        // The bombs keep their claims; the honest winner was paid or remains claimable, never refunded.
        assertEq(uint8(predict.getMarket(6).status), uint8(SqueekPredict.Status.Resolved));
        assertEq(predict.getMarket(6).paymentCursor, 20);
        assertGt(predict.claimable(6, alice), 10 ether);
        before = gasleft();
        predict.pay(6, 40);
        assertLt(before - gasleft(), 1_000_000);
        assertEq(predict.claimable(6, alice), 0);
    }

    function testCheckUpkeepIsFalseWhenNoLaneCanProgress() public {
        vm.warp(block.timestamp + 7 hours);
        vm.roll(block.number + 2100);
        eth.put(ROUND + 1, 2000e8, block.timestamp);
        btc.put(ROUND + 1, 60000e8, block.timestamp);
        predict.maintain();
        // Lane 0 closed and its successor cannot open while the Core is stale; lane 13 rolled normally.
        uint256 stuck = predict.activeMarketIds()[0];
        assertEq(uint8(predict.getMarket(stuck).status), uint8(SqueekPredict.Status.Scheduled));
        assertEq(
            uint8(predict.getMarket(predict.activeMarketIds()[13]).status), uint8(SqueekPredict.Status.Open)
        );
        vm.expectRevert();
        predict.previewOpen(stuck);
        (bool needed,) = predict.checkUpkeep("");
        assertFalse(needed, "upkeep reported although nothing can progress");
        uint256 next = predict.nextMarketId();
        predict.performUpkeep("");
        assertEq(predict.nextMarketId(), next);
        core.setFrontier(uint64((block.timestamp - GENESIS) / 600));
        (needed,) = predict.checkUpkeep("");
        assertTrue(needed);
        predict.performUpkeep("");
        assertEq(uint8(predict.getMarket(stuck).status), uint8(SqueekPredict.Status.Open));
        (needed,) = predict.checkUpkeep("");
        assertFalse(needed);
    }

    function _headers(uint256 id, uint256 number, uint256 fee)
        internal
        view
        returns (bytes memory parent, bytes memory target)
    {
        uint256 end = predict.getMarket(id).endsAt;
        parent = Headers.make(bytes32(uint256(1)), number - 1, end - 1, 1 gwei);
        target = Headers.make(keccak256(parent), number, end + 3, fee);
    }

    function testNativeProofsUseTheHistoryContractBeyond256BlocksWithinOneDay() public {
        _bet(alice, 9, 1, 1 ether);
        _bet(bob, 9, 0, 1 ether);
        (bytes memory parent, bytes memory target) = _headers(9, 8201, 11 gwei);
        uint64 end = predict.getMarket(9).endsAt;
        // Boundary block 8201 is 7,000 blocks old: BLOCKHASH is zero and no history contract exists yet.
        vm.roll(8201 + 7000);
        vm.warp(end + 7000 * 12);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        predict.settleNative(9, parent, target);
        vm.etch(BlockHeader.HISTORY, type(MockHistory).runtimeCode);
        MockHistory(BlockHeader.HISTORY).set(8201, keccak256(target));
        bytes memory forged = Headers.make(keccak256(parent), 8201, end + 3, 100 gwei);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        predict.settleNative(9, parent, forged);
        uint256 a = alice.balance;
        predict.settleNative(9, parent, target);
        assertEq(predict.getMarket(9).result, 11 gwei);
        assertEq(alice.balance - a, 1.98 ether);
        // Beyond the 8191-block ring buffer nothing is provable even with the contract present.
        (parent, target) = _headers(10, 8201, 11 gwei);
        vm.roll(8201 + 8192);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        predict.settleNative(10, parent, target);
        vm.roll(8201 + 8191);
        predict.settleNative(10, parent, target);
        assertEq(predict.getMarket(10).result, 7201);
    }

    function testNativeLanesHaveAOneDayGraceAndOthersTwoDays() public {
        assertEq(predict.resolutionGrace(8), 1 days);
        assertEq(predict.resolutionGrace(9), 1 days);
        assertEq(predict.resolutionGrace(13), 1 days);
        assertEq(predict.resolutionGrace(5), 2 days);
        assertEq(predict.resolutionGrace(0), 2 days);
        _bet(alice, 9, 1, 1 ether);
        _bet(bob, 6, 1, 1 ether);
        uint64 end = predict.getMarket(9).endsAt;
        (bytes memory parent, bytes memory target) = _headers(9, 8201, 11 gwei);
        vm.roll(8202);
        vm.setBlockhash(8201, keccak256(target));
        vm.warp(end + 1 days - 1);
        vm.expectRevert(SqueekPredict.TimeoutNotReached.selector);
        predict.expire(9);
        vm.warp(end + 1 days);
        vm.expectRevert(SqueekPredict.ResolutionExpired.selector);
        predict.settleNative(9, parent, target);
        predict.expire(9);
        assertEq(alice.balance, 999.99 ether);
        // The price lane opened at the same time still has a day of evidence time left.
        vm.expectRevert(SqueekPredict.TimeoutNotReached.selector);
        predict.expire(6);
    }

    function testMovedCoreGenesisFailsClosedToRefund() public {
        _bet(alice, 1, 1, 1 ether);
        _bet(bob, 1, 0, 1 ether);
        SqueekPredict.Market memory m = predict.getMarket(1);
        uint64 last = (m.endsAt - GENESIS) / 600;
        core.add(last, 1000, 200e9);
        core.setFrontier(last + 1);
        vm.warp(m.endsAt + 600);
        core.setGenesis(GENESIS + 600);
        vm.expectRevert(SqueekPredict.CoreReconfigured.selector);
        predict.settleSqueek(1);
        core.setGenesis(GENESIS);
        predict.settleSqueek(1);
        assertEq(predict.getMarket(1).result, 200);
        assertEq(alice.balance, 1000.98 ether);
    }
}
