import './styles.css';
import { BrowserProvider, Contract, JsonRpcProvider, isAddress, keccak256, getAddress } from 'ethers';
import { CHAIN_ID, CORE, EXPLORER, STATUS, template, question, labels, poolOdds, ether, money, gasAmount,
  shortAddress, timeLeft, canBet, quote, entitlement, rules, previewMarkets, grace, escapeHtml as esc,
  type MarketLike, type PositionLike } from '../lib/markets.js';
import { settlementAction } from '../lib/proofs.js';
import { icon } from '../lib/icons.js';
import config from '../config.json';
import predictAbi from '../abi/SqueekPredict.json';
import network from './network.json';
import markUrl from './mark.svg';
import { type Eip1193, injectedWallets, coinbaseProvider, onWalletsChanged, OPEN_IN, isMobileBrowser, iconUrl,
  rememberWallet, rememberedWallet } from './wallets';

type Market = MarketLike & { id: bigint };
type Preview = { ok: true; startsAt: bigint; closesAt: bigint; endsAt: bigint; strike: bigint } | { ok: false; reason: string };

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const dialog = (id: string) => $<HTMLDialogElement>(id);
const CHAIN_HEX = '0x' + CHAIN_ID.toString(16);
const SQUEEK_ERRORS = ['error CorePaused()', 'error CoreStale(uint256 certifiedAt)', 'error NotCertified(uint64 requiredRound,uint64 certifiedRound)'];

const state = {
  markets: previewMarkets() as Market[], previews: new Map<string, Preview>(), ready: false, online: false,
  account: null as string | null, wallet: null as Eip1193 | null, walletId: null as string | null, walletChain: 0,
  filter: 'All', search: '', sort: 'default', selected: null as Market | null, side: 1, busy: false, refreshing: false,
  positionRows: [] as { m: Market; p: PositionLike }[], positionCount: 0, positionOffset: 0, generation: 0, lastSource: 0,
  chainTime: 0, observedAt: 0, squeekHealthy: null as boolean | null, balance: null as bigint | null,
  provider: null as JsonRpcProvider | null, baseFee: null as bigint | null, contract: null as Contract | null, rpcUrl: '', claimId: 0n,
};
const now = () => state.chainTime ? state.chainTime + Math.floor((performance.now() - state.observedAt) / 1000) : Math.floor(Date.now() / 1000);
const date = (t: bigint | number) => new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' }).format(Number(t) * 1000) + ' UTC';
const marketObject = (m: any, id: bigint): Market => ({ ...m.toObject(), id });
/** Card and picker labels drop the tie wording; the rules dialog states that ties go to the second side. */
const short = (label: string) => label.split(' / ')[0];
const pct = (x: number) => `${x.toFixed(x % 1 ? 1 : 0)}%`;

/** A scheduled market opens inside the first bet, so it is bettable whenever the contract's own previewOpen succeeds. */
function preview(m: Market): Preview | undefined { return state.previews.get(String(m.id)); }
function bettable(m: Market) {
  if (!state.ready || !state.online || !m.id) return false;
  if (template(m).category === 'Squeek' && state.squeekHealthy === false) return false;
  if (Number(m.status) === 0) return preview(m)?.ok === true;
  return canBet(m, now());
}
/** Terms to show: an open market's own, or the terms previewOpen reports for a scheduled one. */
function view(m: Market): Market {
  const p = preview(m);
  return Number(m.status) === 0 && p?.ok ? { ...m, startsAt: p.startsAt, closesAt: p.closesAt, endsAt: p.endsAt } : m;
}
function referenceLine(m: Market) {
  const p = preview(m), kind = template(m).kind;
  if (Number(m.status) !== 0 || !p?.ok) return '';
  if (kind === 3 || kind === 4) return `Now ${money(p.strike)}, line set by the first bet`;
  // previewOpen runs as an eth_call, where block.basefee reads 0, so the latest block header is the honest reference.
  if (kind === 5 && state.baseFee != null) return `Now ${gasAmount(state.baseFee)}, line set by the first bet`;
  return '';
}
function closeText(m: Market) {
  const v = view(m), status = Number(m.status);
  if (!state.ready) return 'Loading';
  if (status === 0) {
    const p = preview(m);
    if (p?.ok) return `Closes in ${timeLeft(v.closesAt, now())}`;
    return p && !p.ok ? p.reason : 'Checking';
  }
  if (now() < Number(m.closesAt)) return `Closes in ${timeLeft(m.closesAt, now())}`;
  if (now() < Number(m.endsAt)) return `Resolves in ${timeLeft(m.endsAt, now())}`;
  return 'Awaiting upkeep';
}

