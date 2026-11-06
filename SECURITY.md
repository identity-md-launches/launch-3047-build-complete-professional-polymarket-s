# Security model and implementation review

This is an implementation self-review, **not an independent audit**. A separate contributor must review the accepted source, manifest and immutable arguments before release. No Slither or Mythril execution is claimed. Foundry unit/fuzz/invariant tests, offline JavaScript tests, real header fixtures, and browser/local-chain checks are the validation mechanisms used here.

## Custody and privileges

Only a payable `bet` adds accounted funds. Both sides' net stakes are recorded against `msg.sender`. There are no transferable positions, arbitrary-market APIs, upgrade paths, delegatecalls, self-destructs, external linked libraries, owner-only cancellation, administrative sweeps, fee withdrawal, or initializer. Constructor dependency arguments are nonzero and immutable; no external calls are made during construction.

`activate` is an external self-call isolation helper. It checks `msg.sender == address(this)`; ordinary entry points use a shared reentrancy guard. It cannot be invoked by a receiver or by a factory after deployment to bypass rules.

Payout debits happen before ETH calls. Automatic calls use bounded gas and ignore failed recipients after restoring their exact liabilities; an unbounded-gas manual claim reverts atomically on transfer failure. No payout destination can claim another account's stake. Manual claims may select a new recipient only for the caller's entitlement. Payout loops process 20/40 addresses, never an unbounded set.

## Specific failure cases reviewed and tested

| Concrete failure input | Required behavior and test coverage |
| --- | --- |
| Bet exactly at `closesAt`, after resolution, or with side 2 | Revert without retained value. |
| Caller chooses a price round after expiry to change the winner | Reject unless it is the last round at/before expiry with the immediate successor after it. Exact-expiry observations are included. |
| Zero/negative answer, future timestamp, insufficient answered round, wrong decimals, stale opening, phase change or missing history | Fail closed. Fixed timeout eventually permits net refund. |
| Squeek frontier stops before the measurement end | Do not interpret missing rounds as zero. Refund after timeout. New stakes against a paused/stale source are blocked. |
| Squeek page ends early at its 16-record cap | Continue from its returned certified frontier; preserve streaks across pages and break them across idle rounds. Test a full 144-active-round day and endpoint flooring. |
| Caller forges gas data or supplies a favorable later block | Full header hash must match BLOCKHASH; the target's committed parent must be before expiry and the target at/after it. Forged, later, malformed and expired proofs are rejected. Real Amsterdam header fixtures cover current fields. |
| A bettor rejects ETH or reenters `claim` from its receive function | Other payments progress; accounting remains exact; no second payout can occur. |
| Forty-five winners | Settlement processes twenty recipients, further bounded calls finish exactly once. |
| No winning stake, both-side stake, no bettors, or fractional pro-rata division | Net refunds or proportional payout, with only final rounding dust retained and no fee invasion. |
| RPC or source unavailable during rotation | A failed source affects only its lane. Existing old pools stay independent; fourteen current slots remain unique. |
| Keeper misses the evidence deadline | At the exact 48h boundary outcome settlement is disabled and refund is permissionless. |

The stateful handler advances clocks, changes mock certification/feeds, bets from four independently funded actors, resolves/voids arbitrary generations and repeats payment work. It asserts conservation across all actors and the contract, the sum of every market's remaining liabilities, and the fourteen current-lane identities. The required task fuzz seed is used for the recorded run; no seed is hardcoded into the configuration.

## Trust and limitations

- Core's Reporter certifies physical activity; the application cannot independently verify the hamster or infer movement inside a ten-minute aggregate. Core and Chainlink proxies can be upgraded by their external administrators. Those protocol controls are outside this application's authority.
- Native network metrics are Sepolia metrics. Low-cost testnet activity and physical-source reporting may be economically manipulable. These are testnet demonstrations with no promise of mainnet-grade economic integrity.
- Parimutuel odds are informative pool ratios, not locked prices. New bets dilute other winning stakes. A cumulative threshold can become likely or certain before the halfway betting cutoff. Users can see that information, and no fixed return is promised.
- The first/before-deadline observations and unique block boundary are deterministic, but timely proof submission needs an active keeper. A missing proof can cause a refund instead of the eventual observable outcome. All users accept this fixed timeout rule before betting.
- A keeper must pay gas from its own funds. Contract fees remain locked as explicitly requested. Therefore unlimited zero-volume uptime cannot be financed by the contract; an owner liquidity subsidy is unnecessary, but an operational gas budget remains necessary.
- Forced ETH is harmless surplus and cannot be rescued. Claims do not expire, so per-market and per-user history grows; all on-chain work and pagination is bounded per call.
- Browsers trust the static site's published configuration and host. The deployment handoff compares runtime bytes against the compiled build, verifies immutable dependency identities, and pins a runtime hash. Wallet sends are simulated, explicitly bind Sepolia, and require wallet approval. The website has no signing keys or server-side user custody.

## Pre-release handoff

Independent review must verify the actual launch's two addresses, constructor arguments, deployed bytecode, source-verification publication, site configuration, CSP/HTTPS hosting and funded keeper. Confirm the specified Core has resumed before advertising fourteen available market types. The repository intentionally contains neither launch credentials nor a fabricated live URL.
