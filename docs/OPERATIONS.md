# Operating Squeek Predict

## What runs continuously

The contracts have no privileged operator. A supervised keeper is the normal transaction sender, and users can run the same permissionless methods. Every winning pool is funded by net bets, but the keeper's account must hold Sepolia ETH for transaction gas. The fee reserve is intentionally locked and cannot fund this account. A completely idle, unfunded operator cannot provide unattended market rotation.

Serve `web/` over HTTPS and run `scripts/keeper.mjs` with the verified public configuration, an explicitly supplied signer RPC/account, and a durable state file outside the website document root. The signer service, gas account, static host, monitoring and restart policy are launch/operator responsibilities, not contracts embedded in this project. No secrets are shipped.

The website's default preview is deliberate. Never publish made-up deployment data to remove that notice. Only `scripts/configure-site.mjs` should populate a production configuration from the confirmed launch, after the exact Foundry build and independent review.

## Daily monitoring

- **Market rotation:** `activeMarketIds()` has fourteen unique IDs, each `Scheduled` or `Open` and, when healthy, before its `closesAt`. `observingMarketIds()` holds the lane's previous generation while it observes (0 when none). Scheduled Squeek slots are expected while the specified Core is stale; scheduled prices indicate unavailable/stale opening observations. Repeated `ActivationDeferred` events are useful alerts; `checkUpkeep` returns false while nothing can progress.
- **Evidence:** monitor historical `Awaiting` markets and their `endsAt + resolutionGrace(slot)` deadline (48h; 24h for lanes 8, 9 and 13). Native header proofs stay available for 8191 blocks (about 27 hours) through the EIP-2935 history contract. Run the 30-second keeper loop with sufficient gas and RPC capacity; a one-hour alert threshold for an unsettled native market is sensible.
- **Payouts:** for terminal markets, compare `paymentCursor` against `bettorCount`. `PaymentDeferred` is a recipient problem, not a global queue failure. Deferred recipients should call `claim` through their own account with an accepting recipient.
- **Source:** compare Core genesis plus certified round × 600 to the chain clock. Pauses or certification older than six hours block new hamster stakes. A paused source can still provide already-certified historical outcomes.
- **Solvency:** `balance >= totalLiability + retainedFees + retainedDust`. Equality holds without unsolicited forced ETH. Neither reserve has a withdrawal path.
- **Transactions:** inspect reverted or timed-out keeper submissions, pending nonces, fee ceilings and gas balance. Multiple keepers are safe but may race; only one resolution succeeds. Pay gas only for actual progress where possible.

## Recovery

| Symptom | Permissionless recovery |
| --- | --- |
| Keeper restarts | Reuse its durable JSON cursor. If lost, use a new state file; current slots are processed immediately and history is scanned in chunks of 32 IDs. |
| Available market remains scheduled | Call `open(id)` or `maintain()`. If the source is not healthy, wait for it; no bet is accepted and no fee is retained on a reverted bet. |
| Old expired card remains current | Call `maintain()` or `performUpkeep("")`. It replaces expired slots even when their old evidence is unavailable. |
| Core has not certified the market end | Retry `settleSqueek(id)` after certification. At the 48h deadline use `expire(id)`. Never interpret unknown rounds as zero. |
| Feed has no bracketing pair | Wait for a successor, then use `settlePrice(id,beforeRound)` with the unique valid pair. Incompatible phases, missing IDs, or observations outside the two-hour window lead to timeout refund. |
| Native header is unavailable or too old | Do not replace it with a current block. At `endsAt + 24h`, use `expire(id)`. |
| More than twenty bettors | Call `pay(id,40)` until the cursor reaches the bettor count; use a smaller batch if the estimate exceeds your gas budget (the keeper retries 20, 10, 5). There is no array of user-controlled payout amounts. |
| Recipient rejected the automatic payment | That bettor calls `claim(id,acceptingRecipient)`. A contract bettor must call from the contract that placed the bet. The UI supports EIP-1193 wallets; contract wallet execution may require the wallet's own transaction interface. |
| Browser changed account/network | Reconnect the intended account. All reads stay on Sepolia; the transaction flow switches and explicitly binds chain ID 11155111. |

`checkUpkeep`/`performUpkeep` implement opening and rotation only. They do not claim an unconfigured third-party automation subscription. The supplied keeper also builds price/native evidence and drains payment batches; a replacement automation system must do those jobs too.

## Timing and financial semantics

Contracts do not execute merely because time passes. “Fourteen active markets” is implemented as fourteen persistent lanes, each with one bettable generation and at most one observing generation; a source outage or a missed transaction can reduce the number currently accepting bets. Expired historical markets waiting for evidence are separate from those fourteen. The protocol never fabricates markets, prices, data or liquidity to disguise an outage.

Payouts are attempted automatically after resolution, but are bounded to avoid one transaction scaling with every bettor. A gas-heavy or rejecting recipient retains its claim rather than blocking other winners. No claims expire. The outcome evidence does expire: exactly `resolutionGrace(slot)` after observation ends (48 hours; 24 hours for native lanes), only a net refund can be finalized.

The nominated owner has no hidden maintenance key, outcome override, fee withdrawal, pause control, or oracle-change power. Source upgrades and reporting are controlled by the external protocols. If the required Core is permanently retired, changing to another source requires a separately reviewed deployment and new website handoff. Existing stakes retain their original rules and refund/claim rights.