function toast(message: string, error = false, hash: string | null = null) {
  const el = document.createElement('div'); el.className = `toast${error ? ' error' : ''}`;
  const p = document.createElement('span'); p.textContent = message; el.append(p);
  if (hash && /^0x[\da-f]{64}$/i.test(hash)) {
    const a = document.createElement('a'); a.href = `${EXPLORER}/tx/${hash}`; a.target = '_blank';
    a.rel = 'noopener noreferrer'; a.textContent = 'View transaction ↗'; el.append(a);
  }
  $('toasts').append(el); setTimeout(() => el.remove(), error ? 16000 : 12000);
}

const REASONS: Record<string, string> = { BettingClosed: 'Betting has closed for this market.', InvalidAmount: 'Use 0.001 to 100 ETH per bet.',
  NotCertified: 'SqueekCore has not certified this window yet.', CorePaused: 'Squeek reporting is paused. New stakes are disabled.',
  CoreStale: 'Squeek certification is more than six hours behind. New stakes are disabled.', StalePrice: 'The price feed is too old. Try again after it updates.',
  InvalidPrice: 'The feed has no valid price right now.', ResolutionExpired: 'The evidence deadline passed. Use the refund action.',
  NothingToClaim: 'There is no unpaid amount for this wallet.', InvalidStatus: 'This market has already changed state. Refresh and try again.',
  UnprovenHeader: 'The header is outside the proof window or could not be authenticated.', TransferFailed: 'The recipient could not receive ETH.' };
function revertName(error: any): string | null {
  if (error?.revert?.name) return error.revert.name;
  const data = error?.data ?? error?.info?.error?.data?.data ?? error?.info?.error?.data;
  if (typeof data === 'string' && state.contract) { try { return state.contract.interface.parseError(data)?.name ?? null; } catch { /* unknown */ } }
  return null;
}
function errorText(error: any): string {
  if (error?.code === 4001 || error?.code === 'ACTION_REJECTED') return 'The wallet request was declined.';
  const name = revertName(error);
  if (name) return REASONS[name] || `The contract rejected the request: ${name}.`;
  return error?.shortMessage || error?.message || 'The request did not complete. Please try again.';
}

function categoryCounts() {
  for (const c of ['All', 'Crypto', 'Network', 'Squeek']) {
    $(`count-${c}`).textContent = String(state.markets.filter(m => c === 'All' || template(m).category === c).length);
  }
}

function renderMarkets() {
  const grid = $('market-grid');
  const focused = document.activeElement as HTMLElement | null;
  const restore = focused && grid.contains(focused) ? (focused.dataset.bet
    ? `[data-bet="${focused.dataset.bet}"][data-side="${focused.dataset.side}"]` : focused.dataset.rules ? `[data-rules="${focused.dataset.rules}"]` : null) : null;
  const term = state.search.toLowerCase();
  const markets = state.markets.filter(m => (state.filter === 'All' || template(m).category === state.filter)
    && (question(m) + ' ' + template(m).metric).toLowerCase().includes(term));
  if (state.sort === 'default') markets.sort((a, b) => Number(bettable(b)) - Number(bettable(a)));
  if (state.sort === 'volume') markets.sort((a, b) => Number(b.volume - a.volume));
  if (state.sort === 'ending') markets.sort((a, b) => (Number(view(a).closesAt) || Infinity) - (Number(view(b).closesAt) || Infinity));
  categoryCounts();
  $('no-results').hidden = markets.length > 0;
  grid.innerHTML = markets.map(m => {
    const t = template(m), [no, yes] = poolOdds(m), [noLabel, yesLabel] = labels(m);
    const available = bettable(m) && !state.busy;
    const live = bettable(m);
    const categoryIcon = t.icon === 'hamster' ? `<img src="${markUrl}" alt="" width="24" height="24">` : icon(t.icon);
    const ref = referenceLine(m);
    const q = esc(question(m));
    const key = String(m.templateId);
    return `<article class="card${live ? '' : ' is-paused'}">
      <div class="card-head">
        <span class="cat-icon cat-${t.category.toLowerCase()}" aria-hidden="true">${categoryIcon}</span>
        <h3 class="card-q">${q}</h3>
        <div class="chance"><strong>${pct(yes)}</strong><span>${esc(yesLabel)}</span></div>
      </div>
      <div class="meter" role="img" aria-label="${esc(yesLabel)} ${pct(yes)}, ${esc(noLabel)} ${pct(no)}"><span style="width:${yes}%"></span></div>
      <p class="card-meta">${esc(t.metric)} · ${t.horizon} window${ref ? ` · ${esc(ref)}` : ''}</p>
      <div class="bet-row">
        <button class="bet yes" type="button" data-bet="${key}" data-side="1" ${available ? '' : 'disabled'} aria-label="Bet ${esc(yesLabel)} at ${pct(yes)}: ${q}"><span>${esc(short(yesLabel))}</span><strong>${pct(yes)}</strong></button>
        <button class="bet no" type="button" data-bet="${key}" data-side="0" ${available ? '' : 'disabled'} aria-label="Bet ${esc(noLabel)} at ${pct(no)}: ${q}"><span>${esc(short(noLabel))}</span><strong>${pct(no)}</strong></button>
      </div>
      <div class="card-foot">
        <span class="vol"><span class="num">${ether(m.volume)}</span> ETH vol</span>
        <span class="time${live ? '' : ' paused'}">${icon(live ? 'clock' : 'pause')}${esc(closeText(m))}</span>
        <button class="rules-link" type="button" data-rules="${key}" aria-label="Rules for: ${q}">Rules</button>
      </div>
    </article>`;
  }).join('');
  grid.querySelectorAll<HTMLButtonElement>('[data-bet]').forEach(b => b.addEventListener('click', () => openBet(Number(b.dataset.bet), Number(b.dataset.side))));
  grid.querySelectorAll<HTMLButtonElement>('[data-rules]').forEach(b => b.addEventListener('click', () => openRules(Number(b.dataset.rules))));
  if (restore) grid.querySelector<HTMLElement>(restore)?.focus({ preventScroll: true });
}

