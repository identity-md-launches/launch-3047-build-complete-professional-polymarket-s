// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Headers {
    function make(bytes32 parent, uint256 number, uint256 time, uint256 fee)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory payload = bytes.concat(hex"a0", parent);
        for (uint256 i = 1; i < 16; ++i) {
            bytes memory field =
                i == 8 ? integer(number) : i == 11 ? integer(time) : i == 15 ? integer(fee) : bytes(hex"80");
            payload = bytes.concat(payload, field);
        }
        return payload.length < 56
            ? bytes.concat(bytes1(uint8(0xc0 + payload.length)), payload)
            : bytes.concat(hex"f8", bytes1(uint8(payload.length)), payload);
    }

    function integer(uint256 x) internal pure returns (bytes memory result) {
        if (x == 0) return hex"80";
        if (x < 128) return abi.encodePacked(uint8(x));
        uint256 size;
        for (uint256 y = x; y != 0; y >>= 8) {
            ++size;
        }
        result = new bytes(size + 1);
        result[0] = bytes1(uint8(0x80 + size));
        for (uint256 i; i < size; ++i) {
            result[size - i] = bytes1(uint8(x >> (8 * i)));
        }
    }
}
