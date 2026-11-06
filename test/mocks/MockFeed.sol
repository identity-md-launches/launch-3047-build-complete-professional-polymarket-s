// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

contract MockFeed is IAggregatorV3 {
    struct Round {
        uint80 id;
        int256 answer;
        uint256 started;
        uint256 updated;
        uint80 answered;
    }
    mapping(uint80 => Round) public rounds;
    uint80 public latest;
    uint8 public decimals = 8;
    bool public broken;

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function put(uint80 id, int256 answer, uint256 time) external {
        rounds[id] = Round(id, answer, time, time, id);
        latest = id;
    }

    function corrupt(uint80 key, Round calldata r) external {
        rounds[key] = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return _get(latest);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        return _get(id);
    }

    function _get(uint80 id) private view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed unavailable");
        Round memory r = rounds[id];
        require(r.id != 0, "No data present");
        return (r.id, r.answer, r.started, r.updated, r.answered);
    }
}