const bySlot = (slot: number) => state.markets.find(m => Number(m.templateId) === slot)!;

function openRules(slot: number) {
  const m = bySlot(slot), v = view(m);
  $('rules-question').textContent = question(m); $('rules-body').textContent = rules(m);
  const scheduled = Number(m.status) === 0;
  $('rules-times').innerHTML = Number(v.startsAt)
    ? ([['Betting closes', v.closesAt], ['Observation starts', v.startsAt], ['Observation ends', v.endsAt], ['Refund deadline', BigInt(v.endsAt) + grace(m)]] as [string, bigint][])
      .map(([title, t]) => `<div><dt>${title}${scheduled ? ' (if opened now)' : ''}</dt><dd>${date(t)}</dd></div>`).join('')
    : '<div><dt>Window</dt><dd>Assigned when this market opens</dd></div>';
  dialog('rules-dialog').showModal();
}

function openBet(slot: number, side: number) {
  const m = bySlot(slot);
  if (!bettable(m)) return;
  state.selected = m; state.side = side;
  $('bet-question').textContent = question(m);
  $('bet-note').textContent = [referenceLine(m), 'The payout is an estimate at current pool sizes and changes as others bet. Stakes stay locked until settlement.'].filter(Boolean).join(' ');
  $('bet-progress').textContent = ''; ($('bet-amount') as HTMLInputElement).value = '0.01';
  renderSides(); updateQuote(); dialog('bet-dialog').showModal(); $('bet-amount').focus();
  updateWalletBalance();
}

function renderSides() {
  const m = state.selected; if (!m) return;
  const odds = poolOdds(m), names = labels(m);
  $('side-picker').innerHTML = [1, 0].map(side => `<button type="button" data-pick-side="${side}" class="pick ${side === 1 ? 'yes' : 'no'}" aria-pressed="${side === state.side}" aria-label="${esc(names[side])} ${pct(odds[side])}"><span>${esc(short(names[side]))}</span><strong>${pct(odds[side])}</strong></button>`).join('');
  $('side-picker').querySelectorAll<HTMLButtonElement>('[data-pick-side]').forEach(b => b.addEventListener('click', () => { state.side = Number(b.dataset.pickSide); renderSides(); updateQuote(); }));
}

function wrongChain() { return !!state.wallet && state.walletChain !== CHAIN_ID; }

function updateQuote() {
  if (!state.selected) return;
  const button = $<HTMLButtonElement>('submit-bet'); button.disabled = state.busy;
  button.textContent = state.busy ? 'Transaction in progress…' : !state.account ? 'Connect wallet to bet'
    : wrongChain() ? 'Switch to Sepolia and bet' : `Bet ${short(labels(state.selected)[state.side])}`;
  try {
    if (!state.online) throw new Error('Network reads are unavailable. Reconnect before betting.');
    if (!bettable(state.selected)) throw new Error('Betting is not available for this market right now.');
    const q = quote(state.selected, state.side, ($('bet-amount') as HTMLInputElement).value.trim());
    $('quote-fee').textContent = `${ether(q.fee, 8)} ETH`;
    $('quote-net').textContent = `${ether(q.net, 8)} ETH`;
    $('quote-return').textContent = `${ether(q.payout, 6)} ETH`;
    $('quote-error').textContent = '';
    if (state.balance != null && state.account && q.gross >= state.balance) throw new Error('Keep enough Sepolia ETH for the bet and gas.');
  } catch (error) {
    button.disabled = true; $('quote-error').textContent = errorText(error);
  }
}

async function updateWalletBalance() {
  const account = state.account;
  $('wallet-balance').textContent = account ? 'Checking balance…' : '';
  state.balance = null;
  if (!account || !state.provider) return;
  try {
    const balance = await state.provider.getBalance(account); if (account !== state.account) return;
    state.balance = balance; $('wallet-balance').textContent = `${ether(balance)} ETH available`; updateQuote();
  } catch { $('wallet-balance').textContent = 'Balance unavailable'; }
}

