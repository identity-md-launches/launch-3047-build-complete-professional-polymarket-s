// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekPredict} from "src/SqueekPredict.sol";
import {SqueekMetrics} from "src/SqueekMetrics.sol";
import {MockCore} from "../mocks/MockCore.sol";
import {MockFeed} from "../mocks/MockFeed.sol";

/// @dev A bettor whose failed push can later be claimed to an unrelated recipient.
contract DeferredWallet {
    SqueekPredict public immutable engine;
    bool public rejecting = true;

    constructor(SqueekPredict engine_) {
        engine = engine_;
    }

    function setRejecting(bool value) external {
        rejecting = value;
    }

    function place(uint256 id, uint8 side, uint256 amount) external {
        engine.bet{value: amount}(id, side);
    }

    function withdraw(uint256 id, address payable recipient) external {
        engine.claim(id, recipient);
    }

    receive() external payable {
        require(!rejecting, "wallet rejects push");
    }
}

/// @dev Test-only forced donation; no application runtime is changed.
contract ForcedDonation {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

abstract contract IndependentSetup is Test {
    uint64 internal constant GENESIS = 1_728_000_000;
    uint80 internal constant START_ROUND = (uint80(1) << 64) | 100;
    SqueekPredict internal engine;
    SqueekMetrics internal metrics;
    MockCore internal core;
    MockFeed internal ethFeed;
    MockFeed internal btcFeed;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public virtual {
        vm.warp(GENESIS + 1 days + 17);
        vm.roll(10_000);
        vm.fee(10 gwei);
        core = new MockCore(GENESIS);
        core.setFrontier(144);
        metrics = new SqueekMetrics(address(core));
        ethFeed = new MockFeed();
        btcFeed = new MockFeed();
        ethFeed.put(START_ROUND, 2_000e8, block.timestamp);
        btcFeed.put(START_ROUND, 60_000e8, block.timestamp);
        engine = new SqueekPredict(address(metrics), address(ethFeed), address(btcFeed));
        alice = makeAddr("independent alice");
        bob = makeAddr("independent bob");
        carol = makeAddr("independent carol");
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
        vm.deal(address(this), 1_000 ether);
        engine.maintain();
    }

    function place(address actor, uint256 id, uint8 side, uint256 gross) internal {
        vm.prank(actor);
        engine.bet{value: gross}(id, side);
    }

    function wallet() internal returns (DeferredWallet w) {
        w = new DeferredWallet(engine);
        vm.deal(address(w), 1_000 ether);
    }

    function finishPrice(uint256 id, int256 answer) internal {
        SqueekPredict.Market memory m = engine.getMarket(id);
        MockFeed feed = m.templateId == 7 || m.templateId == 12 ? btcFeed : ethFeed;
        vm.warp(m.endsAt + 60);
        feed.put(START_ROUND + 1, answer, m.endsAt);
        feed.put(START_ROUND + 2, answer + 1, m.endsAt + 1);
        engine.settlePrice(id, START_ROUND + 1);
    }

    function assertAccounting(uint256 surplus) internal view {
        uint256 remaining;
        for (uint256 id = 1; id < engine.nextMarketId(); ++id) {
            remaining += engine.getMarket(id).remaining;
        }
        assertEq(remaining, engine.totalLiability(), "sum of market liabilities");
        assertEq(
            address(engine).balance,
            remaining + engine.retainedFees() + engine.retainedDust() + surplus,
            "ETH backs liabilities and retained reserves"
        );
    }
}
