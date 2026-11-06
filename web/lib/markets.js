import { formatEther, parseEther } from '../vendor/ethers-6.15.0.min.js';

export const CHAIN_ID = 11155111;
export const CORE = '0x74665dAecA35A2303e767E76a2FF1FB6F93e119f';
export const EXPLORER = 'https://sepolia.etherscan.io';
export const STATUS = ['Scheduled', 'Open', 'Awaiting settlement', 'Resolved', 'Refunded'];
export const TEMPLATES = [
  { category: 'Squeek', icon: 'hamster', horizon: '6h', metric: 'Squeek blocks', strike: 100n, kind: 0 },
  { category: 'Squeek', icon: 'hamster', horizon: '24h', metric: 'Squeek blocks', strike: 950n, kind: 0 },
  { category: 'Squeek', icon: 'hamster', horizon: '7d', metric: 'Squeek blocks', strike: 6700n, kind: 0 },
  { category: 'Squeek', icon: 'run', horizon: '24h', metric: 'Active-round streak', strike: 7200n, kind: 1 },
  { category: 'Squeek', icon: 'sun', horizon: '24h', metric: 'Morning vs evening', strike: 0n, kind: 2 },
  { category: 'Crypto', icon: 'eth', horizon: '24h', metric: 'ETH / USD', strike: null, kind: 3 },
  { category: 'Crypto', icon: 'eth', horizon: '7d', metric: 'ETH / USD', strike: null, kind: 3 },
  { category: 'Crypto', icon: 'btc', horizon: '24h', metric: 'BTC / USD', strike: null, kind: 4 },
  { category: 'Network', icon: 'gas', horizon: '24h', metric: 'Sepolia base fee', strike: null, kind: 5 },
  { category: 'Network', icon: 'blocks', horizon: '24h', metric: 'Sepolia blocks', strike: 7000n, kind: 6 },
  { category: 'Squeek', icon: 'activity', horizon: '24h', metric: 'Wheel activity', strike: 11000n, kind: 7 },
  { category: 'Squeek', icon: 'activity', horizon: '24h', metric: 'Active rounds', strike: 24n, kind: 8 },
  { category: 'Crypto', icon: 'btc', horizon: '7d', metric: 'BTC / USD', strike: null, kind: 4 },
  { category: 'Network', icon: 'blocks', horizon: '6h', metric: 'Sepolia blocks', strike: 1750n, kind: 6 },
];