/* ---------- Wallet sheet ---------- */

function walletRow(label: string, img: string | undefined, onClick?: () => Promise<void>, href?: string) {
  const el = document.createElement(href ? 'a' : 'button') as HTMLButtonElement & HTMLAnchorElement;
  el.className = 'wallet-row';
  if (href) { el.href = href; el.rel = 'noopener'; } else el.type = 'button';
  const ic = document.createElement('span'); ic.className = 'wallet-ic';
  if (img) { const i = document.createElement('img'); i.src = img; i.width = 28; i.height = 28; i.alt = ''; ic.append(i); }
  const name = document.createElement('span'); name.textContent = label;
  el.append(ic, name);
  if (onClick) el.addEventListener('click', async () => {
    const rows = $('wallet-options').querySelectorAll<HTMLButtonElement>('button.wallet-row');
    rows.forEach(r => { r.disabled = true; }); name.textContent = `${label} · opening…`; $('wallet-error').textContent = '';
    try { await onClick(); dialog('wallet-dialog').close(); }
    catch (e) { $('wallet-error').textContent = errorText(e); }
    finally { rows.forEach(r => { r.disabled = false; }); name.textContent = label; }
  });
  return el;
}

function renderWalletSheet() {
  const box = $('wallet-options'); box.replaceChildren();
  if (state.account) {
    $('wallet-title').textContent = 'Your wallet';
    const info = document.createElement('p'); info.className = 'wallet-account';
    info.innerHTML = `<span class="mono">${esc(shortAddress(state.account))}</span><span class="muted">${wrongChain() ? 'Wrong network' : 'Connected to Sepolia'}</span>`;
    box.append(info);
    if (wrongChain()) box.append(walletRow('Switch to Sepolia', undefined, () => switchChain()));
    const out = document.createElement('button'); out.type = 'button'; out.className = 'btn secondary wide'; out.textContent = 'Disconnect';
    out.addEventListener('click', () => { disconnect(); dialog('wallet-dialog').close(); });
    box.append(out); return;
  }
  $('wallet-title').textContent = 'Connect a wallet';
  const mobile = isMobileBrowser();
  if (mobile) OPEN_IN.forEach(w => box.append(walletRow(`Open in ${w.name}`, iconUrl(w.id), undefined, w.href(location.href))));
  else injectedWallets().forEach(w => box.append(walletRow(w.name, w.icon, () => connectWallet(w.provider, w.id))));
  box.append(walletRow(mobile ? 'Coinbase Smart Wallet' : 'Coinbase Wallet', iconUrl('coinbase'), async () => connectWallet(await coinbaseProvider(CHAIN_ID), 'coinbase')));
  if (!mobile && !injectedWallets().length) {
    const p = document.createElement('p'); p.className = 'muted small';
    p.textContent = 'No browser wallet was found. Install one and reload, or use Coinbase Smart Wallet with a passkey.';
    box.append(p);
  }
}

function walletPicker() {
  if (state.busy) return;
  $('wallet-error').textContent = '';
  renderWalletSheet();
  dialog('wallet-dialog').showModal();
}
onWalletsChanged(() => { if (dialog('wallet-dialog').open && !state.account) renderWalletSheet(); });

function updateConnectButton() {
  const b = $<HTMLButtonElement>('connect');
  b.textContent = !state.account ? 'Connect wallet' : wrongChain() ? 'Switch to Sepolia' : shortAddress(state.account);
  b.classList.toggle('primary', !state.account || wrongChain());
  b.classList.toggle('secondary', !!state.account && !wrongChain());
  b.title = state.account || 'Connect an Ethereum wallet';
}

async function connectWallet(provider: Eip1193, id: string, silent = false) {
  const accounts: string[] = await provider.request({ method: silent ? 'eth_accounts' : 'eth_requestAccounts' });
  if (!accounts?.[0] || !isAddress(accounts[0])) { if (silent) return; throw new Error('The wallet did not provide an account.'); }
  if (state.wallet !== provider) {
    state.wallet?.removeListener?.('accountsChanged', accountChanged); state.wallet?.removeListener?.('chainChanged', chainChanged);
    state.wallet = provider;
    provider.on?.('accountsChanged', accountChanged); provider.on?.('chainChanged', chainChanged);
  }
  state.walletId = id; rememberWallet(id);
  await checkWalletChain();
  accountChanged(accounts);
}

function disconnect() {
  state.wallet?.removeListener?.('accountsChanged', accountChanged); state.wallet?.removeListener?.('chainChanged', chainChanged);
  if (state.walletId === 'coinbase') (state.wallet as any)?.disconnect?.().catch?.(() => {});
  state.wallet = null; state.walletId = null; rememberWallet(null); accountChanged([]);
}

