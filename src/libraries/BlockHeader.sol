// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Read canonical RLP headers anchored to EVM BLOCKHASH; callers cannot choose a later sample.
library BlockHeader {
    error InvalidHeader();
    error UnprovenHeader();
    error NotBoundaryBlock();

    struct Header {
        bytes32 parentHash;
        uint256 number;
        uint256 timestamp;
        uint256 baseFee;
    }

    /// @dev EIP-2935 system contract (Prague), serving the last 8191 block hashes beyond BLOCKHASH's 256.
    address internal constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    uint256 internal constant HISTORY_WINDOW = 8191;

    function boundary(bytes calldata parentRlp, bytes calldata targetRlp, uint256 endsAt)
        internal
        view
        returns (Header memory target)
    {
        target = decode(targetRlp);
        bytes32 hash = canonicalHash(target.number);
        if (hash == bytes32(0) || keccak256(targetRlp) != hash || target.parentHash != keccak256(parentRlp)) {
            revert UnprovenHeader();
        }
        Header memory parent = decode(parentRlp);
        if (
            parent.number + 1 != target.number || parent.timestamp >= endsAt || target.timestamp < endsAt
                || target.timestamp > block.timestamp
        ) revert NotBoundaryBlock();
    }

    /// @notice The chain's hash for `number`, from BLOCKHASH or the EIP-2935 ring buffer; zero if unprovable.
    function canonicalHash(uint256 number) internal view returns (bytes32 hash) {
        if (number >= block.number) return bytes32(0);
        uint256 age = block.number - number;
        if (age <= 256) return blockhash(number);
        if (age > HISTORY_WINDOW) return bytes32(0);
        (bool ok, bytes memory data) = HISTORY.staticcall(abi.encode(number));
        if (!ok || data.length != 32) return bytes32(0);
        hash = abi.decode(data, (bytes32));
    }

    function decode(bytes calldata rlp) internal pure returns (Header memory h) {
        if (rlp.length == 0 || rlp.length > 2048) revert InvalidHeader();
        (uint256 offset, uint256 length, uint256 end, bool list) = _item(rlp, 0);
        if (!list || end != rlp.length || offset + length != end) revert InvalidHeader();
        uint256 field;
        while (offset < end) {
            (uint256 data, uint256 size, uint256 next, bool nested) = _item(rlp, offset);
            if (nested || next > end || field >= 32) revert InvalidHeader();
            if (field == 0) {
                if (size != 32) revert InvalidHeader();
                h.parentHash = bytes32(rlp[data:data + 32]);
            } else if (field == 8) {
                h.number = _integer(rlp, data, size);
            } else if (field == 11) {
                h.timestamp = _integer(rlp, data, size);
            } else if (field == 15) {
                h.baseFee = _integer(rlp, data, size);
            }
            offset = next;
            ++field;
        }
        if (field < 16) revert InvalidHeader();
    }

    function _integer(bytes calldata b, uint256 offset, uint256 size) private pure returns (uint256 n) {
        if (size > 32 || (size != 0 && b[offset] == 0)) revert InvalidHeader();
        for (uint256 i; i < size; ++i) {
            n = (n << 8) | uint8(b[offset + i]);
        }
    }

    function _item(bytes calldata b, uint256 pos)
        private
        pure
        returns (uint256 data, uint256 size, uint256 next, bool list)
    {
        if (pos >= b.length) revert InvalidHeader();
        uint8 prefix = uint8(b[pos]);
        if (prefix < 0x80) return (pos, 1, pos + 1, false);
        list = prefix >= 0xc0;
        uint256 shortBase = list ? 0xc0 : 0x80;
        if (prefix <= shortBase + 55) {
            size = prefix - shortBase;
            data = pos + 1;
        } else {
            uint256 sizeBytes = prefix - shortBase - 55;
            if (sizeBytes > 2 || pos + 1 + sizeBytes > b.length || b[pos + 1] == 0) revert InvalidHeader();
            for (uint256 i; i < sizeBytes; ++i) {
                size = (size << 8) | uint8(b[pos + 1 + i]);
            }
            if (size < 56) revert InvalidHeader();
            data = pos + 1 + sizeBytes;
        }
        next = data + size;
        if (next > b.length || (!list && size == 1 && uint8(b[data]) < 0x80)) revert InvalidHeader();
    }
}
