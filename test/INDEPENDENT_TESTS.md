# Independent Foundry tests

These tests extend the accepted suite without changing application code or build
configuration. They run offline using the existing vendored forge-std. Test
accounts, feed rounds and certified Core histories are local fixtures; no deployer
key, RPC endpoint, environment mutation, fork, FFI or live dependency is needed.

Run the entire suite with the assignment's fixed seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xdba95040efb3c81f1074eafdd39077e0d4827ce296f9ca29540f931d6f3c5ffe forge test
```

For checks that must keep generated artifacts under the permitted test tree, set
`FOUNDRY_OUT=test/scratch/out` and `FOUNDRY_CACHE_PATH=test/scratch/cache` on those
commands. No submitted test imports or otherwise depends on `test/scratch/`.

## Discovery and property coverage

The five supplied invariant-discovery perspectives were applied directly, without
subagents. The properties below are grounded in the requested pool economics and
the actual public API. Vault share-price properties do not apply: positions are
nontransferable net stakes in separate parimutuel pools.

| Perspective | Properties and evidence | Tests |
| --- | --- | --- |
| Conservation | Actual ETH received plus engine balance equals gross deposits plus forced donations. Market net deposits equal actual payments, outstanding liability and eventual dust. Fees are independently tracked from bet inputs. `SqueekPredict.sol:238`, `:479`, `:486`. | `StatefulSolvency.t.sol`, `PayoutProperties.t.sol` |
| State transitions | Settlement fixes the outcome and terms permanently; replacements retain their template and cannot absorb old liabilities. Failed settlement rolls back the replacement. Payment cursors advance by at most the requested batch. `SqueekPredict.sol:406`, `:414`, `:427`, `:454`. | `StatefulSolvency.t.sol`, `ProtocolEdges.t.sol` |
| Round trips and rounding | Refunds return net stakes; betting both sides cannot recover the fee. Proportional payouts satisfy cross-product bounds with less than one wei truncation per winner. Claim ordering cannot change another winner's entitlement. Dust is retained only after all eligible stake is paid. `SqueekPredict.sol:439`, `:486`. | `PayoutProperties.t.sol`, `StatefulSolvency.t.sol` |
| Adversarial callers | Rejecting or gas-exhausting wallets cannot block other recipients. Failed claims restore all debits. Claims cannot reenter any guarded entry point. Invalid sides, amounts, ids, routes, feed rounds and headers cannot take funds or rewrite markets. `SqueekPredict.sol:115`, `:238`, `:335`, `:454`. | `PayoutProperties.t.sol`, `ProtocolEdges.t.sol`, `HeaderProperties.t.sol` |
| Prediction pools and payment queues | Every template resolves from its designated metric/feed; equality selects side zero. Duplicate bets do not duplicate participant indexes. Claim-before-batch and repeated batches cannot pay twice. Unsolicited ETH cannot change odds or payouts. `SqueekPredict.sol:135`, `:176`, `:200`, `:269`, `:430`. | `ResolutionMatrix.t.sol`, `ProtocolEdges.t.sol`, `PayoutProperties.t.sol` |

## Stateful harness

`StatefulSolvency.t.sol` configures **64 runs × 96 calls**, with unexpected
handler reverts treated as failures. (The revised engine's rotation does more work
per maintenance call; 256 runs no longer finished inside the worker's time budget.) Nine selectors exercise betting, time
advancement, maintenance, price settlement/refunds, payment batches, claims,
recipient rejection, forced donations and explicitly invalid bets.

Four EOAs and two contract wallets start with finite balances. Their balances are
never replenished. The donation budget and separate claim recipient are included
in the closed-system conservation check. No application storage is edited.

Ghost ledgers use successful bet inputs and observed recipient balance deltas;
they do not read `remaining` or `totalLiability` to derive expected payments.
Each funded market's positions, gross volume, fee, outcome and actual payouts are
checked separately. Per-position proportionality uses multiplication inequalities
instead of reproducing the implementation's payout division.

Every sequence starts with genuine paid, deferred and open positions, preventing
an empty protocol from making the payout properties vacuous. `afterInvariant`
expires every remaining funded market and claims every outstanding entitlement,
then checks zero remaining liability and conservation again. The original
invariant suite remains intact and complements this with Squeek settlement.

Since the lane-generation revision, the stateful suite also checks after every call
that each nonzero `observingMarketIds()` entry is the lane's older, still-Open
market and that an Open successor never closes before it ends. After each sequence
it checks that every Scheduled or Open market is its lane's bettable or observing
generation, so no live market is ever orphaned.

## Lane generations (revision)

`GenerationLifecycle.t.sol` covers the overlapping-generation rotation from the
outside:

- Price bets stop at `closesAt` on the clock, before any keeper acts. The successor
  takes a fresh strike and feed round. A second `maintain` in the same block is a
  no-op, and successor stakes never reach the observing pool.
- An observing market times out to an exact refund at its grace boundary without
  touching its successor. Skipping the whole window retires the market directly
  with exactly one successor. Settling an unrotated active market schedules it.
- All seven Squeek lanes take stakes only before their window starts (fuzzed
  timing), with round-aligned windows and a full duration of betting time.
  Consecutive windows never overlap. A rolling lane rotated after its closing
  second skips exactly one unobserved 10-minute round; this is reported as
  behaviour, not as a defect.
- Any Core genesis move, earlier or later and on or off the round grid, fails
  closed and leaves the stakes refundable after the grace.
- Header proofs: BLOCKHASH serves exactly 256 blocks and the EIP-2935 history
  serves the rest up to 8,191. Overlong, reverting or zero history answers and
  current-block targets are rejected. An observing native lane settles through
  the history and clears its slot.

Earlier tests that hard-coded the original Squeek strikes, cutoffs and window
start now read them from `marketTemplate`/`getMarket`. Their properties are
unchanged.

## Boundary and oracle tests

- The pool-cap test reaches 1,000,000 ETH net through 10,101 maximum-size bets and
  one final smaller bet, then verifies that another minimum bet reverts atomically.
- Fee and payout properties use 1,000 fuzz cases. Explicit examples cover zero,
  one wei, minimum and maximum bets, the exact cutoff, delayed claims, one wei of
  dust, invalid batch sizes in the existing suite, and failed recipients.
- `MetricsProperties.t.sol` compares sparse 16-record pages with a dense model
  containing all 144 daily rounds, including idle rounds. It checks five metrics,
  shifted windows, history isolation, additive endpoint deltas, exact liveness
  limits, incompatible configurations and malformed pages.
- `HeaderProperties.t.sol` checks full-width integer round trips, malformed RLP,
  truncation, exact hash commitments and authenticated but invalid temporal
  boundaries. The accepted suite's real Sepolia header fixture remains in use.
- `ResolutionMatrix.t.sol` exercises all seven Core lanes and all three native
  lanes at their strike and above it; `ProtocolEdges.t.sol` covers all four price
  lanes, both feeds and strict equality semantics.

## Limits

The mocks exercise consumption and validation of oracle data. They do not prove
that an external feed is live or truthful. Block hashes are explicitly installed
in the local EVM; this is not a fork test or proof of deployed addresses.

The lane-count invariant concerns fourteen **current slots**, including scheduled
or observing slots. It does not establish twelve continuously bettable markets.
The metric tests verify the implementation's consecutive-active-round definition;
ten-minute aggregates cannot prove uninterrupted physical movement. Native header
tests concern the execution chain on which the engine runs. Deployment, website
publication, operator gas funding and live source availability are outside these
offline Solidity tests and are not certified by a passing suite.