function accountChanged(accounts: string[]) {
  const previous = state.account;
  state.account = accounts?.[0] && isAddress(accounts[0]) ? getAddress(accounts[0]) : null;
  if (previous && previous !== state.account) { dialog('bet-dialog').close(); dialog('claim-dialog').close(); }
  if (!state.account && state.wallet) { state.wallet = null; rememberWallet(null); }
  ++state.generation; state.balance = null; state.positionRows = []; state.positionOffset = 0;
  updateConnectButton(); renderPositions(); updateWalletBalance(); updateQuote();
  if (state.account && state.ready) loadPositions(true).catch(e => toast(errorText(e), true));
}
function chainChanged() { checkWalletChain().catch(e => toast(errorText(e), true)); }
async function checkWalletChain() {
  if (!state.wallet) return;
  state.walletChain = Number(BigInt(await state.wallet.request({ method: 'eth_chainId' })));
  $('network-notice').hidden = !wrongChain() || !state.account;
  $('network-notice').textContent = 'Your wallet is on another network. Betting will ask it to switch to Sepolia.';
  updateConnectButton(); updateQuote();
}

async function switchChain() {
  if (!state.wallet) return;
  try { await state.wallet.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN_HEX }] }); }
  catch (e: any) {
    if (e?.code !== 4902 && e?.data?.originalError?.code !== 4902) throw e;
    await state.wallet.request({ method: 'wallet_addEthereumChain', params: [network.walletAddChain] });
    await state.wallet.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN_HEX }] });
  }
  await checkWalletChain();
  if (wrongChain()) throw new Error('Switch the wallet to Sepolia to continue.');
}

/* ---------- Transactions ---------- */

async function transaction(label: string, method: string, args: unknown[], overrides: Record<string, unknown> = {}) {
  if (!state.account || !state.wallet) { walletPicker(); return false; }
  if (!state.ready || !state.online || !state.contract) { toast('A verified Sepolia deployment and live RPC connection are required.', true); return false; }
  if (state.busy) return false;
  state.busy = true; updateQuote(); $<HTMLButtonElement>('upkeep').disabled = true; renderMarkets();
  const account = state.account, contract = state.contract;
  let hash: string | undefined;
  try {
    await checkWalletChain();
    if (wrongChain()) await switchChain();
    const browser = new BrowserProvider(state.wallet as any, 'any');
    const signer = await browser.getSigner();
    if ((await signer.getAddress()).toLowerCase() !== account.toLowerCase() || account !== state.account) throw new Error('The wallet account changed. Review the transaction again.');
    const fn = contract.getFunction(method);
    await fn.staticCall(...args, { ...overrides, from: account });
    const gas = await fn.estimateGas(...args, { ...overrides, from: account });
    const request = await fn.populateTransaction(...args, overrides);
    $('bet-progress').textContent = 'Confirm the transaction in your wallet.';
    const tx = await signer.sendTransaction({ ...request, chainId: CHAIN_ID, gasLimit: gas * 125n / 100n });
    hash = tx.hash; toast(`${label} submitted. Waiting for confirmation.`, false, hash);
    $('bet-progress').textContent = 'Submitted. Waiting for confirmation on Sepolia…';
    let receipt: any;
    try { receipt = await tx.wait(1, 180000); }
    catch (e: any) { if (e.code === 'TRANSACTION_REPLACED' && !e.cancelled && e.receipt) receipt = e.receipt; else throw e; }
    if (!receipt || Number(receipt.status) !== 1) throw new Error('The transaction reverted on-chain.');
    toast(`${label} confirmed.`, false, receipt.hash || hash); $('bet-progress').textContent = 'Confirmed on Sepolia.';
    state.busy = false;
    await refresh(); await loadPositions(true); await updateWalletBalance();
    return true;
  } catch (e: any) {
    const message = hash && e?.code === 'TIMEOUT' ? 'Submitted; confirmation is still pending. Check the explorer before retrying.' : errorText(e);
    toast(message, true, hash ?? null); $('bet-progress').textContent = message; return false;
  } finally {
    state.busy = false; updateQuote(); renderMarkets(); renderPositions();
    $<HTMLButtonElement>('upkeep').disabled = !state.ready || !state.online;
  }
}

/* ---------- Positions ---------- */

async function loadPositions(reset = false) {
  const contract = state.contract;
  if (!state.account || !state.ready || !contract) { renderPositions(); return; }
  const generation = state.generation, account = state.account;
  const offset = reset ? 0 : state.positionOffset;
  const count = Number(await contract.userMarketCount(account));
  const ids: bigint[] = Array.from(await contract.positionIds(account, offset, 50));
  const markets = ids.length ? await contract.getMarkets(ids) : [];
  const rows: { m: Market; p: PositionLike }[] = [];
  for (let i = 0; i < ids.length; i += 5) {
    rows.push(...await Promise.all(ids.slice(i, i + 5).map((id, j) => contract.getPosition(id, account).then((p: any) => ({ m: marketObject(markets[i + j], id), p: p.toObject() as PositionLike })))));
  }
  if (generation !== state.generation) return;
  state.positionRows = reset ? rows : [...state.positionRows, ...rows];
  state.positionOffset = offset + rows.length; state.positionCount = count; renderPositions();
}

