// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "./interfaces/ISqueekCore.sol";

/// @notice Immutable, permissionless reader of certified Core history, never an outcome reporter.
contract SqueekMetrics {
    enum Metric {
        Blocks,
        LongestRun,
        MorningEvening,
        Work,
        ActiveRounds
    }

    error InvalidCore();
    error UnsupportedConfiguration();
    error InvalidWindow();
    error NotCertified(uint64 requiredRound, uint64 certifiedRound);
    error InvalidPage();
    error CorePaused();
    error CoreStale(uint256 certifiedAt);

    ISqueekCore public immutable core;
    uint64 public constant ROUND_SECONDS = 600;
    uint256 public constant BLOCK_UNITS = 1_000_000_000;
    uint256 public constant MAX_REPORTING_DELAY = 6 hours;

    constructor(address core_) {
        if (core_ == address(0)) revert InvalidCore();
        core = ISqueekCore(core_);
    }

    /// @dev Align to full future Core rounds, leaving one full duration of betting time before the window:
    /// stakes are taken only before any round of the window can be certified. Daily markets use the next
    /// UTC day, aligned upwards.
    function window(uint64 now_, uint32 duration, bool daily)
        external
        view
        returns (uint64 startsAt, uint64 endsAt)
    {
        uint64 genesis = _genesis();
        _requireLive(genesis);
        if (now_ < genesis || duration == 0 || duration > 7 days || duration % ROUND_SECONDS != 0) {
            revert InvalidWindow();
        }
        uint64 candidate = daily ? (now_ / 1 days + 1) * uint64(1 days) : now_ + duration;
        startsAt = genesis + ((candidate - genesis + ROUND_SECONDS - 1) / ROUND_SECONDS) * ROUND_SECONDS;
        endsAt = startsAt + duration;
    }

    /// @notice Round index of a round-aligned timestamp under the Core's current genesis.
    function roundAt(uint64 timestamp) external view returns (uint64) {
        uint64 genesis = _genesis();
        if (timestamp < genesis || (timestamp - genesis) % ROUND_SECONDS != 0) revert InvalidWindow();
        return (timestamp - genesis) / ROUND_SECONDS;
    }

    /// @notice Do not accept new stakes against a paused or abandoned physical-data feed.
    /// Already-certified history remains resolvable even while reporting is paused.
    function requireLive() external view {
        _requireLive(_genesis());
    }

    function _requireLive(uint64 genesis) private view {
        ISqueekCore.CoreState memory s = core.state();
        if (s.paused) revert CorePaused();
        uint256 certifiedAt = uint256(genesis) + uint256(s.settledThroughRound) * ROUND_SECONDS;
        if (certifiedAt > block.timestamp || block.timestamp - certifiedAt > MAX_REPORTING_DELAY) {
            revert CoreStale(certifiedAt);
        }
    }

    /// @notice LongestRun means consecutive nonzero-work 10-minute rounds, in seconds.
    /// MorningEvening returns 1 iff work in 06:00–12:00 UTC exceeds 18:00–24:00 UTC.
    function measure(Metric metric, uint64 startsAt, uint64 endsAt) external view returns (uint256) {
        uint64 genesis = _genesis();
        if (
            startsAt < genesis || endsAt <= startsAt || endsAt - startsAt > 7 days
                || (startsAt - genesis) % ROUND_SECONDS != 0 || (endsAt - genesis) % ROUND_SECONDS != 0
        ) revert InvalidWindow();
        uint64 afterRound = (startsAt - genesis) / ROUND_SECONDS;
        uint64 throughRound = (endsAt - genesis) / ROUND_SECONDS;
        uint64 certified = core.state().settledThroughRound;
        if (certified < throughRound) revert NotCertified(throughRound, certified);
        ISqueekCore.RoundPage memory first = core.roundPage(afterRound, afterRound, 0);
        ISqueekCore.RoundPage memory last = core.roundPage(throughRound, throughRound, 0);
        if (first.certifiedThroughRound != afterRound || last.certifiedThroughRound != throughRound) {
            revert InvalidPage();
        }
        if (metric == Metric.Blocks) {
            return last.end.cumulativeBlockUnits / BLOCK_UNITS - first.end.cumulativeBlockUnits / BLOCK_UNITS;
        }
        if (metric == Metric.Work) return last.end.cumulativeWork - first.end.cumulativeWork;
        if (endsAt - startsAt != 1 days) revert InvalidWindow();

        uint64 cursor = afterRound;
        uint64 previousRound;
        uint256 previousWork = first.end.cumulativeWork;
        uint256 streak;
        uint256 longest;
        uint256 morning;
        uint256 evening;
        uint256 active;
        // 144 rounds, 16 records/page: at most nine full pages (a tenth is defensive).
        for (uint256 pageIndex; cursor < throughRound && pageIndex < 10; ++pageIndex) {
            ISqueekCore.RoundPage memory page = core.roundPage(cursor, throughRound, 16);
            if (
                page.certifiedThroughRound <= cursor || page.certifiedThroughRound > throughRound
                    || page.rounds.length > 16
            ) revert InvalidPage();
            uint64 lastInPage = cursor;
            for (uint256 i; i < page.rounds.length; ++i) {
                ISqueekCore.RoundCheckpoint memory r = page.rounds[i];
                if (
                    r.roundId <= lastInPage || r.roundId > page.certifiedThroughRound
                        || r.cumulativeWork <= previousWork
                ) revert InvalidPage();
                uint256 work = r.cumulativeWork - previousWork;
                streak = previousRound != 0 && r.roundId == previousRound + 1 ? streak + 1 : 1;
                if (streak > longest) longest = streak;
                uint256 secondOfDay = (genesis + (r.roundId - 1) * ROUND_SECONDS) % 1 days;
                if (secondOfDay >= 6 hours && secondOfDay < 12 hours) morning += work;
                if (secondOfDay >= 18 hours) evening += work;
                previousWork = r.cumulativeWork;
                previousRound = r.roundId;
                lastInPage = r.roundId;
                ++active;
            }
            cursor = page.certifiedThroughRound;
        }
        if (cursor != throughRound || previousWork != last.end.cumulativeWork) revert InvalidPage();
        if (metric == Metric.LongestRun) return longest * ROUND_SECONDS;
        if (metric == Metric.MorningEvening) return morning > evening ? 1 : 0;
        return active;
    }

    function _genesis() private view returns (uint64) {
        ISqueekCore.CoreConfiguration memory c = core.configuration();
        if (c.roundDuration != ROUND_SECONDS || c.blockUnitsPerBlock != BLOCK_UNITS) {
            revert UnsupportedConfiguration();
        }
        return c.genesisTimestamp;
    }
}
