// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SqueekPredict} from "src/SqueekPredict.sol";
import {SqueekMetrics} from "src/SqueekMetrics.sol";
import {MockCore} from "./mocks/MockCore.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {DeferredWallet, ForcedDonation} from "./helpers/IndependentSetup.sol";

/// @dev Actors have finite balances. Ghost deposits come from call inputs and
/// ghost payments from actual balance changes, never totalLiability/remaining.
contract SolvencyHandler is Test {
    struct Ledger {
        uint256 gross;
        uint256 fees;
        uint256 no;
        uint256 yes;
        uint256 paid;
        bool terminal;
        bool refund;
        uint8 winner;
        uint256 result;
        bytes32 terms;
    }

    uint64 internal constant GENESIS = 1_728_000_000;
    uint256 public constant INITIAL_ACTOR_BALANCE = 10_000 ether;
    uint256 public constant INITIAL_DONOR_BALANCE = 1_000 ether;
    SqueekPredict public immutable engine;
    MockCore internal immutable core;
    MockFeed internal immutable ethFeed;
    MockFeed internal immutable btcFeed;
    address[6] public actors;
    address payable public immutable recipient;
    uint80 internal round = (uint80(1) << 64) | 100;
    uint256[] public fundedIds;
    mapping(uint256 => Ledger) internal ledgers;
    mapping(uint256 => mapping(uint256 => uint256)) internal noStake;
    mapping(uint256 => mapping(uint256 => uint256)) internal yesStake;
    mapping(uint256 => mapping(uint256 => uint256)) internal received;
    uint256 public grossDeposited;
    uint256 public feesCharged;
    uint256 public paidOut;
    uint256 public donated;
    uint256 public betCalls;
    uint256 public settlementCalls;
    uint256 public refundCalls;
    uint256 public claimCalls;

    constructor(SqueekPredict engine_, MockCore core_, MockFeed eth_, MockFeed btc_) {
        engine = engine_;
        core = core_;
        ethFeed = eth_;
        btcFeed = btc_;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("stateful actor ", vm.toString(i)));
        }
        actors[4] = address(new DeferredWallet(engine));
        actors[5] = address(new DeferredWallet(engine));
        for (uint256 i; i < 6; ++i) {
            vm.deal(actors[i], INITIAL_ACTOR_BALANCE);
        }
        recipient = payable(makeAddr("stateful claim recipient"));
        vm.deal(recipient, 0);
    }

    // Four ETH/BTC lanes provide different durations and independent feeds.
    function bet(uint256 laneSeed, uint256 actorSeed, uint256 amountSeed, bool yes) public {
        uint8[4] memory lanes = [uint8(5), 6, 7, 12];
        uint256 id = engine.activeMarketIds()[lanes[laneSeed % 4]];
        SqueekPredict.Market memory m = engine.getMarket(id);
        if (m.status == SqueekPredict.Status.Scheduled) {
            refreshFeeds();
            engine.open(id);
            m = engine.getMarket(id);
        }
        if (m.status != SqueekPredict.Status.Open || vm.getBlockTimestamp() >= m.closesAt) return;
        uint256 who = actorSeed % 6;
        uint256 maximum = actors[who].balance;
        if (maximum > engine.MAX_BET()) maximum = engine.MAX_BET();
        if (maximum < engine.MIN_BET()) return;
        uint256 gross = bound(amountSeed, engine.MIN_BET(), maximum);
        uint256 oldFees = engine.retainedFees();
        uint256 oldBalance = address(engine).balance;
        vm.prank(actors[who]);
        engine.bet{value: gross}(id, yes ? 1 : 0);
        Ledger storage g = ledgers[id];
        if (g.gross == 0) fundedIds.push(id);
        uint256 fee = gross / 100;
        uint256 net = gross - fee;
        g.gross += gross;
        g.fees += fee;
        if (yes) {
            g.yes += net;
            yesStake[id][who] += net;
        } else {
            g.no += net;
            noStake[id][who] += net;
        }
        grossDeposited += gross;
        feesCharged += fee;
        ++betCalls;
        assertEq(address(engine).balance - oldBalance, gross);
        assertEq(engine.retainedFees() - oldFees, fee);
    }

    function advance(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 1, 3 days);
        vm.warp(vm.getBlockTimestamp() + delta);
        vm.roll(vm.getBlockNumber() + delta / 12 + 1);
        core.setFrontier(uint64((vm.getBlockTimestamp() - GENESIS) / 600));
        refreshFeeds();
    }

    function maintain() external {
        uint256 fees = engine.retainedFees();
        uint256 balance = address(engine).balance;
        engine.maintain();
        assertEq(engine.retainedFees(), fees);
        assertEq(address(engine).balance, balance);
    }

    /// @dev Explicitly reaches winning, losing, empty-winning-side and timeout states.
    /// Price rounds are append-only. Advancing past expiry before this action
    /// therefore selects a refund instead of fabricating historical observations.
    function finish(uint256 marketSeed, bool yesWins, bool timeout) public {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[marketSeed % fundedIds.length];
        Ledger storage g = ledgers[id];
        if (g.terminal) return;
        SqueekPredict.Market memory m = engine.getMarket(id);
        uint256[6] memory balances = actorBalances();
        if (timeout || vm.getBlockTimestamp() >= m.endsAt) {
            uint256 deadline = uint256(m.endsAt) + engine.RESOLUTION_GRACE();
            if (vm.getBlockTimestamp() < deadline) vm.warp(deadline);
            core.setFrontier(uint64((vm.getBlockTimestamp() - GENESIS) / 600));
            refreshFeeds();
            engine.expire(id);
            g.refund = true;
            g.result = 0;
            g.winner = 0;
            ++refundCalls;
        } else {
            vm.warp(m.endsAt + 1);
            core.setFrontier(uint64((vm.getBlockTimestamp() - GENESIS) / 600));
            MockFeed feed = m.templateId == 7 || m.templateId == 12 ? btcFeed : ethFeed;
            int256 answer = int256(m.strike) + (yesWins ? int256(1) : -int256(1));
            uint80 beforeRound = ++round;
            feed.put(beforeRound, answer, m.endsAt);
            feed.put(++round, answer, m.endsAt + 1);
            engine.settlePrice(id, beforeRound);
            g.winner = yesWins ? 1 : 0;
            g.result = uint256(answer);
            g.refund = (yesWins ? g.yes : g.no) == 0;
            ++settlementCalls;
        }
        g.terminal = true;
        SqueekPredict.Market memory finished = engine.getMarket(id);
        assertEq(
            uint8(finished.status),
            uint8(g.refund ? SqueekPredict.Status.Refunded : SqueekPredict.Status.Resolved)
        );
        assertEq(finished.result, g.result);
        assertEq(finished.winner, g.winner);
        g.terms = immutableTerms(finished);
        recordPushes(id, balances);
    }

    function pay(uint256 marketSeed, uint256 batchSeed) external {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[marketSeed % fundedIds.length];
        if (!ledgers[id].terminal) return;
        uint256[6] memory balances = actorBalances();
        uint256 beforeCursor = engine.getMarket(id).paymentCursor;
        uint256 batch = bound(batchSeed, 1, engine.MAX_PAY_BATCH());
        engine.pay(id, batch);
        uint256 afterCursor = engine.getMarket(id).paymentCursor;
        assertGe(afterCursor, beforeCursor);
        assertLe(afterCursor - beforeCursor, batch);
        recordPushes(id, balances);
    }

    function claim(uint256 marketSeed, uint256 actorSeed) public {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[marketSeed % fundedIds.length];
        uint256 who = actorSeed % 6;
        if (!ledgers[id].terminal || engine.claimable(id, actors[who]) == 0) return;
        uint256 preview = engine.claimable(id, actors[who]);
        uint256 beforeBalance = recipient.balance;
        vm.prank(actors[who]);
        engine.claim(id, recipient);
        uint256 actual = recipient.balance - beforeBalance;
        assertEq(actual, preview, "claim preview must equal ETH actually received");
        received[id][who] += actual;
        ledgers[id].paid += actual;
        paidOut += actual;
        ++claimCalls;
        assertTrue(engine.getPosition(id, actors[who]).paid);
        assertEq(engine.claimable(id, actors[who]), 0);
    }

    function toggleRecipient(uint256 actorSeed, bool rejecting) external {
        DeferredWallet(payable(actors[4 + actorSeed % 2])).setRejecting(rejecting);
    }

    function donate(uint256 seed) external {
        if (address(this).balance == 0) return;
        uint256 maximum = address(this).balance;
        if (maximum > 1 ether) maximum = 1 ether;
        uint256 value = bound(seed, 1, maximum);
        new ForcedDonation{value: value}(payable(address(engine)));
        donated += value;
    }

    /// @dev Invalid calls are asserted, not discarded with fail_on_revert=false.
    function invalidBet(uint256 marketSeed, uint256 actorSeed) external {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[marketSeed % fundedIds.length];
        bytes memory beforeMarket = abi.encode(engine.getMarket(id));
        uint256 beforeBalance = address(engine).balance;
        uint256 beforeFees = engine.retainedFees();
        vm.prank(actors[actorSeed % 6]);
        vm.expectRevert(SqueekPredict.InvalidSide.selector);
        engine.bet(id, 2);
        assertEq(abi.encode(engine.getMarket(id)), beforeMarket);
        assertEq(address(engine).balance, beforeBalance);
        assertEq(engine.retainedFees(), beforeFees);
    }

    function refreshFeeds() internal {
        ethFeed.put(++round, 2_000e8, vm.getBlockTimestamp());
        btcFeed.put(round, 60_000e8, vm.getBlockTimestamp());
    }

    function actorBalances() internal view returns (uint256[6] memory balances) {
        for (uint256 i; i < 6; ++i) {
            balances[i] = actors[i].balance;
        }
    }

    function recordPushes(uint256 id, uint256[6] memory beforeBalances) internal {
        for (uint256 i; i < 6; ++i) {
            uint256 delta = actors[i].balance - beforeBalances[i];
            received[id][i] += delta;
            ledgers[id].paid += delta;
            paidOut += delta;
        }
    }

    function immutableTerms(SqueekPredict.Market memory m) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                m.createdAt,
                m.startsAt,
                m.closesAt,
                m.endsAt,
                m.startBlock,
                m.startRound,
                m.templateId,
                m.status,
                m.winner,
                m.strike,
                m.noPool,
                m.yesPool,
                m.volume,
                m.result
            )
        );
    }

    function assertSolvency() external view {
        assertEq(engine.retainedFees(), feesCharged, "fees from independent bet ledger");
        assertEq(address(engine).balance + paidOut, grossDeposited + donated, "actual ETH conservation");
        assertEq(
            address(engine).balance,
            engine.totalLiability() + feesCharged + engine.retainedDust() + donated,
            "donations cannot hide an accounting shortfall"
        );
        uint256 sumRemaining;
        uint256 sumDust;
        for (uint256 j; j < fundedIds.length; ++j) {
            uint256 id = fundedIds[j];
            Ledger storage g = ledgers[id];
            SqueekPredict.Market memory m = engine.getMarket(id);
            assertEq(m.volume, g.gross);
            assertEq(m.noPool, g.no);
            assertEq(m.yesPool, g.yes);
            assertLe(g.paid, g.gross - g.fees, "no market spends another market's deposits");
            uint256 dust = g.gross - g.fees - g.paid - m.remaining;
            if (!g.terminal || m.eligibleRemaining != 0) assertEq(dust, 0);
            else assertLt(dust, 6, "less than one wei per eligible bettor");
            sumDust += dust;
            sumRemaining += m.remaining;
        }
        assertEq(sumRemaining, engine.totalLiability());
        assertEq(sumDust, engine.retainedDust());
        uint256 total = address(engine).balance + address(this).balance + recipient.balance;
        for (uint256 i; i < 6; ++i) {
            total += actors[i].balance;
        }
        assertEq(total, 6 * INITIAL_ACTOR_BALANCE + INITIAL_DONOR_BALANCE);
    }

    function assertEntitlements() external view {
        for (uint256 j; j < fundedIds.length; ++j) {
            uint256 id = fundedIds[j];
            Ledger storage g = ledgers[id];
            SqueekPredict.Market memory m = engine.getMarket(id);
            uint256 pending;
            uint256 pendingStake;
            uint256 participants;
            for (uint256 i; i < 6; ++i) {
                SqueekPredict.Position memory p = engine.getPosition(id, actors[i]);
                assertEq(p.noStake, noStake[id][i]);
                assertEq(p.yesStake, yesStake[id][i]);
                if (noStake[id][i] + yesStake[id][i] > 0) ++participants;
                uint256 preview = engine.claimable(id, actors[i]);
                uint256 paid = received[id][i];
                if (!g.terminal) {
                    assertEq(preview, 0);
                    assertEq(paid, 0);
                    assertFalse(p.paid);
                    continue;
                }
                uint256 stake = g.refund
                    ? noStake[id][i] + yesStake[id][i]
                    : g.winner == 1 ? yesStake[id][i] : noStake[id][i];
                if (g.refund) {
                    assertEq(paid + preview, stake, "refund returns exactly net stake");
                } else {
                    uint256 winningPool = g.winner == 1 ? g.yes : g.no;
                    uint256 entitlement = stake * (g.no + g.yes);
                    assertLe((paid + preview) * winningPool, entitlement);
                    assertGt((paid + preview + 1) * winningPool, entitlement);
                }
                if (p.paid) {
                    assertEq(preview, 0);
                    assertGt(paid, 0);
                } else {
                    assertEq(paid, 0, "failed pushes cannot consume entitlements");
                    pendingStake += stake;
                }
                pending += preview;
            }
            assertEq(engine.bettorCount(id), participants);
            assertLe(m.paymentCursor, participants);
            if (g.terminal) {
                assertEq(immutableTerms(m), g.terms, "finished market cannot be rewritten");
                assertEq(m.eligibleRemaining, pendingStake);
                assertLe(pending, m.remaining);
                if (pendingStake == 0) assertEq(m.remaining, 0);
                else assertLt(m.remaining - pending, 6);
            }
        }
    }

    /// @dev Run after each random sequence: all outstanding entitlements must
    /// remain recoverable, including every previously failed push.
    function drain() external {
        for (uint256 j; j < fundedIds.length; ++j) {
            finish(j, false, true);
            for (uint256 i; i < 6; ++i) {
                claim(j, i);
            }
        }
        assertEq(engine.totalLiability(), 0, "all bettors can exit");
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract StatefulSolvencyTest is StdInvariant, Test {
    SqueekPredict internal engine;
    SolvencyHandler internal handler;

    function setUp() public {
        uint64 genesis = 1_728_000_000;
        vm.warp(genesis + 1 days + 17);
        vm.roll(10_000);
        MockCore core = new MockCore(genesis);
        core.setFrontier(144);
        MockFeed eth = new MockFeed();
        MockFeed btc = new MockFeed();
        uint80 round = (uint80(1) << 64) | 100;
        eth.put(round, 2_000e8, block.timestamp);
        btc.put(round, 60_000e8, block.timestamp);
        engine = new SqueekPredict(address(new SqueekMetrics(address(core))), address(eth), address(btc));
        engine.maintain();
        handler = new SolvencyHandler(engine, core, eth, btc);
        vm.deal(address(handler), handler.INITIAL_DONOR_BALANCE());

        // Ensure every run begins with real resolved, deferred and open liabilities.
        for (uint256 i; i < 6; ++i) {
            handler.bet(0, i, (i + 1) * 0.01 ether, true);
        }
        handler.bet(0, 0, 0.1 ether, false);
        handler.finish(0, true, false);
        handler.claim(0, 4);
        handler.maintain();
        handler.bet(0, 0, 0.01 ether, false);
        handler.bet(2, 5, 0.02 ether, true);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.bet.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.maintain.selector;
        selectors[3] = handler.finish.selector;
        selectors[4] = handler.pay.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.toggleRecipient.selector;
        selectors[7] = handler.donate.selector;
        selectors[8] = handler.invalidBet.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantIndependentLedgerAndClosedSystemConserveEther() public view {
        handler.assertSolvency();
    }

    function invariantPayoutRightsAndTerminalMarketsCannotChange() public view {
        handler.assertEntitlements();
    }

    function invariantCurrentSlotsRemainUniqueAndKeepTheirTemplates() public view {
        uint256[14] memory ids = engine.activeMarketIds();
        for (uint256 i; i < 14; ++i) {
            SqueekPredict.Market memory m = engine.getMarket(ids[i]);
            assertEq(m.templateId, i);
            assertTrue(m.status == SqueekPredict.Status.Open || m.status == SqueekPredict.Status.Scheduled);
            for (uint256 j = i + 1; j < 14; ++j) {
                assertTrue(ids[i] != ids[j]);
            }
        }
    }

    /// @dev An observing generation is always the lane's older, still-Open market, and the bettable
    /// successor can never close before it ends, so one observing slot per lane suffices.
    function invariantObservingGenerationsAreOlderOpenAndNeverOverlapTheirSuccessor() public view {
        uint256[14] memory active = engine.activeMarketIds();
        uint256[14] memory observing = engine.observingMarketIds();
        for (uint256 i; i < 14; ++i) {
            if (observing[i] == 0) continue;
            SqueekPredict.Market memory o = engine.getMarket(observing[i]);
            assertEq(o.templateId, i);
            assertEq(uint8(o.status), uint8(SqueekPredict.Status.Open));
            assertLt(observing[i], active[i]);
            SqueekPredict.Market memory a = engine.getMarket(active[i]);
            if (a.status == SqueekPredict.Status.Open) assertGe(a.closesAt, o.endsAt);
        }
    }

    /// @dev No live market is ever orphaned: each Scheduled or Open market is its lane's bettable
    /// or observing generation, so maintenance can always retire it.
    function assertNoOrphanedLiveMarket() internal view {
        uint256[14] memory active = engine.activeMarketIds();
        uint256[14] memory observing = engine.observingMarketIds();
        for (uint256 id = 1; id < engine.nextMarketId(); ++id) {
            SqueekPredict.Market memory m = engine.getMarket(id);
            if (m.status == SqueekPredict.Status.Scheduled || m.status == SqueekPredict.Status.Open) {
                assertTrue(
                    active[m.templateId] == id || observing[m.templateId] == id, "orphaned live market"
                );
            }
        }
    }

    function afterInvariant() public {
        assertNoOrphanedLiveMarket();
        assertGe(handler.betCalls(), 9);
        assertGe(handler.settlementCalls(), 1);
        assertGe(handler.claimCalls(), 1);
        handler.drain();
        handler.assertSolvency();
        handler.assertEntitlements();
    }
}