function renderPositions() {
  $('positions-connect').hidden = !!state.account;
  $('positions-content').hidden = !state.account;
  if (!state.account) return;
  $('position-wallet').textContent = shortAddress(state.account);
  let stake = 0n, claim = 0n;
  $('position-list').innerHTML = state.positionRows.map(({ m, p }) => {
    const net = p.noStake + p.yesStake, available = entitlement(m, p), sides = labels(m), status = Number(m.status);
    stake += net; claim += available;
    const action = p.paid ? '<span class="tag good">Paid</span>'
      : available > 0n ? `<button class="btn primary" type="button" data-claim="${m.id}" ${state.busy ? 'disabled' : ''}>Claim ${ether(available)} ETH</button>`
      : status < 3 && Number(m.endsAt) <= now() && Number(m.status) !== 0 ? `<button class="btn secondary" type="button" data-settle="${m.id}" ${state.busy ? 'disabled' : ''}>${now() >= Number(m.endsAt) + Number(grace(m)) ? 'Refund' : 'Settle'}</button>`
      : status === 3 ? '<span class="muted small">No winning stake</span>' : '<span class="muted small">In progress</span>';
    const sideText = [p.yesStake > 0n ? `${sides[1]} · ${ether(p.yesStake)} ETH` : '', p.noStake > 0n ? `${sides[0]} · ${ether(p.noStake)} ETH` : ''].filter(Boolean).join(' / ');
    return `<article class="position"><div class="position-main"><span class="tag">#${m.id} · ${STATUS[status]}</span><h3>${esc(question(m))}</h3><p class="muted">${esc(sideText)}</p></div><div class="position-cell"><span>Net stake</span><strong>${ether(net)} ETH</strong></div><div class="position-cell"><span>${status >= 3 ? 'Outcome' : 'Resolves'}</span><strong>${status === 4 ? 'Net refund' : status === 3 ? esc(sides[Number(m.winner)]) : date(m.endsAt)}</strong></div><div class="position-action">${action}</div></article>`;
  }).join('') || '<div class="empty-state"><h2>No positions yet</h2><p>Your bets are recorded on-chain and appear here.</p><a class="btn primary" href="#markets">Browse markets</a></div>';
  $('staked-total').textContent = `${ether(stake)} ETH`; $('claim-total').textContent = `${ether(claim)} ETH`;
  $('load-positions').hidden = state.positionOffset >= state.positionCount;
  $('position-list').querySelectorAll<HTMLButtonElement>('[data-claim]').forEach(b => b.addEventListener('click', () => {
    state.claimId = BigInt(b.dataset.claim!);
    ($('claim-recipient') as HTMLInputElement).value = state.account!; $('claim-error').textContent = '';
    dialog('claim-dialog').showModal();
  }));
  $('position-list').querySelectorAll<HTMLButtonElement>('[data-settle]').forEach(b => b.addEventListener('click', async () => {
    if (state.busy || !state.contract || !state.provider) return; b.disabled = true;
    try {
      const row = state.positionRows.find(r => String(r.m.id) === b.dataset.settle)!;
      const action = await settlementAction(state.contract, state.provider, row.m, now());
      await transaction(action.method === 'expire' ? 'Refund' : 'Settlement', action.method, action.args);
    } catch (e) { toast(errorText(e), true); } finally { b.disabled = false; }
  }));
}

/* ---------- Chain reads ---------- */

async function sourceHealth() {
  if (!state.provider || Date.now() - state.lastSource < 60000) return;
  state.lastSource = Date.now();
  const abi = [
    'function state() view returns ((uint64 settledThroughRound,uint64 cumulativeWork,uint96 cumulativeBlockUnits,uint64 blockHeight,uint96 blockProgress,uint32 workPerThousandBlocks,uint256 authorizationNonce,bool paused))',
    'function configuration() view returns ((bytes32 streamId,uint64 genesisTimestamp,uint64 roundDuration,uint64 maxWorkPerRound,uint16 maxRoundsPerBatch,address guardian,address reporter,uint32 initialWorkPerThousandBlocks,uint64 targetBlocksPerActiveRound,uint64 difficultySmoothingRounds,uint96 blockUnitsPerBlock))',
  ];
  try {
    const core = new Contract(CORE, abi, state.provider);
    const [s, c] = await Promise.all([core.state(), core.configuration()]);
    const certifiedAt = c.genesisTimestamp + s.settledThroughRound * c.roundDuration;
    state.squeekHealthy = !s.paused && now() - Number(certifiedAt) <= 21600 && Number(certifiedAt) <= now();
    $('source-notice').hidden = state.squeekHealthy;
    $('source-notice').textContent = `Squeek markets are paused: SqueekCore ${s.paused ? 'reporting is paused' : `is certified only through ${date(certifiedAt)}`}. They reopen when it catches up; other markets are unaffected.`;
  } catch {
    state.squeekHealthy = false;
    $('source-notice').hidden = false;
    $('source-notice').textContent = 'SqueekCore could not be read, so Squeek markets are paused. Crypto and network markets are unaffected.';
  }
  renderMarkets(); updateQuote();
}

