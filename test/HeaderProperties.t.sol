// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BlockHeader} from "src/libraries/BlockHeader.sol";
import {Headers} from "./helpers/Headers.sol";

contract IndependentHeaderReader {
    function decode(bytes calldata value) external pure returns (BlockHeader.Header memory) {
        return BlockHeader.decode(value);
    }

    function boundary(bytes calldata parent, bytes calldata target, uint256 end)
        external
        view
        returns (BlockHeader.Header memory)
    {
        return BlockHeader.boundary(parent, target, end);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HeaderPropertiesTest is Test {
    IndependentHeaderReader internal reader = new IndependentHeaderReader();

    function testFuzzFullWidthHeaderValuesRoundTrip(
        bytes32 parent,
        uint256 number,
        uint256 timestamp,
        uint256 fee
    ) public view {
        BlockHeader.Header memory decoded = reader.decode(Headers.make(parent, number, timestamp, fee));
        assertEq(decoded.parentHash, parent);
        assertEq(decoded.number, number);
        assertEq(decoded.timestamp, timestamp);
        assertEq(decoded.baseFee, fee);
    }

    function testZeroAndMaximumIntegersHaveDistinctValidEncodings() public view {
        BlockHeader.Header memory zero = reader.decode(Headers.make(bytes32(0), 0, 0, 0));
        BlockHeader.Header memory maximum = reader.decode(
            Headers.make(bytes32(type(uint256).max), type(uint256).max, type(uint256).max, type(uint256).max)
        );
        assertEq(zero.number, 0);
        assertEq(zero.timestamp, 0);
        assertEq(zero.baseFee, 0);
        assertEq(maximum.number, type(uint256).max);
        assertEq(maximum.timestamp, type(uint256).max);
        assertEq(maximum.baseFee, type(uint256).max);
    }

    function testEveryNumericFieldRejectsNonCanonicalAndOversizedIntegers() public {
        bytes[6] memory encodings = [
            bytes(hex"00"), // Integer zero is the empty string (80), never 00.
            bytes(hex"8101"), // Single-byte integer must use the single-byte form.
            bytes(hex"820080"), // Leading zero.
            bytes(hex"b80180"), // Long string form for a one-byte payload.
            bytes.concat(hex"a1", bytes32(type(uint256).max), hex"ff"), // 33 bytes.
            bytes(hex"c0") // A field cannot itself be a list.
        ];
        uint256[3] memory fields = [uint256(8), 11, 15];
        for (uint256 i; i < fields.length; ++i) {
            for (uint256 j; j < encodings.length; ++j) {
                bytes memory header = headerWithField(fields[i], encodings[j]);
                vm.expectRevert(BlockHeader.InvalidHeader.selector);
                reader.decode(header);
            }
        }
    }

    function testParentHashMustBeExactly32Bytes() public {
        bytes memory shortHash = headerWithField(0, bytes.concat(hex"9f", new bytes(31)));
        bytes memory longHash = headerWithField(0, bytes.concat(hex"a1", new bytes(33)));
        vm.expectRevert(BlockHeader.InvalidHeader.selector);
        reader.decode(shortHash);
        vm.expectRevert(BlockHeader.InvalidHeader.selector);
        reader.decode(longHash);
    }

    function testMissingBaseFeeTooManyFieldsAndNestedUnusedFieldsAreRejected() public {
        bytes memory payload = bytes.concat(hex"a0", bytes32(uint256(1)));
        for (uint256 i; i < 14; ++i) {
            payload = bytes.concat(payload, hex"80");
        }
        bytes memory shortHeader = rlpList(payload);
        vm.expectRevert(BlockHeader.InvalidHeader.selector);
        reader.decode(shortHeader);
        for (uint256 i; i < 18; ++i) {
            payload = bytes.concat(payload, hex"80");
        }
        bytes memory tooMany = rlpList(payload);
        vm.expectRevert(BlockHeader.InvalidHeader.selector);
        reader.decode(tooMany);
        bytes memory nested = headerWithField(4, hex"c0");
        vm.expectRevert(BlockHeader.InvalidHeader.selector);
        reader.decode(nested);
        vm.expectRevert(BlockHeader.InvalidHeader.selector);
        reader.decode(new bytes(2049));
    }

    function testFuzzTruncatedHeaderCannotDecode(uint256 cutSeed) public {
        bytes memory complete = Headers.make(bytes32(uint256(1)), type(uint64).max, 1_728_000_000, 10 gwei);
        uint256 cut = bound(cutSeed, 0, complete.length - 1);
        bytes memory truncated = new bytes(cut);
        for (uint256 i; i < cut; ++i) {
            truncated[i] = complete[i];
        }
        vm.expectRevert(BlockHeader.InvalidHeader.selector);
        reader.decode(truncated);
    }

    function testFuzzBoundaryRequiresExactParentAndTargetHashes(bytes32 salt) public {
        bytes memory parent = Headers.make(salt, 49_999, 999_999, 3 gwei);
        bytes memory target = Headers.make(keccak256(parent), 50_000, 1_000_000, 4 gwei);
        vm.warp(1_000_100);
        vm.roll(50_001);
        vm.setBlockhash(50_000, keccak256(target));
        assertEq(reader.boundary(parent, target, 1_000_000).baseFee, 4 gwei);
        bytes memory wrongParent = Headers.make(salt, 49_999, 999_999, 3 gwei + 1);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(wrongParent, target, 1_000_000);
        bytes memory wrongTarget = Headers.make(keccak256(parent), 50_000, 1_000_000, 4 gwei + 1);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(parent, wrongTarget, 1_000_000);
    }

    function testAuthenticatedButNonBoundaryHeadersAreRejected() public {
        // Authenticating a supplied hash alone must never bypass temporal checks.
        uint256[4] memory parentNumber = [uint256(49_998), 49_999, 49_999, 49_999];
        uint256[4] memory parentTime = [uint256(999_999), 1_000_000, 999_998, 999_999];
        uint256[4] memory targetTime = [uint256(1_000_000), 1_000_001, 999_999, 1_000_101];
        vm.warp(1_000_100);
        vm.roll(50_001);
        for (uint256 i; i < 4; ++i) {
            bytes memory parent = Headers.make(bytes32(uint256(1)), parentNumber[i], parentTime[i], 1);
            bytes memory target = Headers.make(keccak256(parent), 50_000, targetTime[i], 2);
            vm.setBlockhash(50_000, keccak256(target));
            vm.expectRevert(BlockHeader.NotBoundaryBlock.selector);
            reader.boundary(parent, target, 1_000_000);
        }
    }

    function testCurrentAndFutureBlocksCannotBeProven() public {
        bytes memory parent = Headers.make(bytes32(uint256(1)), 49_999, 999_999, 1);
        bytes memory target = Headers.make(keccak256(parent), 50_000, 1_000_000, 2);
        vm.warp(1_000_001);
        vm.roll(50_000);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(parent, target, 1_000_000);
        vm.roll(49_999);
        vm.expectRevert(BlockHeader.UnprovenHeader.selector);
        reader.boundary(parent, target, 1_000_000);
    }

    function headerWithField(uint256 index, bytes memory encoded) internal pure returns (bytes memory) {
        bytes memory payload;
        for (uint256 i; i < 16; ++i) {
            bytes memory field = i == index
                ? encoded
                : i == 0
                    ? bytes.concat(hex"a0", bytes32(uint256(1)))
                    : i == 8
                        ? bytes(hex"01")
                        : i == 11 ? bytes(hex"02") : i == 15 ? bytes(hex"03") : bytes(hex"80");
            payload = bytes.concat(payload, field);
        }
        return rlpList(payload);
    }

    function rlpList(bytes memory payload) internal pure returns (bytes memory) {
        if (payload.length < 56) return bytes.concat(bytes1(uint8(0xc0 + payload.length)), payload);
        return bytes.concat(hex"f8", bytes1(uint8(payload.length)), payload);
    }
}
