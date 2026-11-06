// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stand-in for the EIP-2935 history contract: 32-byte block number in, 32-byte hash out.
contract MockHistory {
    mapping(uint256 => bytes32) public hashes;

    function set(uint256 number, bytes32 hash) external {
        hashes[number] = hash;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        require(data.length == 32, "input");
        uint256 number = abi.decode(data, (uint256));
        require(number < block.number && block.number - number <= 8191, "range");
        return abi.encode(hashes[number]);
    }
}