async function loadPreviews(blockTag: number) {
  const contract = state.contract!;
  const scheduled = state.markets.filter(m => Number(m.status) === 0);
  const results = await Promise.allSettled(scheduled.map(m => contract.previewOpen(m.id, { blockTag })));
  const next = new Map<string, Preview>();
  results.forEach((r, i) => {
    const id = String(scheduled[i].id);
    if (r.status === 'fulfilled') next.set(id, { ok: true, startsAt: r.value[0], closesAt: r.value[1], endsAt: r.value[2], strike: r.value[3] });
    else {
      const name = revertName(r.reason);
      next.set(id, { ok: false, reason: name === 'CoreStale' || name === 'CorePaused' || name === 'NotCertified' ? 'Paused · waiting for Squeek data'
        : name === 'StalePrice' || name === 'InvalidPrice' ? 'Paused · waiting for price feed' : name ? 'Paused' : 'Unavailable' });
    }
  });
  state.previews = next;
}

async function refresh() {
  if (state.refreshing || !state.provider) return;
  state.refreshing = true;
  try {
    const block = await state.provider.getBlock('latest');
    if (!block) throw new Error('Sepolia RPC returned no latest block.');
    state.chainTime = block.timestamp; state.observedAt = performance.now(); state.baseFee = block.baseFeePerGas;
    if (Date.now() / 1000 - block.timestamp > 180) throw new Error('The Sepolia RPC is serving a stale block.');
    if (state.ready && state.contract) {
      const ids: bigint[] = Array.from(await state.contract.activeMarketIds({ blockTag: block.number }));
      const markets = await state.contract.getMarkets(ids, { blockTag: block.number });
      state.markets = markets.map((m: any, i: number) => marketObject(m, ids[i]));
      await loadPreviews(block.number);
      if (state.selected) state.selected = state.markets.find(m => m.templateId === state.selected!.templateId) ?? state.selected;
    }
    state.online = true;
    if (!state.account) $('network-notice').hidden = true;
    if (state.wallet) checkWalletChain().catch(() => {});
    const open = state.markets.filter(bettable).length;
    $('read-status').innerHTML = `<span class="dot"></span>Live · ${open} of ${state.markets.length} open · block ${block.number.toLocaleString('en-US')}`;
    $<HTMLButtonElement>('upkeep').disabled = !state.ready || state.busy;
    renderMarkets(); if (dialog('bet-dialog').open) renderSides(); updateQuote(); await sourceHealth();
  } catch (e) {
    state.online = false; $<HTMLButtonElement>('upkeep').disabled = true;
    $('read-status').innerHTML = '<span class="dot warning"></span>Sepolia unreachable · retrying';
    renderMarkets(); updateQuote();
    $('network-notice').hidden = false; $('network-notice').textContent = `${errorText(e)} Bets are disabled until the connection returns.`;
  } finally { state.refreshing = false; }
}

