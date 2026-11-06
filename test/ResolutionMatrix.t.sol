// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IndependentSetup} from "./helpers/IndependentSetup.sol";
import {SqueekPredict} from "src/SqueekPredict.sol";
import {Headers} from "./helpers/Headers.sol";

contract ResolutionMatrixTest is IndependentSetup {
    function fundBothSides(uint256 id) internal {
        place(alice, id, 0, 1 ether);
        place(bob, id, 1, 1 ether);
    }

    function assertResolved(uint256 id, uint256 expected, bool over) internal view {
        SqueekPredict.Market memory m = engine.getMarket(id);
        assertEq(m.result, expected);
        assertEq(m.winner, over ? 1 : 0);
        assertEq(uint8(m.status), uint8(SqueekPredict.Status.Resolved));
        assertEq(over ? bob.balance : alice.balance, 1_000.98 ether);
        assertEq(over ? alice.balance : bob.balance, 999 ether);
        assertEq(engine.getMarket(engine.activeMarketIds()[m.templateId]).templateId, m.templateId);
        assertEq(engine.totalLiability(), 0);
        assertAccounting(0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzAllSqueekResolutionRoutesAtStrikeAndOneUnitOver(uint8 slotSeed, bool over) public {
        uint256[7] memory ids = [uint256(1), 2, 3, 4, 5, 11, 12];
        uint256 id = ids[slotSeed % 7];
        fundBothSides(id);
        SqueekPredict.Market memory m = engine.getMarket(id);
        uint64 afterRound = (m.startsAt - GENESIS) / 600;
        uint64 throughRound = (m.endsAt - GENESIS) / 600;
        uint256 expected;
        if (m.templateId <= 2) {
            expected = m.strike + (over ? 1 : 0);
            core.add(afterRound, 1, 900_000_000);
            core.add(throughRound, 10, uint96(expected * 1e9));
        } else if (m.templateId == 3) {
            uint64 count = over ? 4 : 3;
            for (uint64 i = 1; i <= count; ++i) {
                core.add(afterRound + i, 1, 1e9);
            }
            expected = count * 600;
        } else if (m.templateId == 4) {
            core.add(afterRound + 37, 10, 1e9); // 06:00 UTC.
            core.add(afterRound + 109, over ? 9 : 10, 1e9); // 18:00 UTC.
            expected = over ? 1 : 0;
        } else if (m.templateId == 10) {
            expected = over ? 5001 : 5000;
            core.add(afterRound + 1, uint64(expected), 1e9);
        } else {
            uint64 count = over ? 25 : 24;
            for (uint64 i; i < count; ++i) {
                core.add(afterRound + i * 2 + 1, 1, 1e9);
            }
            expected = count;
        }
        core.setFrontier(throughRound);
        vm.warp(m.endsAt - 1);
        vm.expectRevert(SqueekPredict.NotEnded.selector);
        engine.settleSqueek(id);
        vm.warp(m.endsAt);
        engine.settleSqueek(id);
        assertResolved(id, expected, over);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzAllNativeResolutionRoutesAtStrikeAndOneUnitOver(uint8 slotSeed, bool over) public {
        uint256[3] memory ids = [uint256(9), 10, 14];
        uint256 id = ids[slotSeed % 3];
        fundBothSides(id);
        SqueekPredict.Market memory m = engine.getMarket(id);
        uint256 value = m.strike + (over ? 1 : 0);
        uint256 targetNumber = m.templateId == 8 ? m.startBlock + 7000 : m.startBlock + value;
        uint256 fee = m.templateId == 8 ? value : 10 gwei;
        bytes memory parent = Headers.make(bytes32(uint256(1)), targetNumber - 1, m.endsAt - 1, fee);
        bytes memory target = Headers.make(keccak256(parent), targetNumber, m.endsAt, fee);
        vm.roll(targetNumber + 1);
        vm.warp(m.endsAt + 1);
        vm.setBlockhash(targetNumber, keccak256(target));
        engine.settleNative(id, parent, target);
        assertResolved(id, value, over);
    }

    function testAllMarketDurationsAndOutcomeKindsAreFixed() public view {
        uint32[14] memory durations = [
            uint32(6 hours),
            1 days,
            7 days,
            1 days,
            1 days,
            1 days,
            7 days,
            1 days,
            1 days,
            1 days,
            1 days,
            1 days,
            7 days,
            6 hours
        ];
        uint8[14] memory kinds = [uint8(0), 0, 0, 1, 2, 3, 3, 4, 5, 6, 7, 8, 4, 6];
        for (uint8 i; i < 14; ++i) {
            (SqueekPredict.Kind kind, uint32 duration,) = engine.marketTemplate(i);
            assertEq(uint8(kind), kinds[i]);
            assertEq(duration, durations[i]);
            SqueekPredict.Market memory m = engine.getMarket(i + 1);
            assertEq(m.endsAt - m.startsAt, duration);
        }
    }
}
