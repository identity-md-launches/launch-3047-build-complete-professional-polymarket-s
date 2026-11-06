// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BlockHeader} from "../src/libraries/BlockHeader.sol";
import {Headers} from "./helpers/Headers.sol";
import {SepoliaHeaders} from "./fixtures/SepoliaHeaders.sol";

contract HeaderReader {
    function decode(bytes calldata b) external pure returns (BlockHeader.Header memory) {
        return BlockHeader.decode(b);
    }

    function boundary(bytes calldata a, bytes calldata b, uint256 t)
        external
        view
        returns (BlockHeader.Header memory)
    {
        return BlockHeader.boundary(a, b, t);
    }
}

contract BlockHeaderTest is Test {
    HeaderReader reader = new HeaderReader();

    function testFuzzDecodeBoundedHeader(uint64 number, uint64 time, uint64 fee, bytes32 parent) public view {
        BlockHeader.Header memory h = reader.decode(Headers.make(parent, number, time, fee));
        assertEq(h.number, number);
        assertEq(h.timestamp, time);
        assertEq(h.baseFee, fee);
        assertEq(h.parentHash, parent);
    }

    function testRejectMalformedRlp() public {
        bytes[7] memory bad = [bytes(hex""), hex"80", hex"c0", hex"f800", hex"f90001c0", hex"c181", hex"f8ff"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert();
            reader.decode(bad[i]);
        }
        bytes memory valid = Headers.make(bytes32(uint256(1)), 100, 200, 300);
        vm.expectRevert();
        reader.decode(bytes.concat(valid, hex"00"));
    }

    function testBoundaryAt256BlockLimit() public {
        bytes memory parent = Headers.make(bytes32(uint256(1)), 99, 199, 300);
        bytes memory target = Headers.make(keccak256(parent), 100, 200, 300);
        vm.warp(400);
        vm.roll(356);
        vm.setBlockhash(100, keccak256(target));
        assertEq(reader.boundary(parent, target, 200).number, 100);
        vm.roll(357);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(parent, target, 200);
    }

    function testRealSepoliaAmsterdamBoundaryIsDecodedAndAuthenticated() public {
        vm.warp(SepoliaHeaders.TIMESTAMP + 120);
        vm.roll(SepoliaHeaders.NUMBER + 10);
        vm.setBlockhash(SepoliaHeaders.NUMBER, SepoliaHeaders.HASH);
        BlockHeader.Header memory h =
            reader.boundary(SepoliaHeaders.parent(), SepoliaHeaders.target(), SepoliaHeaders.TIMESTAMP);
        assertEq(h.number, SepoliaHeaders.NUMBER);
        assertEq(h.timestamp, SepoliaHeaders.TIMESTAMP);
        assertEq(h.baseFee, SepoliaHeaders.BASE_FEE);
    }
}