function route() {
  const name = ['positions', 'how'].includes(location.hash.slice(1)) ? location.hash.slice(1) : 'markets';
  for (const p of ['markets', 'positions', 'how']) $(p + '-page').hidden = p !== name;
  document.querySelectorAll<HTMLAnchorElement>('[data-nav]').forEach(a => { if (a.dataset.nav === name) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current'); });
  if (name === 'positions' && state.account && state.ready) loadPositions(true).catch(e => toast(errorText(e), true));
}

/** Picks the first public RPC from network.json that answers as Sepolia. */
async function connectRpc(): Promise<JsonRpcProvider> {
  const urls = [config.rpcUrl, ...network.network.rpcUrls.filter(u => u !== config.rpcUrl)];
  for (const url of urls) {
    const provider = new JsonRpcProvider(url, CHAIN_ID, { staticNetwork: true, batchMaxCount: 10 });
    try {
      if (Number(BigInt(await provider.send('eth_chainId', []))) === CHAIN_ID) { state.rpcUrl = url; return provider; }
    } catch { /* try the next RPC */ }
    provider.destroy();
  }
  throw new Error('No Sepolia RPC answered. Check your connection.');
}

async function init() {
  document.querySelectorAll<HTMLElement>('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon!); });
  ($('core-link') as HTMLAnchorElement).href = `${EXPLORER}/address/${CORE}`;
  renderMarkets(); route();
  try {
    if (config.chainId !== CHAIN_ID || !config.contractAddress || !isAddress(config.contractAddress) || !/^0x[\da-f]{64}$/i.test(config.runtimeHash || '')) throw new Error('The website configuration has no verified contract.');
    state.provider = await connectRpc();
    const code = await state.provider.getCode(config.contractAddress);
    if (code === '0x' || keccak256(code).toLowerCase() !== config.runtimeHash!.toLowerCase()) throw new Error('The contract code on Sepolia does not match the verified release.');
    const contract = new Contract(config.contractAddress, [...(predictAbi as any[]), ...SQUEEK_ERRORS], state.provider);
    if (Number(await contract.SLOT_COUNT()) !== 14 || Number(await contract.FEE_BPS()) !== 100) throw new Error('The configured contract is not Squeek Predict.');
    state.contract = contract; state.ready = true;
    const link = $<HTMLAnchorElement>('contract-link'); link.hidden = false; link.href = `${EXPLORER}/address/${config.contractAddress}`;
    await refresh();
    reconnect();
  } catch (e) {
    state.ready = false; state.online = false;
    $('launch-notice').hidden = false; $('launch-notice').textContent = `${errorText(e)} Betting is disabled.`;
    $('read-status').innerHTML = '<span class="dot warning"></span>Unavailable · betting disabled'; renderMarkets();
  }
}

/** Restores the last wallet without a prompt: eth_accounts only answers for an already-authorised site. */
function reconnect() {
  const id = rememberedWallet(); if (!id) return;
  setTimeout(async () => {
    try {
      if (id === 'coinbase') await connectWallet(await coinbaseProvider(CHAIN_ID), id, true);
      else { const w = injectedWallets().find(x => x.id === id); if (w) await connectWallet(w.provider, id, true); }
    } catch { /* stay disconnected */ }
  }, 300);
}

$('connect').addEventListener('click', () => { if (state.account && wrongChain()) switchChain().catch(e => toast(errorText(e), true)); else walletPicker(); });
$('positions-wallet').addEventListener('click', walletPicker);
$('upkeep').addEventListener('click', () => transaction('Market upkeep', 'maintain', []));
document.querySelectorAll<HTMLButtonElement>('[data-close]').forEach(b => b.addEventListener('click', () => dialog(b.dataset.close!).close()));
document.querySelectorAll<HTMLDialogElement>('dialog').forEach(d => d.addEventListener('click', e => { if (e.target === d) d.close(); }));
document.querySelectorAll<HTMLButtonElement>('[data-filter]').forEach(b => b.addEventListener('click', () => {
  state.filter = b.dataset.filter!;
  document.querySelectorAll<HTMLButtonElement>('[data-filter]').forEach(x => x.setAttribute('aria-pressed', String(x === b)));
  renderMarkets();
}));
$('search').addEventListener('input', e => { state.search = (e.target as HTMLInputElement).value; renderMarkets(); });
$('sort').addEventListener('change', e => { state.sort = (e.target as HTMLSelectElement).value; renderMarkets(); });
$('clear-search').addEventListener('click', () => { state.search = ''; ($('search') as HTMLInputElement).value = ''; document.querySelector<HTMLButtonElement>('[data-filter="All"]')!.click(); });
$('bet-amount').addEventListener('input', updateQuote);
document.querySelectorAll<HTMLButtonElement>('[data-amount]').forEach(b => b.addEventListener('click', () => { ($('bet-amount') as HTMLInputElement).value = b.dataset.amount!; updateQuote(); }));
$('bet-form').addEventListener('submit', async e => {
  e.preventDefault(); if (!state.account || !state.selected) { walletPicker(); return; }
  try {
    const q = quote(state.selected, state.side, ($('bet-amount') as HTMLInputElement).value.trim());
    if (await transaction('Bet', 'bet', [state.selected.id, state.side], { value: q.gross })) dialog('bet-dialog').close();
  } catch (error) { $('quote-error').textContent = errorText(error); }
});
$('load-positions').addEventListener('click', async () => {
  const b = $<HTMLButtonElement>('load-positions'); b.disabled = true;
  try { await loadPositions(); } catch (e) { toast(errorText(e), true); } finally { b.disabled = false; }
});
$('claim-form').addEventListener('submit', async e => {
  e.preventDefault(); $('claim-error').textContent = '';
  try {
    const input = ($('claim-recipient') as HTMLInputElement).value.trim();
    if (!isAddress(input) || BigInt(input) === 0n || input.toLowerCase() === config.contractAddress!.toLowerCase()) throw new Error('Enter a valid recipient address that can receive Sepolia ETH.');
    if (await transaction('Payout', 'claim', [state.claimId, getAddress(input)])) dialog('claim-dialog').close();
  } catch (error) { $('claim-error').textContent = errorText(error); }
});
window.addEventListener('hashchange', route);
setInterval(() => { if (!document.hidden && !state.busy) { refresh(); if (location.hash === '#positions' && state.account && state.ready) loadPositions(true).catch(() => {}); } }, 20000);
setInterval(() => { if (!document.hidden && !state.busy) { renderMarkets(); updateQuote(); } }, 30000);
init();
