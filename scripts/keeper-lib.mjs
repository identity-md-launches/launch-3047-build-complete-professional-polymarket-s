import { settlementAction } from '../web/lib/proofs.js';

const asMarket = (m, id) => ({ ...(typeof m.toObject === 'function' ? m.toObject() : m), id: BigInt(id) });

/** Payment batch sizes tried in turn when the larger one does not fit the per-transaction gas budget. */
export const PAY_BATCHES = [40, 20, 10, 5];

/** One bounded cycle. The caller supplies a sender; the library never loads keys or the environment. */
export async function runCycle({ contract, provider, send, checkpoint, maxTransactions = 12, scanBatch = 32, log = () => {} }) {
  if (!Number.isInteger(maxTransactions) || maxTransactions < 1 || maxTransactions > 100) throw new Error('Invalid transaction budget.');
  const block = await provider.getBlock('latest');
  if (!block || Date.now() / 1000 - block.timestamp > 180) throw new Error('RPC latest block is stale.');
  const now = block.timestamp;
  let budget = maxTransactions;
  let completed = 0;
  const active = Array.from(await contract.activeMarketIds(), BigInt);
  const observing = typeof contract.observingMarketIds === 'function' ? Array.from(await contract.observingMarketIds(), BigInt).filter(id => id !== 0n) : [];
  const activeMarkets = Array.from(await contract.getMarkets(active), (m, i) => asMarket(m, active[i]));
  const observingMarkets = observing.length ? Array.from(await contract.getMarkets(observing), (m, i) => asMarket(m, observing[i])) : [];
  // Upkeep is due when a bettable market has closed or ended, an observing market has ended, or a lane can open.
  let maintain = activeMarkets.some(m => Number(m.status) === 1 && Number(m.closesAt) <= now)
    || observingMarkets.some(m => Number(m.status) === 1 && Number(m.endsAt) <= now);
  if (!maintain) {
    for (const m of activeMarkets) {
      if (Number(m.status) !== 0) continue;
      try { await contract.open.staticCall(m.id); maintain = true; break; } catch {}
    }
  }
  // A transaction the sender refused to submit (gas budget) is not charged against the cycle budget.
  const dispatch = async action => {
    if (budget === 0) return false;
    --budget;
    try {
      const changed = await send(action);
      if (changed) ++completed;
      return changed;
    } catch (e) {
      if (e?.code === 'NOT_SENT') ++budget;
      throw e;
    }
  };
  if (maintain) {
    try { await dispatch({ method: 'maintain', args: [] }); } catch (e) { log(`upkeep: ${e.shortMessage || e.message}`); }
  }
  const next = BigInt(await contract.nextMarketId());
  let cursor = BigInt(checkpoint.nextScan ?? '1');
  if (cursor < 1n || cursor > next) cursor = 1n;
  const ids = new Set([...active.map(String), ...observing.map(String), ...(checkpoint.pending || [])]);
  for (let i = 0; i < scanBatch && cursor < next; ++i, ++cursor) ids.add(String(cursor));
  const pending = new Set();
  // Active deadlines first, then oldest retained jobs. Settlement never depends on local state.
  for (const textId of ids) {
    const id = BigInt(textId);
    if (id <= 0n || id >= next) continue;
    let market;
    try { market = asMarket(await contract.getMarket(id), id); }
    catch (e) { pending.add(textId); log(`read ${id}: ${e.shortMessage || e.message}`); continue; }
    if (Number(market.status) < 3) {
      pending.add(textId);
      if (Number(market.status) === 0 || Number(market.endsAt) > now || budget === 0) continue;
      try {
        const action = await settlementAction(contract, provider, market, now);
        // A failed static call sends nothing and spends no operator gas.
        await contract[action.method].staticCall(...action.args);
        if (await dispatch(action)) market = asMarket(await contract.getMarket(id), id);
      } catch (e) { log(`market ${id}: ${e.shortMessage || e.message}`); }
    }
    if (Number(market.status) >= 3) {
      const count = BigInt(await contract.bettorCount(id));
      if (BigInt(market.paymentCursor) < count) {
        pending.add(textId);
        if (budget) {
          try {
            let changed = false;
            for (const size of PAY_BATCHES) {
              try { changed = await dispatch({ method: 'pay', args: [id, size] }); break; }
              catch (e) { if (e?.code !== 'NOT_SENT' || size === PAY_BATCHES.at(-1)) throw e; }
            }
            if (changed) {
              market = asMarket(await contract.getMarket(id), id);
              if (BigInt(market.paymentCursor) >= count) pending.delete(textId);
            }
          } catch (e) { log(`payments ${id}: ${e.shortMessage || e.message}`); }
        }
      } else pending.delete(textId);
    }
  }
  checkpoint.nextScan = String(cursor);
  checkpoint.pending = [...pending];
  return { completed, attempted: maxTransactions - budget, pending: pending.size, nextScan: checkpoint.nextScan };
}
