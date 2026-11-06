// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "../../src/interfaces/ISqueekCore.sol";

contract MockCore is ISqueekCore {
    uint64 public genesis;
    uint64 public frontier;
    bool public broken;
    bool public stuckPage;
    bool public paused;
    RoundCheckpoint[] private records;

    constructor(uint64 genesis_) {
        genesis = genesis_;
    }

    function setFrontier(uint64 f) external {
        frontier = f;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setStuckPage(bool b) external {
        stuckPage = b;
    }

    function setPaused(bool b) external {
        paused = b;
    }

    function add(uint64 round, uint64 work, uint96 units) external {
        LedgerPosition memory previous = _point(type(uint64).max);
        require(records.length == 0 || records[records.length - 1].roundId < round, "order");
        records.push(
            RoundCheckpoint(
                round,
                previous.cumulativeWork + work,
                previous.cumulativeBlockUnits + units,
                10_000,
                bytes32(uint256(round))
            )
        );
    }

    function configuration() external view returns (CoreConfiguration memory c) {
        require(!broken, "core unavailable");
        c.genesisTimestamp = genesis;
        c.roundDuration = 600;
        c.blockUnitsPerBlock = 1_000_000_000;
        c.maxRoundsPerBatch = 16;
    }

    function state() external view returns (CoreState memory s) {
        require(!broken, "core unavailable");
        LedgerPosition memory p = _point(frontier);
        s.settledThroughRound = frontier;
        s.cumulativeWork = p.cumulativeWork;
        s.cumulativeBlockUnits = p.cumulativeBlockUnits;
        s.blockHeight = uint64(p.cumulativeBlockUnits / 1e9);
        s.paused = paused;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory page)
    {
        require(!broken, "core unavailable");
        require(afterRound <= throughRound && throughRound <= frontier && maxRecords <= 16, "bounds");
        page.start = _point(afterRound);
        page.certifiedThroughRound = throughRound;
        uint256 count;
        for (uint256 i; i < records.length; ++i) {
            if (records[i].roundId <= afterRound) continue;
            if (records[i].roundId > throughRound) break;
            if (count == maxRecords) {
                page.certifiedThroughRound = records[i].roundId - 1;
                break;
            }
            ++count;
        }
        page.rounds = new RoundCheckpoint[](count);
        uint256 cursor;
        for (uint256 i; i < records.length && cursor < count; ++i) {
            if (records[i].roundId > afterRound && records[i].roundId <= throughRound) {
                page.rounds[cursor++] = records[i];
            }
        }
        if (stuckPage && throughRound > afterRound) page.certifiedThroughRound = afterRound;
        page.end = _point(page.certifiedThroughRound);
    }

    function _point(uint64 round) private view returns (LedgerPosition memory p) {
        for (uint256 i; i < records.length; ++i) {
            if (records[i].roundId > round) break;
            p = LedgerPosition(
                records[i].cumulativeWork, records[i].cumulativeBlockUnits, records[i].workPerThousandBlocks
            );
        }
    }
}
