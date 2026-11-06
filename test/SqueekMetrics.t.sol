// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekMetrics} from "../src/SqueekMetrics.sol";
import {MockCore} from "./mocks/MockCore.sol";

contract SqueekMetricsTest is Test {
    uint64 constant GENESIS = 1_728_000_000;
    MockCore core;
    SqueekMetrics metrics;

    function setUp() public {
        core = new MockCore(GENESIS);
        metrics = new SqueekMetrics(address(core));
        core.setFrontier(2000);
        vm.warp(GENESIS + 2000 * 600);
    }

    function testConstructorDoesNotCallDependency() public {
        SqueekMetrics isolated = new SqueekMetrics(makeAddr("no-code"));
        assertEq(address(isolated.core()).code.length, 0);
        vm.expectRevert(SqueekMetrics.InvalidCore.selector);
        new SqueekMetrics(address(0));
    }

    function testWindowsLeaveOneDurationOfBettingAndUseFullRoundsAndUtcDay() public {
        // Aligned call: the window starts exactly one duration later, on a round boundary.
        (uint64 a, uint64 b) = metrics.window(GENESIS + 600, 6 hours, false);
        assertEq(a, GENESIS + 600 + 6 hours);
        assertEq(b - a, 6 hours);
        // Unaligned call: rounded up to the next round boundary, never earlier than now + duration.
        (a, b) = metrics.window(GENESIS + 601, 6 hours, false);
        assertEq(a, GENESIS + 1200 + 6 hours);
        (a, b) = metrics.window(GENESIS + 1 hours, 1 days, true);
        assertEq(a % 1 days, 0);
        assertGt(a, GENESIS + 1 hours);
        assertEq(b - a, 1 days);
        assertEq(metrics.roundAt(GENESIS + 1200), 2);
        vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
        metrics.roundAt(GENESIS + 1201);
        vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
        metrics.roundAt(GENESIS - 600);
    }

    function testBlocksSubtractEndpointFloorsNotFloorOfDifference() public {
        core.add(1, 1, 900_000_000);
        core.add(2, 1, 200_000_000);
        assertEq(metrics.measure(SqueekMetrics.Metric.Blocks, GENESIS + 600, GENESIS + 1200), 1);
        assertEq(metrics.measure(SqueekMetrics.Metric.Work, GENESIS + 600, GENESIS + 1200), 1);
    }

    function testPaginatedRunSpansPagesAndZeroRoundBreaksStreak() public {
        for (uint64 i = 1; i <= 20; ++i) {
            core.add(i, 10, 1e9);
        }
        for (uint64 i = 22; i <= 46; ++i) {
            core.add(i, 10, 1e9);
        }
        assertEq(metrics.measure(SqueekMetrics.Metric.LongestRun, GENESIS, GENESIS + 1 days), 25 * 600);
        assertEq(metrics.measure(SqueekMetrics.Metric.ActiveRounds, GENESIS, GENESIS + 1 days), 45);
    }

    function testFullDay144RecordsAndSevenDayEndpoint() public {
        for (uint64 i = 1; i <= 144; ++i) {
            core.add(i, 10, 1e9);
        }
        assertEq(metrics.measure(SqueekMetrics.Metric.LongestRun, GENESIS, GENESIS + 1 days), 1 days);
        assertEq(metrics.measure(SqueekMetrics.Metric.ActiveRounds, GENESIS, GENESIS + 1 days), 144);
        core.add(1008, 100, 11e9);
        assertEq(metrics.measure(SqueekMetrics.Metric.Blocks, GENESIS, GENESIS + 7 days), 155);
    }

    function testMorningAndEveningUseUtcRoundStartAndTieIsNo() public {
        core.add(36, 1000, 1e9); // 05:50, outside morning.
        core.add(37, 20, 1e9); // 06:00.
        core.add(73, 1000, 1e9); // 12:00, outside morning.
        core.add(109, 20, 1e9); // 18:00.
        assertEq(metrics.measure(SqueekMetrics.Metric.MorningEvening, GENESIS, GENESIS + 1 days), 0);
    }

    function testMorningWins() public {
        core.add(37, 21, 1e9);
        core.add(109, 20, 1e9);
        assertEq(metrics.measure(SqueekMetrics.Metric.MorningEvening, GENESIS, GENESIS + 1 days), 1);
    }

    function testUncertifiedRoundsAreUnknownNotZero() public {
        core.setFrontier(143);
        vm.expectRevert(abi.encodeWithSelector(SqueekMetrics.NotCertified.selector, uint64(144), uint64(143)));
        metrics.measure(SqueekMetrics.Metric.Blocks, GENESIS, GENESIS + 1 days);
    }

    function testEmptyCertifiedDayIsZero() public view {
        assertEq(metrics.measure(SqueekMetrics.Metric.Blocks, GENESIS, GENESIS + 1 days), 0);
        assertEq(metrics.measure(SqueekMetrics.Metric.LongestRun, GENESIS, GENESIS + 1 days), 0);
        assertEq(metrics.measure(SqueekMetrics.Metric.ActiveRounds, GENESIS, GENESIS + 1 days), 0);
    }

    function testInvalidWindowsAndNonAdvancingPageRevert() public {
        vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
        metrics.measure(SqueekMetrics.Metric.Blocks, GENESIS + 1, GENESIS + 1 days);
        vm.expectRevert(SqueekMetrics.InvalidWindow.selector);
        metrics.measure(SqueekMetrics.Metric.LongestRun, GENESIS, GENESIS + 7 days);
        core.setStuckPage(true);
        vm.expectRevert(SqueekMetrics.InvalidPage.selector);
        metrics.measure(SqueekMetrics.Metric.LongestRun, GENESIS, GENESIS + 1 days);
    }

    function testFuzzEndpointFloor(uint96 beforeUnits, uint96 addedUnits) public {
        beforeUnits = uint96(bound(beforeUnits, 0, 1e25));
        addedUnits = uint96(bound(addedUnits, 0, 1e25));
        core.add(1, 1, beforeUnits);
        core.add(2, 1, addedUnits);
        assertEq(
            metrics.measure(SqueekMetrics.Metric.Blocks, GENESIS + 600, GENESIS + 1200),
            (uint256(beforeUnits) + addedUnits) / 1e9 - beforeUnits / 1e9
        );
    }
}
