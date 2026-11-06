// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IndependentSetup} from "./helpers/IndependentSetup.sol";
import {SqueekPredict} from "src/SqueekPredict.sol";
import {SqueekMetrics} from "src/SqueekMetrics.sol";
import {BlockHeader} from "src/libraries/BlockHeader.sol";
import {Headers} from "./helpers/Headers.sol";

contract GenerationHeaderReader {
    function boundary(bytes calldata parent, bytes calldata target, uint256 end)
        external
        view
        returns (BlockHeader.Header memory)
    {
        return BlockHeader.boundary(parent, target, end);
    }
}

/// @dev Stand-ins for a misbehaving history contract at the EIP-2935 address.
contract LongAnswerHistory {
    bytes32 public answer;

    function set(bytes32 value) external {
        answer = value;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(answer, answer);
    }
}

contract RevertingHistory {
    fallback(bytes calldata) external returns (bytes memory) {
        revert("history unavailable");
    }
}

contract HonestHistory {
    mapping(uint256 => bytes32) public hashes;

    function set(uint256 number, bytes32 hash) external {
        hashes[number] = hash;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        return abi.encode(hashes[abi.decode(data, (uint256))]);
    }
}

/// Overlapping lane generations, the Squeek pre-window cutoff, the Core genesis guard and
/// history-backed header proofs, exercised from the outside with adversarial timing.
contract GenerationLifecycleTest is IndependentSetup {
    uint64 internal opened;

    function setUp() public override {
        super.setUp();
        opened = uint64(block.timestamp);
    }

    function healthy(uint80 roundOffset) internal {
        core.setFrontier(uint64((block.timestamp - GENESIS) / 600));
        ethFeed.put(START_ROUND + roundOffset, 2_000e8, block.timestamp);
        btcFeed.put(START_ROUND + roundOffset, 60_000e8, block.timestamp);
    }

    function status(uint256 id) internal view returns (uint8) {
        return uint8(engine.getMarket(id).status);
    }

    function testPriceBetsStopExactlyAtCloseAndSuccessorTakesFreshStrike() public {
        SqueekPredict.Market memory m = engine.getMarket(6);
        vm.warp(m.closesAt - 1);
        place(alice, 6, 1, 1 ether);
        vm.warp(m.closesAt);
        // Betting closes on the clock, before any keeper has rotated the lane.
        vm.prank(bob);
        vm.expectRevert(SqueekPredict.BettingClosed.selector);
        engine.bet{value: 1 ether}(6, 0);
        core.setFrontier(uint64((block.timestamp - GENESIS) / 600));
        ethFeed.put(START_ROUND + 1, 2_345e8, block.timestamp);
        btcFeed.put(START_ROUND + 1, 61_000e8, block.timestamp);
        engine.maintain();

        assertEq(engine.observingMarketIds()[5], 6);
        uint256 successor = engine.activeMarketIds()[5];
        SqueekPredict.Market memory s = engine.getMarket(successor);
        assertEq(s.templateId, 5);
        assertEq(uint8(s.status), uint8(SqueekPredict.Status.Open));
        assertEq(s.strike, 2_345e8);
        assertEq(s.startRound, START_ROUND + 1);
        assertEq(s.startsAt, m.closesAt);
        assertEq(s.closesAt, m.endsAt, "maintained on time, successor closes exactly when predecessor ends");

        SqueekPredict.Market memory closed = engine.getMarket(6);
        assertEq(closed.strike, m.strike, "rotation cannot rewrite the observing market");
        assertEq(closed.endsAt, m.endsAt);
        assertEq(closed.yesPool, 0.99 ether);
        assertEq(uint8(closed.status), uint8(SqueekPredict.Status.Open));

        // A second maintain in the same block is a no-op.
        uint256 next = engine.nextMarketId();
        bytes memory active = abi.encode(engine.activeMarketIds());
        bytes memory observing = abi.encode(engine.observingMarketIds());
        engine.maintain();
        assertEq(engine.nextMarketId(), next);
        assertEq(abi.encode(engine.activeMarketIds()), active);
        assertEq(abi.encode(engine.observingMarketIds()), observing);
        (bool needed,) = engine.checkUpkeep("");
        assertFalse(needed);

        place(bob, successor, 0, 2 ether);
        assertEq(engine.getMarket(6).noPool, 0, "successor stakes never reach the observing pool");
        assertAccounting(0);
    }

    function testObservingMarketTimesOutToExactRefundWithoutTouchingSuccessor() public {
        place(alice, 6, 1, 1 ether);
        place(bob, 6, 0, 2 ether);
        SqueekPredict.Market memory m = engine.getMarket(6);
        vm.warp(m.closesAt);
        healthy(1);
        engine.maintain();
        uint256 successor = engine.activeMarketIds()[5];
        place(carol, successor, 1, 1 ether);

        vm.warp(m.endsAt + engine.RESOLUTION_GRACE() - 1);
        vm.expectRevert(SqueekPredict.TimeoutNotReached.selector);
        engine.expire(6);
        vm.warp(m.endsAt + engine.RESOLUTION_GRACE());
        vm.expectRevert(SqueekPredict.ResolutionExpired.selector);
        engine.settlePrice(6, START_ROUND + 1);
        engine.expire(6);

        assertEq(status(6), uint8(SqueekPredict.Status.Refunded));
        assertEq(alice.balance, 1_000 ether - 0.01 ether);
        assertEq(bob.balance, 1_000 ether - 0.02 ether);
        assertEq(engine.observingMarketIds()[5], 0);
        assertEq(engine.activeMarketIds()[5], successor);
        assertEq(status(successor), uint8(SqueekPredict.Status.Open));
        assertEq(engine.getMarket(successor).remaining, 0.99 ether);
        assertEq(engine.totalLiability(), 0.99 ether);
        assertAccounting(0);
    }

    function testKeeperSkippingTheWholeWindowRetiresDirectlyWithOneSuccessor() public {
        place(alice, 6, 1, 1 ether);
        SqueekPredict.Market memory m = engine.getMarket(6);
        vm.warp(m.endsAt + 1);
        healthy(1);
        engine.maintain();
        assertEq(status(6), uint8(SqueekPredict.Status.Awaiting));
        assertEq(engine.observingMarketIds()[5], 0, "an ended market never occupies the observing slot");
        SqueekPredict.Market memory s = engine.getMarket(engine.activeMarketIds()[5]);
        assertEq(uint8(s.status), uint8(SqueekPredict.Status.Open));
        assertEq(s.startsAt, block.timestamp);
        // Exactly one successor exists for the lane: the previous id is the old market itself.
        uint256 count;
        for (uint256 id = 15; id < engine.nextMarketId(); ++id) {
            if (engine.getMarket(id).templateId == 5) ++count;
        }
        assertEq(count, 1);
    }

    function testSettlingAnUnrotatedActiveMarketSchedulesItsSuccessor() public {
        place(alice, 6, 1, 1 ether);
        place(bob, 6, 0, 1 ether);
        uint64 end = engine.getMarket(6).endsAt;
        vm.warp(end + 60);
        ethFeed.put(START_ROUND + 1, 2_100e8, end - 1);
        ethFeed.put(START_ROUND + 2, 2_100e8, end + 30);
        engine.settlePrice(6, START_ROUND + 1);
        assertEq(alice.balance, 1_000.98 ether);
        uint256 successor = engine.activeMarketIds()[5];
        assertGt(successor, 14);
        assertEq(engine.getMarket(successor).templateId, 5);
        assertEq(status(successor), uint8(SqueekPredict.Status.Open));
        assertEq(engine.getMarket(successor).strike, 2_100e8);
        assertEq(engine.observingMarketIds()[5], 0);
        assertAccounting(0);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzSqueekLanesTakeStakesOnlyBeforeTheirWindowStarts(uint8 laneSeed, uint256 when) public {
        uint256[7] memory ids = [uint256(1), 2, 3, 4, 5, 11, 12];
        uint256 id = ids[laneSeed % 7];
        SqueekPredict.Market memory m = engine.getMarket(id);
        (, uint32 duration,) = engine.marketTemplate(m.templateId);
        assertEq(m.closesAt, m.startsAt);
        assertEq((m.startsAt - GENESIS) % 600, 0);
        assertEq(m.startRound, (m.startsAt - GENESIS) / 600);
        assertEq(m.endsAt - m.startsAt, duration);
        if (m.templateId == 4) {
            assertEq(m.startsAt, (uint256(opened) / 1 days + 1) * 1 days);
        } else {
            assertGe(m.startsAt, opened + duration, "a full duration of betting before the window");
            assertLt(m.startsAt, opened + duration + 600);
        }
        vm.warp(bound(when, opened, m.closesAt - 1));
        core.setFrontier(uint64((block.timestamp - GENESIS) / 600));
        place(carol, id, 1, 1 ether);
        vm.warp(m.closesAt);
        core.setFrontier(uint64((block.timestamp - GENESIS) / 600));
        vm.prank(carol);
        vm.expectRevert(SqueekPredict.BettingClosed.selector);
        engine.bet{value: 1 ether}(id, 0);
        assertAccounting(0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzSqueekSuccessorWindowStartsExactlyWherePredecessorEnds(uint8 laneSeed, uint256 lag)
        public
    {
        uint256[7] memory ids = [uint256(1), 2, 3, 4, 5, 11, 12];
        uint256 id = ids[laneSeed % 7];
        SqueekPredict.Market memory m = engine.getMarket(id);
        // Rotated anywhere in the first round after closing.
        lag = bound(lag, 0, 599);
        vm.warp(m.closesAt + lag);
        healthy(1);
        engine.maintain();
        assertEq(engine.observingMarketIds()[m.templateId], id);
        SqueekPredict.Market memory s = engine.getMarket(engine.activeMarketIds()[m.templateId]);
        assertEq(uint8(s.status), uint8(SqueekPredict.Status.Open));
        // Never overlapping. A rotation on the closing second or a daily lane abuts exactly; a late
        // rotation of a rolling lane skips at most one unobserved 10-minute round.
        assertGe(s.startsAt, m.endsAt, "consecutive windows cannot overlap");
        if (lag == 0 || m.templateId == 4) assertEq(s.startsAt, m.endsAt);
        else assertEq(s.startsAt, m.endsAt + 600);
        assertGe(s.closesAt, m.endsAt);
        assertEq(s.endsAt - s.startsAt, m.endsAt - m.startsAt);
        assertEq(s.strike, m.strike);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzAnyCoreGenesisMoveFailsClosedAndStakesRefund(uint256 shiftSeed, bool later) public {
        place(alice, 1, 1, 1 ether);
        place(bob, 1, 0, 1 ether);
        SqueekPredict.Market memory m = engine.getMarket(1);
        uint64 last = (m.endsAt - GENESIS) / 600;
        core.add(last, 1000, 200e9);
        core.setFrontier(last + 1);
        vm.warp(m.endsAt + 600);
        uint64 shift = uint64(bound(shiftSeed, 1, 1 days));
        core.setGenesis(later ? GENESIS + shift : GENESIS - shift);
        bytes memory beforeMarket = abi.encode(engine.getMarket(1));
        uint256 next = engine.nextMarketId();
        if (shift % 600 == 0) vm.expectRevert(SqueekPredict.CoreReconfigured.selector);
        else vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
        engine.settleSqueek(1);
        assertEq(abi.encode(engine.getMarket(1)), beforeMarket);
        assertEq(engine.nextMarketId(), next);
        vm.warp(m.endsAt + engine.resolutionGrace(0));
        engine.expire(1);
        assertEq(alice.balance, 999.99 ether);
        assertEq(bob.balance, 999.99 ether);
        assertEq(engine.totalLiability(), 0);
        assertAccounting(0);
    }

    function testUnchangedGenesisStillSettlesAfterLaneRotation() public {
        place(alice, 1, 1, 1 ether);
        place(bob, 1, 0, 1 ether);
        SqueekPredict.Market memory m = engine.getMarket(1);
        vm.warp(m.closesAt);
        healthy(1);
        engine.maintain();
        assertEq(engine.observingMarketIds()[0], 1);
        uint64 first = (m.startsAt - GENESIS) / 600;
        core.add(first + 1, 1000, uint96(m.strike * 1e9 + 1e9));
        vm.warp(m.endsAt);
        core.setFrontier((m.endsAt - GENESIS) / 600);
        engine.settleSqueek(1);
        assertEq(engine.getMarket(1).result, m.strike + 1);
        assertEq(engine.observingMarketIds()[0], 0);
        assertEq(alice.balance, 1_000.98 ether);
        assertAccounting(0);
    }

    function testPreviewOpenAndActivateRejectEveryNonScheduledOrForeignCall() public {
        vm.expectRevert(SqueekPredict.InvalidMarket.selector);
        engine.previewOpen(0);
        uint256 unborn = engine.nextMarketId();
        vm.expectRevert(SqueekPredict.InvalidMarket.selector);
        engine.previewOpen(unborn);
        vm.expectRevert(SqueekPredict.InvalidStatus.selector);
        engine.previewOpen(6);
        vm.prank(alice);
        vm.expectRevert(SqueekPredict.OnlySelf.selector);
        engine.activate(6);
        vm.expectRevert(SqueekPredict.InvalidMarket.selector);
        engine.resolutionGrace(14);
    }

    // ---------- History-backed header proofs ----------

    function boundaryPair(uint256 number, uint256 end)
        internal
        pure
        returns (bytes memory p, bytes memory t)
    {
        p = Headers.make(bytes32(uint256(7)), number - 1, end - 1, 1 gwei);
        t = Headers.make(keccak256(p), number, end, 2 gwei);
    }

    function testBlockhashServesExactly256BlocksAndHistoryBeyond() public {
        GenerationHeaderReader reader = new GenerationHeaderReader();
        (bytes memory p, bytes memory t) = boundaryPair(5_000, 1_000);
        vm.roll(5_256);
        vm.setBlockhash(5_000, keccak256(t));
        assertEq(reader.boundary(p, t, 1_000).number, 5_000, "age 256 is served by BLOCKHASH");
        vm.roll(5_257);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(p, t, 1_000);
        vm.etch(0x0000F90827F1C53a10cb7A02335B175320002935, type(HonestHistory).runtimeCode);
        HonestHistory(0x0000F90827F1C53a10cb7A02335B175320002935).set(5_000, keccak256(t));
        assertEq(reader.boundary(p, t, 1_000).baseFee, 2 gwei);
        vm.roll(5_000 + 8_191);
        assertEq(reader.boundary(p, t, 1_000).number, 5_000);
        vm.roll(5_000 + 8_192);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(p, t, 1_000);
    }

    function testMalformedOrFailingHistoryAnswersAreNeverTrusted() public {
        GenerationHeaderReader reader = new GenerationHeaderReader();
        address history = 0x0000F90827F1C53a10cb7A02335B175320002935;
        (bytes memory p, bytes memory t) = boundaryPair(5_000, 1_000);
        vm.roll(6_000);
        vm.etch(history, type(LongAnswerHistory).runtimeCode);
        LongAnswerHistory(history).set(keccak256(t));
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(p, t, 1_000);
        vm.etch(history, type(RevertingHistory).runtimeCode);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(p, t, 1_000);
        // An all-zero answer cannot authenticate anything, including a header hashing to it.
        vm.etch(history, type(HonestHistory).runtimeCode);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(p, t, 1_000);
        // The current and future blocks are never provable, even when the history would answer.
        HonestHistory(history).set(6_000, keccak256(t));
        (bytes memory p2, bytes memory t2) = boundaryPair(6_000, 1_000);
        HonestHistory(history).set(6_000, keccak256(t2));
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(p2, t2, 1_000);
    }

    function testObservingNativeLaneSettlesThroughHistoryAndClearsItsSlot() public {
        place(alice, 10, 1, 1 ether);
        place(bob, 10, 0, 1 ether);
        SqueekPredict.Market memory m = engine.getMarket(10);
        vm.warp(m.closesAt);
        healthy(1);
        engine.maintain();
        assertEq(engine.observingMarketIds()[9], 10);
        uint256 successor = engine.activeMarketIds()[9];
        uint256 number = m.startBlock + m.strike + 1;
        bytes memory parent = Headers.make(bytes32(uint256(3)), number - 1, m.endsAt - 1, 1 gwei);
        bytes memory target = Headers.make(keccak256(parent), number, m.endsAt + 5, 1 gwei);
        vm.roll(number + 1_000);
        vm.warp(m.endsAt + engine.NATIVE_RESOLUTION_GRACE() - 1);
        vm.etch(0x0000F90827F1C53a10cb7A02335B175320002935, type(HonestHistory).runtimeCode);
        HonestHistory(0x0000F90827F1C53a10cb7A02335B175320002935).set(number, keccak256(target));
        engine.settleNative(10, parent, target);
        assertEq(engine.getMarket(10).result, m.strike + 1);
        assertEq(alice.balance, 1_000.98 ether);
        assertEq(engine.observingMarketIds()[9], 0);
        assertEq(engine.activeMarketIds()[9], successor);
        assertAccounting(0);
    }
}
