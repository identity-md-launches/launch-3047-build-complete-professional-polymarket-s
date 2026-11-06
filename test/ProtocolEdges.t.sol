// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IndependentSetup} from "./helpers/IndependentSetup.sol";
import {SqueekPredict} from "src/SqueekPredict.sol";
import {SqueekMetrics} from "src/SqueekMetrics.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {BlockHeader} from "src/libraries/BlockHeader.sol";
import {Headers} from "./helpers/Headers.sol";

/// forge-config: default.fuzz.runs = 1000
contract ProtocolEdgesTest is IndependentSetup {
    function testMinimumMaximumAndOneWeiOutsideBetBounds() public {
        uint256[4] memory bad = [uint256(0), 1, engine.MIN_BET() - 1, engine.MAX_BET() + 1];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(SqueekPredict.InvalidAmount.selector);
            engine.bet{value: bad[i]}(6, 1);
        }
        place(alice, 6, 0, engine.MIN_BET());
        place(bob, 6, 1, engine.MAX_BET());
        assertEq(engine.getMarket(6).volume, 100.001 ether);
        assertEq(engine.retainedFees(), 1.00001 ether);
        assertAccounting(0);
    }

    function testAggregatePoolCapAcrossRepeatedCallsAndBothSides() public {
        // Reach the cap using the real public interface, without editing storage.
        vm.deal(alice, 1_100_000 ether);
        vm.startPrank(alice);
        for (uint256 i; i < 10_101; ++i) {
            engine.bet{value: 100 ether}(6, uint8(i % 2));
        }
        engine.bet{value: 1 ether + uint256(1 ether) / 99}(6, 0);
        SqueekPredict.Market memory full = engine.getMarket(6);
        assertEq(uint256(full.noPool) + full.yesPool, engine.MAX_POOL());
        vm.expectRevert(SqueekPredict.InvalidAmount.selector);
        engine.bet{value: 0.001 ether}(6, 1);
        vm.stopPrank();
        assertEq(abi.encode(engine.getMarket(6)), abi.encode(full));
        assertEq(engine.bettorCount(6), 1);
        assertAccounting(0);
    }

    function testFuzzFeeRoundsDownAndOddsMoveTowardNewStake(uint96 value, bool yes) public {
        uint256 gross = bound(value, engine.MIN_BET(), engine.MAX_BET());
        place(alice, 6, 0, 1 ether);
        place(bob, 6, 1, 1 ether);
        uint256 feesBefore = engine.retainedFees();
        place(carol, 6, yes ? 1 : 0, gross);
        uint256 charged = engine.retainedFees() - feesBefore;
        assertLe(charged * 100, gross);
        assertLt(gross - charged * 100, 100);
        SqueekPredict.Position memory p = engine.getPosition(6, carol);
        assertEq(uint256(p.noStake) + p.yesStake + charged, gross);
        (uint256 no, uint256 over) = engine.odds(6);
        assertEq(no + over, 10_000);
        assertGe(yes ? over : no, 5_000);
        assertAccounting(0);
    }

    function testPositionPaginationIsNewestFirstUniqueAndBounded() public {
        uint256[4] memory ids = [uint256(6), 8, 10, 14];
        for (uint256 i; i < ids.length; ++i) {
            place(alice, ids[i], 0, 0.001 ether);
            place(alice, ids[i], 1, 0.001 ether);
        }
        place(alice, 6, 1, 0.001 ether);
        assertEq(engine.userMarketCount(alice), 4);
        uint256[] memory page = engine.positionIds(alice, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 10);
        assertEq(page[1], 8);
        page = engine.positionIds(alice, 3, 100);
        assertEq(page.length, 1);
        assertEq(page[0], 6);
        assertEq(engine.positionIds(alice, 0, 0).length, 0);
        assertEq(engine.positionIds(alice, 4, 100).length, 0);
        assertEq(engine.positionIds(alice, type(uint256).max, 1).length, 0);
        assertEq(engine.positionIds(bob, 0, 100).length, 0);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(engine.bettorCount(ids[i]), 1);
        }
    }

    function testBatchReadsHandleEmptyMaximumDuplicateAndUnknownIds() public {
        assertEq(engine.getMarkets(new uint256[](0)).length, 0);
        uint256[] memory ids = new uint256[](100);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = 1 + i % 14;
        }
        SqueekPredict.Market[] memory result = engine.getMarkets(ids);
        assertEq(result.length, 100);
        for (uint256 i; i < result.length; ++i) {
            assertEq(abi.encode(result[i]), abi.encode(engine.getMarket(ids[i])));
        }
        ids[99] = engine.nextMarketId();
        vm.expectRevert(SqueekPredict.InvalidMarket.selector);
        engine.getMarkets(ids);
        vm.expectRevert(SqueekPredict.InvalidBatch.selector);
        engine.getMarkets(new uint256[](101));
    }

    function testFuzzUnknownIdsCannotReadMutateOrClaim(uint256 seed) public {
        uint256 id = bound(seed, engine.nextMarketId(), type(uint256).max);
        bytes[11] memory calls = [
            abi.encodeCall(engine.getMarket, (id)),
            abi.encodeCall(engine.getPosition, (id, alice)),
            abi.encodeCall(engine.bettorCount, (id)),
            abi.encodeCall(engine.odds, (id)),
            abi.encodeCall(engine.open, (id)),
            abi.encodeCall(engine.settleSqueek, (id)),
            abi.encodeCall(engine.settlePrice, (id, START_ROUND)),
            abi.encodeCall(engine.settleNative, (id, bytes(""), bytes(""))),
            abi.encodeCall(engine.expire, (id)),
            abi.encodeCall(engine.claimable, (id, alice)),
            abi.encodeCall(engine.claim, (id, payable(alice)))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(engine).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(SqueekPredict.InvalidMarket.selector));
        }
        assertEq(engine.nextMarketId(), 15);
        assertAccounting(0);
    }

    function testWrongSettlementRouteRollsBackReplacementAndBalances() public {
        place(alice, 6, 1, 1 ether);
        vm.warp(engine.getMarket(6).endsAt + 1);
        bytes memory beforeMarket = abi.encode(engine.getMarket(6));
        uint256[14] memory active = engine.activeMarketIds();
        vm.expectRevert(SqueekPredict.WrongKind.selector);
        engine.settleSqueek(6);
        vm.expectRevert(SqueekPredict.WrongKind.selector);
        engine.settleNative(6, "", "");
        vm.expectRevert(SqueekPredict.WrongKind.selector);
        engine.settlePrice(10, START_ROUND);
        assertEq(abi.encode(engine.getMarket(6)), beforeMarket);
        assertEq(abi.encode(engine.activeMarketIds()), abi.encode(active));
        assertEq(engine.nextMarketId(), 15);
        assertAccounting(0);
    }

    function testNewLaneOpensOnceAndOldAwaitingMarketSettlesWithoutSecondReplacement() public {
        place(alice, 6, 1, 1 ether);
        uint64 end = engine.getMarket(6).endsAt;
        vm.warp(end + 1);
        ethFeed.put(START_ROUND + 1, 2_100e8, end);
        ethFeed.put(START_ROUND + 2, 2_200e8, end + 1);
        engine.maintain();
        uint256 replacement = engine.activeMarketIds()[5];
        uint256 next = engine.nextMarketId();
        assertEq(uint8(engine.getMarket(6).status), uint8(SqueekPredict.Status.Awaiting));
        engine.settlePrice(6, START_ROUND + 1);
        assertEq(engine.activeMarketIds()[5], replacement);
        assertEq(engine.nextMarketId(), next);
        assertEq(engine.getMarket(replacement).volume, 0);
        vm.expectRevert(SqueekPredict.InvalidStatus.selector);
        engine.open(replacement);
        vm.expectRevert(SqueekPredict.BettingClosed.selector);
        engine.bet{value: 1 ether}(6, 1);
        assertAccounting(0);
    }

    function testMorningBetsCloseAtStartAndOtherActivityBetsUseHalfWindow() public {
        uint64 start = engine.getMarket(5).startsAt;
        assertEq(engine.getMarket(5).closesAt, start);
        vm.warp(start - 1);
        core.setFrontier(uint64((block.timestamp - GENESIS) / 600));
        place(alice, 5, 1, 1 ether);
        vm.warp(start);
        vm.expectRevert(SqueekPredict.BettingClosed.selector);
        engine.bet{value: 1 ether}(5, 1);
        // Every certified-history lane now closes at its window start; external lanes at half window.
        SqueekPredict.Market memory m = engine.getMarket(4);
        assertEq(m.closesAt, m.startsAt);
        m = engine.getMarket(6);
        assertEq(m.closesAt - m.startsAt, (m.endsAt - m.startsAt) / 2);
        assertAccounting(0);
    }

    function testSqueekHistoricalSettlementWorksWhileCorePaused() public {
        place(alice, 1, 0, 1 ether);
        SqueekPredict.Market memory m = engine.getMarket(1);
        core.setFrontier(uint64((m.endsAt - GENESIS) / 600));
        core.setPaused(true);
        vm.warp(m.endsAt);
        engine.settleSqueek(1);
        assertEq(uint8(engine.getMarket(1).status), uint8(SqueekPredict.Status.Resolved));
        assertEq(alice.balance, 999.99 ether);
        assertAccounting(0);
    }

    function testFuzzEveryInvalidBoundaryRoundPreservesFundedMarket(uint8 mutation, bool successor) public {
        place(alice, 6, 1, 1 ether);
        uint64 end = engine.getMarket(6).endsAt;
        vm.warp(end + 10);
        ethFeed.put(START_ROUND + 1, 2_100e8, end);
        ethFeed.put(START_ROUND + 2, 2_200e8, end + 1);
        uint80 key = START_ROUND + (successor ? 2 : 1);
        uint256 time = successor ? end + 1 : end;
        MockFeed.Round memory r = MockFeed.Round(key, 2_100e8, time, time, key);
        uint8 choice = mutation % 6;
        if (choice == 0) {
            r.answer = 0;
        } else if (choice == 1) {
            r.answer = -1;
        } else if (choice == 2) {
            r.updated = 0;
        } else if (choice == 3) {
            r.started = time + 1;
        } else if (choice == 4) {
            r.started = block.timestamp + 1;
            r.updated = block.timestamp + 1;
        } else {
            r.answered = key - 1;
        }
        ethFeed.corrupt(key, r);
        bytes memory beforeMarket = abi.encode(engine.getMarket(6));
        vm.expectRevert(SqueekPredict.InvalidPrice.selector);
        engine.settlePrice(6, START_ROUND + 1);
        assertEq(abi.encode(engine.getMarket(6)), beforeMarket);
        assertEq(engine.nextMarketId(), 15);
        assertAccounting(0);
    }

    function testBoundaryRoundIdentifiersCannotBeForged() public {
        uint64 end = engine.getMarket(6).endsAt;
        vm.warp(end + 10);
        ethFeed.put(START_ROUND + 1, 2_100e8, end);
        ethFeed.put(START_ROUND + 2, 2_200e8, end + 1);
        vm.expectRevert(SqueekPredict.InvalidPriceBoundary.selector);
        engine.settlePrice(6, START_ROUND - 1);
        vm.expectRevert(SqueekPredict.InvalidPriceBoundary.selector);
        engine.settlePrice(6, (uint80(1) << 64) | type(uint64).max);
        ethFeed.corrupt(START_ROUND + 1, MockFeed.Round(START_ROUND + 2, 2_100e8, end, end, START_ROUND + 2));
        vm.expectRevert(SqueekPredict.InvalidPriceBoundary.selector);
        engine.settlePrice(6, START_ROUND + 1);
    }

    function testExactTwoHourBoundaryAgesAreAcceptedButOneSecondOlderIsNot() public {
        uint64 end = engine.getMarket(6).endsAt;
        vm.warp(end + 2 hours + 1);
        ethFeed.put(START_ROUND + 1, 2_100e8, end - 2 hours);
        ethFeed.put(START_ROUND + 2, 2_200e8, end + 2 hours + 1);
        vm.expectRevert(SqueekPredict.StalePrice.selector);
        engine.settlePrice(6, START_ROUND + 1);
        ethFeed.put(START_ROUND + 2, 2_200e8, end + 2 hours);
        engine.settlePrice(6, START_ROUND + 1);
        assertEq(engine.getMarket(6).result, 2_100e8);
    }

    function testFuzzAllPriceLanesUseTheirOwnFeedAndStrictStrike(uint8 lane, bool over) public {
        uint256[4] memory ids = [uint256(6), 7, 8, 13];
        uint256 id = ids[lane % 4];
        SqueekPredict.Market memory m = engine.getMarket(id);
        place(alice, id, 1, 1 ether);
        place(bob, id, 0, 1 ether);
        finishPrice(id, int256(m.strike) + (over ? int256(1) : int256(0)));
        assertEq(engine.getMarket(id).winner, over ? 1 : 0);
        assertEq(over ? alice.balance : bob.balance, 1_000.98 ether);
        assertEq(over ? bob.balance : alice.balance, 999 ether);
        assertAccounting(0);
    }

    function testNativeProofCannotCountBlocksBeforeOpening() public {
        uint256 end = engine.getMarket(10).endsAt;
        bytes memory parent = Headers.make(bytes32(uint256(1)), 9_998, end - 1, 1 gwei);
        bytes memory target = Headers.make(keccak256(parent), 9_999, end, 1 gwei);
        vm.warp(end + 1);
        vm.roll(10_001);
        vm.setBlockhash(9_999, keccak256(target));
        vm.expectRevert(BlockHeader.NotBoundaryBlock.selector);
        engine.settleNative(10, parent, target);
        assertEq(engine.nextMarketId(), 15);
    }
}
