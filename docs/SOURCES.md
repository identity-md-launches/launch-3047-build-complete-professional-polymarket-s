# Public source evidence

Checked on 2026-11-06 using Sepolia chain ID 11155111 and the public read RPC **https://ethereum-sepolia-rpc.publicnode.com**. No deployment or signing was performed as part of these checks.

## Specified SqueekCore

- Proxy required by the brief: `0x74665dAecA35A2303e767E76a2FF1FB6F93e119f`. RPC returned nonempty code.
- EIP-1967 implementation observed: `0x0a71c86ab63a77675002a389fdf4d096a07b11e2`.
- [Sourcify verified implementation, ABI and source](https://sourcify.dev/server/v2/contract/11155111/0x0a71c86ab63a77675002a389fdf4d096a07b11e2?fields=abi,sources).
- `configuration()` returned genesis **1791847800** (2026-10-12 23:30 UTC), round duration **600**, and block units per block **1,000,000,000**.
- `state()` returned certified frontier **1973**, cumulative work **148986**, cumulative block units **13095604188187**, completed block height **13095**, and paused **false**.
- Derived certification endpoint: `1791847800 + 1973 * 600 = 1793031600`, or **2026-10-26 16:20 UTC**. Unpaused does not mean fresh. Opening new Squeek pools correctly fails the six-hour liveness guard at the checked time.

The eight-field CoreState, eleven-field CoreConfiguration, and `roundPage(uint64,uint64,uint256)` interface in `src/interfaces/ISqueekCore.sol` match that implementation's verified ABI. [The Core reference](https://docs.squeekchain.com/developers/core/) explains certification and round-page semantics. Exact endpoint reads use `roundPage(r,r,0)`. Pages contain active rounds; certified omissions are zero-work gaps. The certified frontier must cover the entire window before it is usable.

[The current deployment documentation](https://docs.squeekchain.com/developers/) publishes a different Core release. The requested address remains pinned here. Replacing it would change the prediction source and requires an explicitly agreed new deployment; there is no mutable source pointer that could retroactively change funded markets.

## Chainlink price feeds

| Feed | Sepolia proxy | Verified getter results |
| --- | --- | --- |
| ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | `description() = "ETH / USD"`, `decimals() = 8`; positive, timestamped `latestRoundData()` |
| BTC/USD | `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43` | `description() = "BTC / USD"`, `decimals() = 8`; positive, timestamped `latestRoundData()` |

Addresses were cross-checked with [Chainlink's ETH feed API example](https://docs.chain.link/data-feeds/api-reference) and [BTC consuming-feeds guide](https://docs.chain.link/docs/consuming-data-feeds). [Historical feed documentation](https://docs.chain.link/data-feeds/historical-data) explains composite proxy round IDs and phases. The application requires an adjacent before/after pair in the opening phase; it does not assume a current answer represents the price at an earlier deadline. The keeper rejects incomplete history and the contract independently checks every supplied round.

## Native Sepolia headers

`test/fixtures/sepolia-headers.json` contains only public header fields for consecutive Sepolia blocks **12076106 and 12076107**. Both headers are re-encoded and hashed in the offline JavaScript tests, and the same bytes are authenticated by the Solidity tests through an injected canonical block hash. These are public network fixtures, not fabricated settlement evidence.

The encoder follows [Geth v1.17.7's Header declaration](https://github.com/ethereum/go-ethereum/blob/v1.17.7/core/types/block.go), including the appended `blockAccessListHash` and `slotNumber` fields active on the observed Sepolia chain. Those fields are defined by [EIP-7928](https://eips.ethereum.org/EIPS/eip-7928) and [EIP-7843](https://eips.ethereum.org/EIPS/eip-7843). It refuses any header whose encoding does not reproduce the RPC's block hash. The Solidity parser authenticates the full hash and extracts number, timestamp and base fee from their fixed positions, while allowing bounded appended fields.

Future incompatible header formats must be supported by a new application deployment if they change those positions or the block hash scheme. The existing market's timeout refund remains available without a header proof.
