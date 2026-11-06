// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SqueekPredict} from "../src/SqueekPredict.sol";
import {SqueekMetrics} from "../src/SqueekMetrics.sol";
import {MockCore} from "./mocks/MockCore.sol";
import {MockFeed} from "./mocks/MockFeed.sol";

contract MarketHandler is Test {
    SqueekPredict public market;
    MockCore public core;
    MockFeed public feed;
    address[4] public actors;
    uint80 private round = 100;
    uint64 constant GENESIS = 1_728_000_000;

    constructor(SqueekPredict m, MockCore c, MockFeed f) {
        market = m;
        core = c;
        feed = f;
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(10000 + i));
            vm.deal(actors[i], 1000 ether);
        }
    }

    function bet(uint8 slot, uint8 who, uint96 amount, bool yes) external {
        uint256 id = market.activeMarketIds()[slot % 14];
        SqueekPredict.Market memory m = market.getMarket(id);
        if (m.status != SqueekPredict.Status.Open || block.timestamp >= m.closesAt) return;
        uint256 value = bound(amount, 0.001 ether, 1 ether);
        vm.prank(actors[who % 4]);
        market.bet{value: value}(id, yes ? 1 : 0);
    }

    function elapse(uint32 duration) external {
        uint256 elapsed = bound(duration, 1, 3 days);
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + elapsed / 12 + 1);
        feed.put(++round, 2000e8, block.timestamp);
        core.setFrontier(uint64((block.timestamp - GENESIS) / 600));
        market.maintain();
    }

    function resolve(uint256 seed) external {
        uint256 id = 1 + seed % (market.nextMarketId() - 1);
        SqueekPredict.Market memory m = market.getMarket(id);
        if (
            (m.status != SqueekPredict.Status.Open && m.status != SqueekPredict.Status.Awaiting)
                || block.timestamp < m.endsAt
        ) return;
        if (block.timestamp >= m.endsAt + 2 days) {
            market.expire(id);
            return;
        }
        uint8 slot = m.templateId;
        if (slot < 5 || slot == 10 || slot == 11) market.settleSqueek(id);
    }

    function pay(uint256 seed) external {
        uint256 id = 1 + seed % (market.nextMarketId() - 1);
        SqueekPredict.Status status = market.getMarket(id).status;
        if (status == SqueekPredict.Status.Resolved || status == SqueekPredict.Status.Refunded) {
            market.pay(id, 40);
        }
    }
}

contract AccountingInvariantTest is StdInvariant, Test {
    SqueekPredict market;
    MarketHandler handler;

    function setUp() public {
        vm.warp(1_728_000_000 + 1 days + 1);
        vm.roll(1000);
        MockCore core = new MockCore(1_728_000_000);
        core.setFrontier(144);
        MockFeed feed = new MockFeed();
        feed.put(100, 2000e8, block.timestamp);
        market = new SqueekPredict(address(new SqueekMetrics(address(core))), address(feed), address(feed));
        market.maintain();
        handler = new MarketHandler(market, core, feed);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.bet.selector;
        selectors[1] = handler.elapse.selector;
        selectors[2] = handler.resolve.selector;
        selectors[3] = handler.pay.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantBalanceEqualsLiabilitiesAndLockedReserves() public view {
        assertEq(
            address(market).balance, market.totalLiability() + market.retainedFees() + market.retainedDust()
        );
        uint256 remaining;
        for (uint256 id = 1; id < market.nextMarketId(); ++id) {
            remaining += market.getMarket(id).remaining;
        }
        assertEq(remaining, market.totalLiability());
    }

    function invariantTotalEtherIsConservedAcrossEveryActor() public view {
        uint256 total = address(market).balance;
        for (uint256 i; i < 4; ++i) {
            total += handler.actors(i).balance;
        }
        assertEq(total, 4000 ether);
    }

    function invariantExactlyFourteenUniqueCurrentLanes() public view {
        uint256[14] memory ids = market.activeMarketIds();
        for (uint256 i; i < 14; ++i) {
            SqueekPredict.Market memory m = market.getMarket(ids[i]);
            assertEq(m.templateId, i);
            assertTrue(m.status == SqueekPredict.Status.Open || m.status == SqueekPredict.Status.Scheduled);
            for (uint256 j = i + 1; j < 14; ++j) {
                assertTrue(ids[i] != ids[j]);
            }
        }
    }
}
