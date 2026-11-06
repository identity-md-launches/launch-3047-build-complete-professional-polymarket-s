// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekMetrics} from "src/SqueekMetrics.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";
import {MockCore} from "./mocks/MockCore.sol";

/// forge-config: default.fuzz.runs = 256
contract MetricsPropertiesTest is Test {
    uint64 internal constant GENESIS = 1_728_000_000;
    MockCore internal core;
    SqueekMetrics internal metrics;

    function setUp() public {
        core = new MockCore(GENESIS);
        metrics = new SqueekMetrics(address(core));
        core.setFrontier(144);
        vm.warp(GENESIS + 1 days);
    }

    function testLivenessAcceptsExactSixHoursAndRejectsFutureCertification() public {
        vm.warp(GENESIS + 1 days + 6 hours);
        metrics.requireLive();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(abi.encodeWithSelector(SqueekMetrics.CoreStale.selector, GENESIS + uint256(1 days)));
        metrics.requireLive();
        core.setFrontier(181);
        vm.expectRevert(
            abi.encodeWithSelector(SqueekMetrics.CoreStale.selector, GENESIS + uint256(181 * 600))
        );
        metrics.requireLive();
    }

    function testUnsupportedRoundDurationOrBlockUnitScalingFailsClosed() public {
        ISqueekCore.CoreConfiguration memory config = core.configuration();
        config.roundDuration = 599;
        vm.mockCall(address(core), abi.encodeCall(core.configuration, ()), abi.encode(config));
        vm.expectRevert(SqueekMetrics.UnsupportedConfiguration.selector);
        metrics.window(GENESIS + 1 days, 1 days, false);
        vm.expectRevert(SqueekMetrics.UnsupportedConfiguration.selector);
        metrics.measure(SqueekMetrics.Metric.Blocks, GENESIS, GENESIS + 1 days);
        config.roundDuration = 600;
        config.blockUnitsPerBlock = 1e9 + 1;
        vm.mockCall(address(core), abi.encodeCall(core.configuration, ()), abi.encode(config));
        vm.expectRevert(SqueekMetrics.UnsupportedConfiguration.selector);
        metrics.requireLive();
    }

    function testInvalidWindowDurationsAndEndpoints() public {
        uint32[4] memory durations = [uint32(0), 599, 601, uint32(7 days + 600)];
        for (uint256 i; i < durations.length; ++i) {
            vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
            metrics.window(GENESIS + 1 days, durations[i], false);
        }
        vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
        metrics.window(GENESIS - 1, 600, false);
        uint64[6] memory starts = [GENESIS - 600, GENESIS, GENESIS + 600, GENESIS + 1, GENESIS, GENESIS];
        uint64[6] memory ends =
            [GENESIS, GENESIS, GENESIS, GENESIS + 600, GENESIS + 601, GENESIS + 7 days + 600];
        for (uint256 i; i < starts.length; ++i) {
            vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
            metrics.measure(SqueekMetrics.Metric.Blocks, starts[i], ends[i]);
        }
        vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
        metrics.measure(SqueekMetrics.Metric.ActiveRounds, GENESIS, GENESIS + 600);
        vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
        metrics.measure(SqueekMetrics.Metric.MorningEvening, GENESIS, GENESIS + 600);
    }

    function testFuzzWindowAlignmentWithNonUtcGenesis(
        uint16 offsetSeed,
        uint32 elapsedSeed,
        uint16 roundsSeed,
        bool daily
    ) public {
        uint64 genesis = GENESIS + uint64(bound(offsetSeed, 0, 599));
        uint64 now_ = genesis + uint64(bound(elapsedSeed, 0, 365 days));
        MockCore shifted = new MockCore(genesis);
        shifted.setFrontier((now_ - genesis) / 600);
        SqueekMetrics reader = new SqueekMetrics(address(shifted));
        vm.warp(now_);
        uint32 duration = uint32(bound(roundsSeed, 1, 1008) * 600);
        (uint64 starts, uint64 ends) = reader.window(now_, duration, daily);
        assertGt(starts, now_);
        assertEq((starts - genesis) % 600, 0);
        assertEq(ends - starts, duration);
        // Non-daily windows leave one full duration of betting time before the first round.
        uint256 candidate = daily ? (uint256(now_) / 1 days + 1) * 1 days : uint256(now_) + duration;
        assertGe(starts, candidate);
        assertLt(starts, candidate + 600);
    }

    function testFuzzSparsePaginationAgainstDenseDailyModel(
        uint256 activeMask,
        uint16 scaleSeed,
        uint8 offsetSeed
    ) public {
        uint64 offset = uint64(bound(offsetSeed, 0, 144));
        uint64 scale = uint64(bound(scaleSeed, 1, 100));
        core.setFrontier(offset + 144);
        vm.warp(GENESIS + (offset + 144) * 600);
        // Nonzero history before the window catches accidental baseline inclusion.
        if (offset != 0) core.add(offset, 777, 900_000_000);
        uint256 expectedWork;
        uint256 expectedActive;
        uint256 expectedLongest;
        uint256 run;
        uint256 morning;
        uint256 evening;
        for (uint64 i; i < 144; ++i) {
            uint64 work = (activeMask >> i) & 1 == 0 ? 0 : (i % 7 + 1) * scale;
            // Dense oracle: every round, including idle rounds, is represented.
            if (work == 0) {
                run = 0;
            } else {
                ++run;
                ++expectedActive;
                expectedWork += work;
                if (run > expectedLongest) expectedLongest = run;
                uint256 utcHour = ((uint256(offset) + i) * 600 % 1 days) / 1 hours;
                if (utcHour >= 6 && utcHour < 12) morning += work;
                if (utcHour >= 18) evening += work;
                // The Core exposes only active checkpoints, in 16-record pages.
                core.add(offset + i + 1, work, 1e9);
            }
        }
        uint64 start = GENESIS + offset * 600;
        uint64 end = start + 1 days;
        assertEq(metrics.measure(SqueekMetrics.Metric.Work, start, end), expectedWork);
        assertEq(metrics.measure(SqueekMetrics.Metric.Blocks, start, end), expectedActive);
        assertEq(metrics.measure(SqueekMetrics.Metric.ActiveRounds, start, end), expectedActive);
        assertEq(metrics.measure(SqueekMetrics.Metric.LongestRun, start, end), expectedLongest * 600);
        assertEq(metrics.measure(SqueekMetrics.Metric.MorningEvening, start, end), morning > evening ? 1 : 0);
    }

    function testFuzzEndpointMetricsAreAdditiveAcrossAdjacentWindows(uint96 a, uint96 b, uint96 c) public {
        a = uint96(bound(a, 0, 1e25));
        b = uint96(bound(b, 0, 1e25));
        c = uint96(bound(c, 0, 1e25));
        core.add(1, 17, a);
        core.add(2, 23, b);
        core.add(3, 31, c);
        for (uint256 i; i < 2; ++i) {
            SqueekMetrics.Metric metric = i == 0 ? SqueekMetrics.Metric.Blocks : SqueekMetrics.Metric.Work;
            uint256 whole = metrics.measure(metric, GENESIS, GENESIS + 1800);
            uint256 first = metrics.measure(metric, GENESIS, GENESIS + 600);
            uint256 rest = metrics.measure(metric, GENESIS + 600, GENESIS + 1800);
            assertEq(whole, first + rest, "adjacent endpoint deltas must telescope");
        }
    }

    function testHistoricalResultCannotBeChangedByLaterRounds() public {
        core.add(1, 1, 1e9);
        core.add(37, 10, 1e9);
        core.add(109, 1, 1e9);
        uint256[5] memory beforeResult;
        for (uint8 i; i < 5; ++i) {
            beforeResult[i] = metrics.measure(SqueekMetrics.Metric(i), GENESIS, GENESIS + 1 days);
        }
        core.add(145, 10_000, 10_000e9);
        core.setFrontier(145);
        vm.warp(GENESIS + 145 * 600);
        for (uint8 i; i < 5; ++i) {
            assertEq(metrics.measure(SqueekMetrics.Metric(i), GENESIS, GENESIS + 1 days), beforeResult[i]);
        }
    }

    function testInvalidEndpointCertificationIsRejected() public {
        ISqueekCore.RoundPage memory page = core.roundPage(144, 144, 0);
        page.certifiedThroughRound = 143;
        vm.mockCall(
            address(core), abi.encodeCall(core.roundPage, (uint64(144), uint64(144), 0)), abi.encode(page)
        );
        vm.expectRevert(SqueekMetrics.InvalidPage.selector);
        metrics.measure(SqueekMetrics.Metric.Blocks, GENESIS, GENESIS + 1 days);
    }

    function testFuzzMalformedActivityPageNeverProducesAnOutcome(uint8 mutation) public {
        core.add(1, 10, 1e9);
        core.add(2, 10, 1e9);
        ISqueekCore.RoundPage memory page = core.roundPage(0, 144, 16);
        uint8 choice = mutation % 8;
        if (choice == 0) page.certifiedThroughRound = 0;
        else if (choice == 1) page.certifiedThroughRound = 145;
        else if (choice == 2) page.rounds = new ISqueekCore.RoundCheckpoint[](17);
        else if (choice == 3) page.rounds[0].roundId = 0;
        else if (choice == 4) page.rounds[1].roundId = page.rounds[0].roundId;
        else if (choice == 5) page.rounds[1].roundId = 145;
        else if (choice == 6) page.rounds[1].cumulativeWork = page.rounds[0].cumulativeWork;
        else page.rounds[1].cumulativeWork = 21; // Disagrees with the certified endpoint's 20.
        vm.mockCall(
            address(core), abi.encodeCall(core.roundPage, (uint64(0), uint64(144), 16)), abi.encode(page)
        );
        vm.expectRevert(SqueekMetrics.InvalidPage.selector);
        metrics.measure(SqueekMetrics.Metric.ActiveRounds, GENESIS, GENESIS + 1 days);
    }

    function testPartialPagesMustReachEndWithinBoundedNumberOfCalls() public {
        for (uint64 i; i < 10; ++i) {
            ISqueekCore.RoundPage memory page;
            page.certifiedThroughRound = i + 1;
            page.rounds = new ISqueekCore.RoundCheckpoint[](0);
            vm.mockCall(address(core), abi.encodeCall(core.roundPage, (i, uint64(144), 16)), abi.encode(page));
        }
        vm.expectRevert(SqueekMetrics.InvalidPage.selector);
        metrics.measure(SqueekMetrics.Metric.LongestRun, GENESIS, GENESIS + 1 days);
    }
}
