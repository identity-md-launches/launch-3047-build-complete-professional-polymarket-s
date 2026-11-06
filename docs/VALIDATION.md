# Validation record

Checked on November 6, 2026. These are local implementation checks, not deployment attestations or an independent audit.

| Check | Result |
| --- | --- |
| `forge build` | Passed with the pinned Solidity 0.8.26 configuration. |
| `forge test` | 41 tests passed, zero failed or skipped. |
| Stateful invariants | 64 runs and 4,096 handler calls, zero handler reverts; conservation, liability accounting and fourteen unique current lanes held. |
| `forge fmt --check` | Passed. |
| `node --test test/*.test.mjs` | 17 tests passed, zero failed or skipped. |
| Website ABIs | Both checked against their compiled artifacts and matched. |
| Deployed runtime size | `SqueekMetrics`: 4,227 bytes; `SqueekPredict`: 13,753 bytes. Both below 24,576 bytes. |

The Foundry run used the requested seed:

```text
0xdba95040efb3c81f1074eafdd39077e0d4827ce296f9ca29540f931d6f3c5ffe
```

The default Solidity and JavaScript tests use vendored imports, deterministic mocks and checked-in public header fixtures. They require no network, environment configuration, signer, fork, FFI or filesystem cheatcodes. Foundry must have the pinned compiler installed, as provided by the execution profile.

## Browser and local chain

A temporary Chromium smoke harness exercised the actual static site against contracts deployed on a disposable Anvil chain. Its Core and feeds were explicitly local test doubles. The public website configuration was not replaced with local addresses.

- Fourteen real contract-backed market cards rendered at desktop width 1,440px and mobile width 375px. Neither viewport overflowed horizontally; the mobile bet dialog fit the viewport.
- Category filters, search, wallet discovery, explicit connection and on-chain positions worked without browser runtime exceptions.
- The wallet initially reported the wrong chain. A successful bet switched to Sepolia's chain ID, explicitly bound that ID in the transaction request, deducted the correct fee and recorded the net stake.
- A rejected wallet request left the stake unchanged. Changing the wallet account replaced the displayed positions with that account's on-chain positions.
- The actual keeper library sent five successful local transactions: maintenance, historical price settlement, and three authenticated native-header settlements. It isolated unavailable mock sources and paid the winning test position automatically.
- A twenty-account payment batch left a later winning account with a manual claim. The UI rejected an invalid recipient, then paid exactly 0.2079 local test ETH to the selected accepting recipient. The same position could no longer be claimed.

The temporary harness is disposable test scaffolding. It is not a production dependency or evidence of a Sepolia deployment. The delivered Solidity and JavaScript suites remain independently runnable using the commands above.

## Remaining launch work

The authorized launch must deploy the two applications, verify their actual runtime and immutable arguments, publish the configured `web/` directory over HTTPS, and operate a funded keeper. The specified Core must resume certification before all Squeek lanes can open. See [README](../README.md), [source observations](SOURCES.md), [operations](OPERATIONS.md) and [security assumptions](../SECURITY.md).
