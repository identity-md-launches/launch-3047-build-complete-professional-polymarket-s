import { Contract, encodeRlp, keccak256, toBeHex } from '../vendor/ethers-6.15.0.min.js';
import { template } from './markets.js';

export const FEED_ABI = [
  'function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)',
  'function getRoundData(uint80) view returns (uint80,int256,uint256,uint256,uint80)',
];

const integer = value => {
  const n = BigInt(value);
  if (n < 0n) throw new Error('Negative header integer.');
  return n === 0n ? '0x' : toBeHex(n);
};

/** Encode execution headers through Amsterdam (Geth v1.17.7 field order). */
export function encodeHeader(block) {
  const required = ['parentHash','sha3Uncles','miner','stateRoot','transactionsRoot','receiptsRoot',
    'logsBloom','difficulty','number','gasLimit','gasUsed','timestamp','extraData','mixHash','nonce'];
  for (const key of required) if (block[key] == null) throw new Error(`RPC omitted header field ${key}.`);
  const numbers = new Set(['difficulty','number','gasLimit','gasUsed','timestamp','baseFeePerGas','blobGasUsed','excessBlobGas','slotNumber']);
  const fields = required.map(key => numbers.has(key) ? integer(block[key]) : block[key]);
  let missing = false;
  for (const key of ['baseFeePerGas','withdrawalsRoot','blobGasUsed','excessBlobGas','parentBeaconBlockRoot','requestsHash','blockAccessListHash','slotNumber']) {
    if (block[key] == null) { missing = true; continue; }
    if (missing) throw new Error(`Incomplete fork header before ${key}.`);
    fields.push(numbers.has(key) ? integer(block[key]) : block[key]);
  }
  const encoded = encodeRlp(fields);
  if (!block.hash || keccak256(encoded).toLowerCase() !== block.hash.toLowerCase()) {
    throw new Error('RPC header does not reproduce the block hash. No evidence will be submitted.');
  }
  return encoded;
}

/** Find the unique adjacent feed pair bracketing the deadline; the contract verifies it again. */
export async function findPriceRound(feed, startRound, endsAt) {
  const latest = await feed.latestRoundData();
  let low = BigInt(startRound), high = BigInt(latest[0]);
  const end = BigInt(endsAt);
  if (high >> 64n !== low >> 64n) throw new Error('Feed phase changed. This market may require a timeout refund.');
  if (BigInt(latest[3]) <= end) throw new Error('Waiting for the first feed observation after expiry.');
  const first = await feed.getRoundData(low);
  if (BigInt(first[3]) > end) throw new Error('Opening round is after expiry.');
  let steps = 0;
  while (low < high) {
    if (++steps > 80) throw new Error('Feed search exceeded its bound.');
    const mid = (low + high + 1n) / 2n;
    const round = await feed.getRoundData(mid);
    if (BigInt(round[0]) !== mid || BigInt(round[3]) === 0n) throw new Error('Feed history is incomplete.');
    if (BigInt(round[3]) <= end) low = mid;
    else high = mid - 1n;
  }
  const [before, after] = await Promise.all([feed.getRoundData(low), feed.getRoundData(low + 1n)]);
  if (BigInt(before[3]) > end || BigInt(after[3]) <= end) throw new Error('Could not prove the expiry price.');
  return low;
}

/** Find the first execution block at or after a fixed timestamp, not the block at keeper execution. */
export async function findNativeHeaders(provider, market) {
  const latest = await provider.send('eth_getBlockByNumber', ['latest', false]);
  const height = BigInt(latest.number), end = BigInt(market.endsAt);
  if (BigInt(latest.timestamp) < end) throw new Error('The observation window is still running.');
  let low = BigInt(market.startBlock), high = height;
  let steps = 0;
  const getBlock = n => provider.send('eth_getBlockByNumber', [toBeHex(n), false]);
  while (low < high) {
    if (++steps > 64) throw new Error('Block search exceeded its bound.');
    const mid = (low + high) / 2n;
    const b = await getBlock(mid);
    if (!b) throw new Error('RPC has no block history for this market.');
    if (BigInt(b.timestamp) >= end) high = mid;
    else low = mid + 1n;
  }
  if (height <= low) throw new Error('Waiting for one confirmation of the boundary block.');
  // One block of margin: the submission itself must still see the hash.
  if (height - low >= 256n) throw new Error('The block-header proof window has elapsed; refund is available 48h after expiry.');
  const [parent, target] = await Promise.all([getBlock(low - 1n), getBlock(low)]);
  if (!parent || !target || BigInt(parent.timestamp) >= end || BigInt(target.timestamp) < end) {
    throw new Error('Invalid timestamp boundary in RPC history.');
  }
  return [encodeHeader(parent), encodeHeader(target)];
}

export async function settlementAction(contract, provider, market, now) {
  if (BigInt(now) < BigInt(market.endsAt)) throw new Error('The observation window has not ended.');
  if (BigInt(now) >= BigInt(market.endsAt) + 172800n) return { method: 'expire', args: [market.id] };
  const kind = template(market).kind;
  if ([0,1,2,7,8].includes(kind)) return { method: 'settleSqueek', args: [market.id] };
  if (kind === 3 || kind === 4) {
    const address = kind === 3 ? await contract.ethFeed() : await contract.btcFeed();
    const feed = new Contract(address, FEED_ABI, provider);
    const round = await findPriceRound(feed, market.startRound, market.endsAt);
    return { method: 'settlePrice', args: [market.id, round] };
  }
  return { method: 'settleNative', args: [market.id, ...await findNativeHeaders(provider, market)] };
}