export function template(m) { return TEMPLATES[Number(m.templateId)]; }
export function money(x) { return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 2 }).format(Number(x) / 1e8); }
export function ether(x, places = 4) {
  const s = formatEther(x ?? 0n);
  const [whole, fraction = ''] = s.split('.');
  const trimmed = fraction.slice(0, places).replace(/0+$/, '');
  return whole + (trimmed ? '.' + trimmed : '');
}
export function shortAddress(x) { return `${x.slice(0, 6)}…${x.slice(-4)}`; }
/** Exact gas amounts: Sepolia base fees are often a few wei, which a gwei-only format would print as 0. */
export function gasAmount(wei) {
  const n = BigInt(wei);
  if (n < 1_000_000n) return `${n.toLocaleString('en-US')} wei`;
  return `${(Number(n) / 1e9).toLocaleString('en-US', { maximumFractionDigits: 6 })} gwei`;
}
/** Seconds after `endsAt` during which the contract accepts evidence; afterwards only `expire`. */
export function grace(m) { const k = template(m).kind; return k === 5 || k === 6 ? 86400n : 172800n; }
export function question(m) {
  const t = template(m), s = Number(m.status) === 0 ? t.strike : m.strike ?? t.strike;
  if (t.kind === 0) return `More than ${s.toLocaleString()} Squeek blocks in ${t.horizon}?`;
  if (t.kind === 1) return `An active-round streak longer than ${Number(s) / 60} minutes?`;
  if (t.kind === 2) return 'Will the morning be more active than the evening?';
  if (t.kind === 3 || t.kind === 4) return `${t.kind === 3 ? 'ETH' : 'BTC'} above ${s === null || Number(m.status) === 0 ? 'its opening price' : money(s)} in ${t.horizon}?`;
  if (t.kind === 5) return `Sepolia base fee above ${s === null || Number(m.status) === 0 ? 'its opening level' : gasAmount(s)} in 24h?`;
  if (t.kind === 6) return `More than ${s.toLocaleString()} Sepolia blocks in ${t.horizon}?`;
  if (t.kind === 7) return `More than ${s.toLocaleString()} wheel passages in 24h?`;
  return `More than ${s.toLocaleString()} active rounds in 24h?`;
}
export function labels(m) { return template(m).kind === 2 ? ['Evening / tie', 'Morning'] : ['Under / equal', 'Over']; }
export function poolOdds(m) {
  const total = BigInt(m.noPool ?? 0) + BigInt(m.yesPool ?? 0);
  const yes = total ? Number(BigInt(m.yesPool) * 10000n / total) / 100 : 50;
  return [100 - yes, yes];
}
export function timeLeft(time, now) {
  const seconds = Math.max(0, Number(time) - now);
  if (!seconds) return 'due now';
  if (seconds >= 86400) return `${Math.floor(seconds / 86400)}d ${Math.floor(seconds % 86400 / 3600)}h`;
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
  return `${Math.max(1, Math.ceil(seconds / 60))}m`;
}
export function canBet(m, now) { return Number(m.status) === 1 && Number(m.closesAt) > now; }
export function quote(m, side, input) {
  if (!/^(?:\d+)(?:\.\d{0,18})?$/.test(input)) throw new Error('Enter an ETH amount with at most 18 decimals.');
  const gross = parseEther(input);
  if (gross < parseEther('0.001')) throw new Error('The minimum bet is 0.001 ETH.');
  if (gross > parseEther('100')) throw new Error('The maximum bet is 100 ETH.');
  const fee = gross / 100n, net = gross - fee;
  const samePool = BigInt(side === 1 ? m.yesPool : m.noPool);
  const total = BigInt(m.yesPool) + BigInt(m.noPool);
  if (total + net > parseEther('1000000')) throw new Error('This market has reached its pool limit.');
  return { gross, fee, net, payout: net * (total + net) / (samePool + net) };
}
export function entitlement(m, p) {
  if (p.paid) return 0n;
  if (Number(m.status) === 4) return p.noStake + p.yesStake;
  if (Number(m.status) !== 3) return 0n;
  const pool = Number(m.winner) === 1 ? m.yesPool : m.noPool;
  return pool === 0n ? 0n : (Number(m.winner) === 1 ? p.yesStake : p.noStake) * (m.yesPool + m.noPool) / pool;
}
export function rules(m) {
  const t = template(m);
  let detail;
  if (t.kind === 0) detail = 'Completed Squeek blocks are the difference between floored cumulative block units at the two certified round endpoints. Only full ten-minute rounds in the stated window count.';
  if (t.kind === 1) detail = 'A run is consecutive certified ten-minute rounds with nonzero work. This measures an active-round streak; it cannot prove uninterrupted physical running within each round.';
  if (t.kind === 2) detail = 'Compares accepted wheel passages in rounds starting 06:00–12:00 UTC against 18:00–24:00 UTC on the next full day. A tie belongs to Evening / tie.';
  if (t.kind === 3 || t.kind === 4) detail = 'Uses the last Chainlink USD observation at or before expiry, proven by its immediate successor after expiry. Both observations must be within two hours of expiry and in the opening feed phase. The opening price is captured when the market opens.';
  if (t.kind === 5) detail = 'Uses the base fee of the first Sepolia execution block at or after expiry, authenticated against the chain’s block hash. This is Sepolia gas, not Ethereum mainnet gas or a wallet’s priority fee.';
  if (t.kind === 6) detail = 'Counts Sepolia execution blocks from the opening block (included) to the first block at or after expiry (excluded). Both expiry headers are authenticated against the chain’s block hash.';
  if (t.kind === 7) detail = 'Counts accepted wheel-magnet passages by subtracting certified cumulative work at the two endpoints.';
  if (t.kind === 8) detail = 'Counts certified ten-minute rounds with nonzero wheel work in the stated 24-hour window. Certified omitted rounds are inactive; uncertified rounds are unknown.';
  const hours = Number(grace(m)) / 3600;
  const cutoff = t.category === 'Squeek' ? 'Betting closes when the observation window starts, before any of its rounds can be certified; a new market for the next window opens at that moment.' : 'Betting closes halfway through the observation window; a new market opens at that moment.';
  return `${detail} Over / Morning wins only on a strict greater-than result. Otherwise Under / equal wins. A 1% fee is retained on every bet. Payouts use final net pool shares. Missing evidence after ${hours} hours or a winning side with no stake refunds net stakes; the fee remains retained. ${cutoff}`;
}
export function previewMarkets() {
  return TEMPLATES.map((t, i) => ({ id: null, templateId: i, status: 0, strike: t.strike, noPool: 0n, yesPool: 0n, volume: 0n, startsAt: 0n, closesAt: 0n, endsAt: 0n }));
}
export function escapeHtml(s) { return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]); }
