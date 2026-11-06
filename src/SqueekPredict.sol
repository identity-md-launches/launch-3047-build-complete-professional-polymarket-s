// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {SqueekMetrics} from "./SqueekMetrics.sol";
import {BlockHeader} from "./libraries/BlockHeader.sol";

/// @notice Fourteen fixed recurring prediction lanes, funded solely by native-ETH bets.
/// @dev Immutable dependencies, no owner, no arbitrary markets, no fee withdrawal and no upgrades.
contract SqueekPredict {
    enum Kind {
        SqueekBlocks,
        LongestRun,
        MorningEvening,
        EthPrice,
        BtcPrice,
        BaseFee,
        EthBlocks,
        SqueekWork,
        ActiveRounds
    }
    enum Status {
        Scheduled,
        Open,
        Awaiting,
        Resolved,
        Refunded
    }

    struct Market {
        uint64 createdAt;
        uint64 startsAt;
        uint64 closesAt;
        uint64 endsAt;
        uint64 startBlock;
        uint80 startRound;
        uint8 templateId;
        Status status;
        uint8 winner;
        uint256 strike;
        uint128 noPool;
        uint128 yesPool;
        uint128 volume;
        uint256 result;
        uint256 remaining;
        uint256 eligibleRemaining;
        uint256 paymentCursor;
    }

    struct Position {
        uint128 noStake;
        uint128 yesStake;
        bool paid;
    }

    error InvalidDependency();
    error InvalidMarket();
    error InvalidSide();
    error InvalidAmount();
    error BettingClosed();
    error InvalidStatus();
    error NotEnded();
    error ResolutionExpired();
    error TimeoutNotReached();
    error WrongKind();
    error InvalidPrice();
    error StalePrice();
    error InvalidPriceBoundary();
    error NothingToClaim();
    error TransferFailed();
    error InvalidRecipient();
    error InvalidBatch();
    error ReentrantCall();
    error OnlySelf();

    event MarketScheduled(uint256 indexed marketId, uint8 indexed templateId);
    event MarketOpened(
        uint256 indexed marketId, uint64 startsAt, uint64 closesAt, uint64 endsAt, uint256 strike
    );
    event ActivationDeferred(uint256 indexed marketId);
    event MarketAwaiting(uint256 indexed marketId, uint256 indexed replacementId);
    event BetPlaced(
        uint256 indexed marketId, address indexed bettor, uint8 side, uint256 gross, uint256 net, uint256 fee
    );
    event MarketResolved(uint256 indexed marketId, uint8 winner, uint256 result, bool refunded);
    event Paid(uint256 indexed marketId, address indexed bettor, address indexed recipient, uint256 amount);
    event PaymentDeferred(uint256 indexed marketId, address indexed bettor, uint256 amount);
    event DustRetained(uint256 indexed marketId, uint256 amount);

    uint8 public constant SLOT_COUNT = 14;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant MIN_BET = 0.001 ether;
    uint256 public constant MAX_BET = 100 ether;
    uint256 public constant MAX_POOL = 1_000_000 ether;
    uint256 public constant MAX_PRICE_AGE = 2 hours;
    uint256 public constant RESOLUTION_GRACE = 2 days;
    uint256 public constant AUTO_PAY_BATCH = 20;
    uint256 public constant MAX_PAY_BATCH = 40;
    uint256 public constant PUSH_GAS = 35_000;

    SqueekMetrics public immutable metrics;
    IAggregatorV3 public immutable ethFeed;
    IAggregatorV3 public immutable btcFeed;
    uint256 public nextMarketId = 1;
    uint256 public retainedFees;
    uint256 public retainedDust;
    uint256 public totalLiability;
    uint256 private entered;
    uint256[14] private activeIds;
    mapping(uint256 => Market) private markets;
    mapping(uint256 => mapping(address => Position)) private positions;
    mapping(uint256 => address[]) private bettors;
    mapping(address => uint256[]) private userMarkets;

    modifier nonReentrant() {
        if (entered != 0) revert ReentrantCall();
        entered = 1;
        _;
        entered = 0;
    }

    /// @dev No dependency calls or ETH required during factory construction.
    constructor(address metrics_, address ethFeed_, address btcFeed_) {
        if (metrics_ == address(0) || ethFeed_ == address(0) || btcFeed_ == address(0)) {
            revert InvalidDependency();
        }
        metrics = SqueekMetrics(metrics_);
        ethFeed = IAggregatorV3(ethFeed_);
        btcFeed = IAggregatorV3(btcFeed_);
        for (uint8 i; i < SLOT_COUNT; ++i) {
            _schedule(i);
        }
    }

    function marketTemplate(uint8 slot) public pure returns (Kind kind, uint32 duration, uint256 strike) {
        if (slot == 0) return (Kind.SqueekBlocks, 6 hours, 100);
        if (slot == 1) return (Kind.SqueekBlocks, 1 days, 400);
        if (slot == 2) return (Kind.SqueekBlocks, 7 days, 2800);
        if (slot == 3) return (Kind.LongestRun, 1 days, 30 minutes);
        if (slot == 4) return (Kind.MorningEvening, 1 days, 0);
        if (slot == 5) return (Kind.EthPrice, 1 days, 0);
        if (slot == 6) return (Kind.EthPrice, 7 days, 0);
        if (slot == 7) return (Kind.BtcPrice, 1 days, 0);
        if (slot == 8) return (Kind.BaseFee, 1 days, 0);
        if (slot == 9) return (Kind.EthBlocks, 1 days, 7000);
        if (slot == 10) return (Kind.SqueekWork, 1 days, 5000);
        if (slot == 11) return (Kind.ActiveRounds, 1 days, 24);
        if (slot == 12) return (Kind.BtcPrice, 7 days, 0);
        if (slot == 13) return (Kind.EthBlocks, 6 hours, 1750);
        revert InvalidMarket();
    }

    function activeMarketIds() external view returns (uint256[14] memory) {
        return activeIds;
    }

    function getMarket(uint256 id) public view returns (Market memory) {
        _exists(id);
        return markets[id];
    }

    function getPosition(uint256 id, address user) external view returns (Position memory) {
        _exists(id);
        return positions[id][user];
    }

    function bettorCount(uint256 id) external view returns (uint256) {
        _exists(id);
        return bettors[id].length;
    }

    function userMarketCount(address user) external view returns (uint256) {
        return userMarkets[user].length;
    }

    function positionIds(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids)
    {
        if (limit > 100) revert InvalidBatch();
        uint256 count = userMarkets[user].length;
        if (offset >= count) return new uint256[](0);
        uint256 n = count - offset;
        if (n > limit) n = limit;
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = userMarkets[user][count - 1 - offset - i];
        }
    }

    function getMarkets(uint256[] calldata ids) external view returns (Market[] memory result) {
        if (ids.length > 100) revert InvalidBatch();
        result = new Market[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            result[i] = getMarket(ids[i]);
        }
    }

    /// @notice Pool shares, not fixed payout promises. An empty pool begins at 50/50.
    function odds(uint256 id) external view returns (uint256 noBps, uint256 yesBps) {
        _exists(id);
        Market storage m = markets[id];
        uint256 total = uint256(m.noPool) + m.yesPool;
        if (total == 0) return (5000, 5000);
        yesBps = uint256(m.yesPool) * 10_000 / total;
        return (10_000 - yesBps, yesBps);
    }

    function open(uint256 id) external nonReentrant {
        _open(id);
    }

    /// @dev Self-only isolation lets a bad oracle leave its lane scheduled without stopping others.
    function activate(uint256 id) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _open(id);
    }

    function maintain() external nonReentrant {
        _maintain();
    }

    function performUpkeep(bytes calldata) external nonReentrant {
        _maintain();
    }

    function checkUpkeep(bytes calldata) external view returns (bool needed, bytes memory data) {
        for (uint8 i; i < SLOT_COUNT; ++i) {
            Market storage m = markets[activeIds[i]];
            if (m.status == Status.Scheduled || (m.status == Status.Open && block.timestamp >= m.endsAt)) {
                return (true, bytes(""));
            }
        }
        return (false, bytes(""));
    }

    function bet(uint256 id, uint8 side) external payable nonReentrant {
        _exists(id);
        if (side > 1) revert InvalidSide();
        if (msg.value < MIN_BET || msg.value > MAX_BET) revert InvalidAmount();
        Market storage m = markets[id];
        if (m.status == Status.Scheduled) _open(id);
        if (m.status != Status.Open || block.timestamp >= m.closesAt) revert BettingClosed();
        (Kind kind,,) = marketTemplate(m.templateId);
        if (_isSqueek(kind)) metrics.requireLive();
        uint256 fee = msg.value / 100;
        uint256 net = msg.value - fee;
        if (uint256(m.noPool) + m.yesPool + net > MAX_POOL) revert InvalidAmount();
        Position storage p = positions[id][msg.sender];
        if (p.noStake == 0 && p.yesStake == 0) {
            bettors[id].push(msg.sender);
            userMarkets[msg.sender].push(id);
        }
        if (side == 0) {
            p.noStake += uint128(net);
            m.noPool += uint128(net);
        } else {
            p.yesStake += uint128(net);
            m.yesPool += uint128(net);
        }
        m.remaining += net;
        m.volume += uint128(msg.value);
        retainedFees += fee;
        totalLiability += net;
        emit BetPlaced(id, msg.sender, side, msg.value, net, fee);
    }

    function settleSqueek(uint256 id) external nonReentrant {
        _beginResolution(id, false);
        Market storage m = markets[id];
        (Kind kind,,) = marketTemplate(m.templateId);
        SqueekMetrics.Metric metric;
        if (kind == Kind.SqueekBlocks) metric = SqueekMetrics.Metric.Blocks;
        else if (kind == Kind.LongestRun) metric = SqueekMetrics.Metric.LongestRun;
        else if (kind == Kind.MorningEvening) metric = SqueekMetrics.Metric.MorningEvening;
        else if (kind == Kind.SqueekWork) metric = SqueekMetrics.Metric.Work;
        else if (kind == Kind.ActiveRounds) metric = SqueekMetrics.Metric.ActiveRounds;
        else revert WrongKind();
        uint256 value = metrics.measure(metric, m.startsAt, m.endsAt);
        _finish(id, value, false);
    }

    /// @notice Prove the last feed observation at/before expiry using its immediate successor.
    /// Phase changes and missing round IDs fail closed and can refund after the fixed timeout.
    function settlePrice(uint256 id, uint80 beforeRound) external nonReentrant {
        _beginResolution(id, false);
        Market storage m = markets[id];
        (Kind kind,,) = marketTemplate(m.templateId);
        if (kind != Kind.EthPrice && kind != Kind.BtcPrice) revert WrongKind();
        IAggregatorV3 feed = kind == Kind.EthPrice ? ethFeed : btcFeed;
        if (
            beforeRound < m.startRound || beforeRound >> 64 != m.startRound >> 64
                || uint64(beforeRound) == type(uint64).max
        ) revert InvalidPriceBoundary();
        (uint80 r, int256 answer, uint256 started, uint256 updated, uint80 answered) =
            feed.getRoundData(beforeRound);
        _validatePrice(r, answer, started, updated, answered);
        (uint80 next, int256 nextAnswer, uint256 nextStarted, uint256 nextTime, uint80 nextAnswered) =
            feed.getRoundData(beforeRound + 1);
        _validatePrice(next, nextAnswer, nextStarted, nextTime, nextAnswered);
        if (r != beforeRound || next != beforeRound + 1 || updated > m.endsAt || nextTime <= m.endsAt) {
            revert InvalidPriceBoundary();
        }
        if (m.endsAt - updated > MAX_PRICE_AGE || nextTime - m.endsAt > MAX_PRICE_AGE) revert StalePrice();
        _finish(id, uint256(answer), false);
    }

    /// @notice Verifies the first Sepolia execution block at/after expiry. No keeper-reported values.
    function settleNative(uint256 id, bytes calldata parentHeader, bytes calldata targetHeader)
        external
        nonReentrant
    {
        _beginResolution(id, false);
        Market storage m = markets[id];
        (Kind kind,,) = marketTemplate(m.templateId);
        if (kind != Kind.BaseFee && kind != Kind.EthBlocks) revert WrongKind();
        BlockHeader.Header memory header = BlockHeader.boundary(parentHeader, targetHeader, m.endsAt);
        if (header.number < m.startBlock) revert BlockHeader.NotBoundaryBlock();
        _finish(id, kind == Kind.BaseFee ? header.baseFee : header.number - m.startBlock, false);
    }

    function expire(uint256 id) external nonReentrant {
        _beginResolution(id, true);
        _finish(id, 0, true);
    }

    /// @notice All payouts are proportional to net stake. Anyone can advance automatic payments.
    function pay(uint256 id, uint256 maxAccounts) external nonReentrant {
        _exists(id);
        if (maxAccounts == 0 || maxAccounts > MAX_PAY_BATCH) revert InvalidBatch();
        _payBatch(id, maxAccounts);
    }

    function claim(uint256 id, address payable recipient) external nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        (uint256 amount, uint256 stake) = _payablePosition(id, msg.sender);
        if (amount == 0 || positions[id][msg.sender].paid) revert NothingToClaim();
        _debit(id, msg.sender, amount, stake);
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit Paid(id, msg.sender, recipient, amount);
        _dust(id);
    }

    function claimable(uint256 id, address user) external view returns (uint256) {
        if (positions[id][user].paid) return 0;
        (uint256 amount,) = _payablePosition(id, user);
        return amount;
    }

    function _schedule(uint8 slot) private returns (uint256 id) {
        id = nextMarketId++;
        markets[id].createdAt = uint64(block.timestamp);
        markets[id].templateId = slot;
        activeIds[slot] = id;
        emit MarketScheduled(id, slot);
    }

    function _open(uint256 id) private {
        _exists(id);
        Market storage m = markets[id];
        if (m.status != Status.Scheduled) revert InvalidStatus();
        (Kind kind, uint32 duration, uint256 strike) = marketTemplate(m.templateId);
        uint64 startsAt = uint64(block.timestamp);
        uint64 endsAt = startsAt + duration;
        if (_isSqueek(kind)) {
            (startsAt, endsAt) = metrics.window(startsAt, duration, kind == Kind.MorningEvening);
        } else if (kind == Kind.EthPrice || kind == Kind.BtcPrice) {
            IAggregatorV3 feed = kind == Kind.EthPrice ? ethFeed : btcFeed;
            if (feed.decimals() != 8) revert InvalidPrice();
            (uint80 r, int256 answer, uint256 started, uint256 updated, uint80 answered) =
                feed.latestRoundData();
            _validatePrice(r, answer, started, updated, answered);
            if (block.timestamp - updated > MAX_PRICE_AGE) revert StalePrice();
            strike = uint256(answer);
            m.startRound = r;
        } else if (kind == Kind.BaseFee) {
            strike = block.basefee;
        }
        m.startsAt = startsAt;
        m.endsAt = endsAt;
        m.closesAt = kind == Kind.MorningEvening ? startsAt : startsAt + duration / 2;
        m.startBlock = uint64(block.number);
        m.strike = strike;
        m.status = Status.Open;
        emit MarketOpened(id, startsAt, m.closesAt, endsAt, strike);
    }

    function _tryOpen(uint256 id) private {
        try this.activate{gas: 300_000}(id) {}
        catch {
            emit ActivationDeferred(id);
        }
    }

    function _maintain() private {
        for (uint8 i; i < SLOT_COUNT; ++i) {
            uint256 id = activeIds[i];
            Market storage m = markets[id];
            if (m.status == Status.Open && block.timestamp >= m.endsAt) _roll(id);
            else if (m.status == Status.Scheduled) _tryOpen(id);
        }
    }

    function _roll(uint256 id) private {
        Market storage m = markets[id];
        m.status = Status.Awaiting;
        uint256 replacement = _schedule(m.templateId);
        emit MarketAwaiting(id, replacement);
        _tryOpen(replacement);
    }

    function _beginResolution(uint256 id, bool timeout) private {
        _exists(id);
        Market storage m = markets[id];
        if (m.status != Status.Open && m.status != Status.Awaiting) revert InvalidStatus();
        if (block.timestamp < m.endsAt) revert NotEnded();
        if (timeout) {
            if (block.timestamp < m.endsAt + RESOLUTION_GRACE) revert TimeoutNotReached();
        } else if (block.timestamp >= m.endsAt + RESOLUTION_GRACE) {
            revert ResolutionExpired();
        }
        if (m.status == Status.Open) _roll(id);
    }

    function _finish(uint256 id, uint256 value, bool refund) private {
        Market storage m = markets[id];
        m.result = value;
        m.winner = value > m.strike ? 1 : 0;
        uint256 winningPool = m.winner == 1 ? m.yesPool : m.noPool;
        refund = refund || winningPool == 0;
        m.status = refund ? Status.Refunded : Status.Resolved;
        m.eligibleRemaining = refund ? uint256(m.noPool) + m.yesPool : winningPool;
        emit MarketResolved(id, m.winner, value, refund);
        _payBatch(id, AUTO_PAY_BATCH);
    }

    function _payablePosition(uint256 id, address user) private view returns (uint256 amount, uint256 stake) {
        _exists(id);
        Market storage m = markets[id];
        Position storage p = positions[id][user];
        if (m.status == Status.Refunded) {
            stake = uint256(p.noStake) + p.yesStake;
            return (stake, stake);
        }
        if (m.status != Status.Resolved) return (0, 0);
        stake = m.winner == 1 ? p.yesStake : p.noStake;
        uint256 winningPool = m.winner == 1 ? m.yesPool : m.noPool;
        // Both multiplicands are <= MAX_POOL, whose square fits uint256.
        amount = stake * (uint256(m.noPool) + m.yesPool) / winningPool;
    }

    function _payBatch(uint256 id, uint256 maxAccounts) private {
        Market storage m = markets[id];
        if (m.status != Status.Resolved && m.status != Status.Refunded) revert InvalidStatus();
        uint256 end = m.paymentCursor + maxAccounts;
        if (end > bettors[id].length) end = bettors[id].length;
        while (m.paymentCursor < end) {
            address user = bettors[id][m.paymentCursor++];
            if (positions[id][user].paid) continue;
            (uint256 amount, uint256 stake) = _payablePosition(id, user);
            if (amount == 0) continue;
            _debit(id, user, amount, stake);
            (bool success,) = payable(user).call{value: amount, gas: PUSH_GAS}("");
            if (success) {
                emit Paid(id, user, user, amount);
                _dust(id);
            } else {
                positions[id][user].paid = false;
                m.remaining += amount;
                m.eligibleRemaining += stake;
                totalLiability += amount;
                emit PaymentDeferred(id, user, amount);
            }
        }
    }

    function _debit(uint256 id, address user, uint256 amount, uint256 stake) private {
        positions[id][user].paid = true;
        markets[id].remaining -= amount;
        markets[id].eligibleRemaining -= stake;
        totalLiability -= amount;
    }

    function _dust(uint256 id) private {
        Market storage m = markets[id];
        if (m.eligibleRemaining == 0 && m.remaining != 0) {
            uint256 dust = m.remaining;
            m.remaining = 0;
            totalLiability -= dust;
            retainedDust += dust;
            emit DustRetained(id, dust);
        }
    }

    function _validatePrice(uint80 round, int256 answer, uint256 started, uint256 updated, uint80 answered)
        private
        view
    {
        if (
            round == 0 || answer <= 0 || updated == 0 || started > updated || updated > block.timestamp
                || answered < round
        ) {
            revert InvalidPrice();
        }
    }

    function _isSqueek(Kind kind) private pure returns (bool) {
        return kind == Kind.SqueekBlocks || kind == Kind.LongestRun || kind == Kind.MorningEvening
            || kind == Kind.SqueekWork || kind == Kind.ActiveRounds;
    }

    function _exists(uint256 id) private view {
        if (id == 0 || id >= nextMarketId) revert InvalidMarket();
    }
}
