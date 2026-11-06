import { BrowserProvider, Contract, JsonRpcProvider, isAddress, keccak256, getAddress } from './vendor/ethers-6.15.0.min.js';
import { CHAIN_ID, CORE, EXPLORER, STATUS, TEMPLATES, template, question, labels, poolOdds, ether,
  shortAddress, timeLeft, canBet, quote, entitlement, rules, previewMarkets, grace, escapeHtml as esc } from './lib/markets.js';
import { settlementAction } from './lib/proofs.js';
import { icon } from './lib/icons.js';

const $ = id => document.getElementById(id);
const state = { markets: previewMarkets(), ready: false, online: false, account: null, wallet: null,
  filter: 'All', search: '', sort: 'default', selected: null, side: 1, busy: false, refreshing: false,
  positionRows: [], positionCount: 0, positionOffset: 0, generation: 0, lastSource: 0,
  chainTime: 0, observedAt: 0, wallets: new Map() };
const now = () => state.chainTime ? state.chainTime + Math.floor((performance.now() - state.observedAt) / 1000) : Math.floor(Date.now() / 1000);
const date = t => new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'UTC' }).format(Number(t) * 1000) + ' UTC';
const marketObject = (m, id) => ({ ...m.toObject(), id });

function toast(message, error = false, hash = null) {
  const el = document.createElement('div'); el.className = `toast${error ? ' error' : ''}`;
  const p = document.createElement('span'); p.textContent = message; el.append(p);
  if (hash && /^0x[\da-f]{64}$/i.test(hash)) {
    const a = document.createElement('a'); a.href = `${EXPLORER}/tx/${hash}`; a.target = '_blank';
    a.rel = 'noopener noreferrer'; a.textContent = 'View transaction ↗'; el.append(a);
  }
  $('toasts').append(el); setTimeout(() => el.remove(), error ? 16000 : 12000);
}

function errorText(error) {
  if (error?.code === 4001 || error?.code === 'ACTION_REJECTED') return 'The wallet request was declined.';
  const data = error?.data ?? error?.info?.error?.data?.data ?? error?.info?.error?.data;
  if (typeof data === 'string' && state.contract) {
    try {
      const name = state.contract.interface.parseError(data)?.name;
      const messages = { BettingClosed: 'Betting has closed for this market.', InvalidAmount: 'Use 0.001–100 ETH per bet.',
        NotCertified: 'SqueekCore has not certified this window yet.', CorePaused: 'Squeek reporting is paused. New stakes are disabled.', CoreStale: 'Squeek certification is more than six hours behind. New stakes are disabled.', StalePrice: 'The price feed is too old. Try again after it updates.',
        InvalidPrice: 'The feed has no valid price right now.', ResolutionExpired: 'The evidence deadline passed. Use the refund action.',
        NothingToClaim: 'There is no unpaid amount for this wallet.', InvalidStatus: 'This market has already changed state. Refresh and try again.',
        UnprovenHeader: 'The header is outside the proof window or could not be authenticated.', TransferFailed: 'The recipient could not receive ETH.' };
      if (name) return messages[name] || `The contract rejected the request: ${name}.`;
    } catch {}
  }
  return error?.shortMessage || error?.message || 'The request did not complete. Please try again.';
}

function renderMarkets() {
  const focused = document.activeElement;
  const restore = $('market-grid').contains(focused) ? (focused.hasAttribute('data-bet')
    ? `[data-bet="${focused.dataset.bet}"][data-side="${focused.dataset.side}"]`
    : focused.hasAttribute('data-rules') ? `[data-rules="${focused.dataset.rules}"]` : null) : null;
  let markets = state.markets.filter(m => (state.filter === 'All' || template(m).category === state.filter)
    && question(m).toLowerCase().includes(state.search.toLowerCase()));
  if (state.sort === 'volume') markets.sort((a, b) => Number((b.yesPool + b.noPool) - (a.yesPool + a.noPool)));
  if (state.sort === 'ending') markets.sort((a, b) => (Number(a.closesAt) || Infinity) - (Number(b.closesAt) || Infinity));
  $('market-count').textContent = markets.length;
  $('no-results').hidden = markets.length > 0;
  $('market-grid').innerHTML = markets.map(m => {
    const t = template(m), [no, yes] = poolOdds(m), [noLabel, yesLabel] = labels(m);
    const available = state.ready && state.online && canBet(m, now()) && !state.busy && (t.category !== 'Squeek' || state.squeekHealthy === true);
    const close = !state.ready ? 'Opens after launch' : Number(m.status) === 0 ? 'Waiting for source'
      : now() < Number(m.closesAt) ? `Closes ${timeLeft(m.closesAt, now())}`
      : now() < Number(m.endsAt) ? `Observing · ${timeLeft(m.endsAt, now())}` : 'Awaiting upkeep';
    const categoryIcon = t.icon === 'hamster' ? '<img src="./assets/mark.svg" alt="">' : icon(t.icon);
    return `<article class="market-card"><div class="card-top"><span class="category-icon ${t.category === 'Crypto' ? 'crypto' : t.category === 'Network' ? 'network-icon' : ''}" aria-hidden="true">${categoryIcon}</span><div class="card-category"><strong>${esc(t.metric)}</strong><span>${esc(t.category)} market</span></div><span class="card-duration">${t.horizon}</span><button class="rules-button" data-rules="${m.templateId}" aria-label="Rules: ${esc(question(m))}">${icon('info')}</button></div><h3>${esc(question(m))}</h3><div class="odds-line"><strong>${yes.toFixed(yes % 1 ? 1 : 0)}<small>% ${yesLabel.toLowerCase()}</small></strong><span>${state.ready && Number(m.status) !== 0 ? 'Pool share' : 'Opening odds'}</span></div><progress class="odds-progress" value="${yes}" max="100" aria-label="${yesLabel} pool share ${yes}%"></progress><div class="bet-sides"><button class="side-button" data-bet="${m.templateId}" data-side="1" ${available ? '' : 'disabled'}><span>${yesLabel}</span><strong>${yes.toFixed(yes % 1 ? 1 : 0)}%</strong></button><button class="side-button no" data-bet="${m.templateId}" data-side="0" ${available ? '' : 'disabled'}><span>${noLabel}</span><strong>${no.toFixed(no % 1 ? 1 : 0)}%</strong></button></div><div class="card-footer"><span class="volume">${state.ready ? ether(m.volume) : '—'} ETH <span class="muted">volume</span></span><span class="closing"><span class="dot ${available ? '' : 'neutral'}"></span>${close}</span></div></article>`;
  }).join('');
  document.querySelectorAll('[data-bet]').forEach(b => b.addEventListener('click', () => openBet(Number(b.dataset.bet), Number(b.dataset.side))));
  document.querySelectorAll('[data-rules]').forEach(b => b.addEventListener('click', () => openRules(state.markets.find(m => Number(m.templateId) === Number(b.dataset.rules)))));
  if (restore) $('market-grid').querySelector(restore)?.focus({ preventScroll: true });
}

function openRules(m) {
  $('rules-title').textContent = question(m); $('rules-body').textContent = rules(m);
  $('rules-times').innerHTML = Number(m.startsAt) ? [['Betting closes', m.closesAt], ['Observation starts', m.startsAt], ['Observation ends', m.endsAt], ['Refund deadline', BigInt(m.endsAt) + grace(m)]]
    .map(([title,t]) => `<div><dt>${title}</dt><dd>${date(t)}</dd></div>`).join('') : '<div><dt>UTC window</dt><dd>Assigned when this market opens</dd></div>';
  $('rules-dialog').showModal();
}

function openBet(slot, side) {
  const m = state.markets.find(m => Number(m.templateId) === slot);
  if (!state.ready || !canBet(m, now())) return;
  state.selected = m; state.side = side;
  $('bet-title').textContent = 'Take a position'; $('bet-question').textContent = question(m);
  $('bet-progress').textContent = ''; $('bet-amount').value = '0.01';
  renderSides(); updateQuote(); $('bet-dialog').showModal(); $('bet-amount').focus();
  updateWalletBalance();
}

function renderSides() {
  const m = state.selected; if (!m) return;
  const odds = poolOdds(m), names = labels(m);
  $('side-picker').innerHTML = [1,0].map(side => `<button type="button" data-pick-side="${side}" class="${side === 0 ? 'no ' : ''}${side === state.side ? 'selected' : ''}" aria-pressed="${side === state.side}">${names[side]} · ${odds[side].toFixed(1)}%</button>`).join('');
  document.querySelectorAll('[data-pick-side]').forEach(b => b.addEventListener('click', () => { state.side = Number(b.dataset.pickSide); renderSides(); updateQuote(); }));
}

function updateQuote() {
  if (!state.selected) return;
  const button = $('submit-bet'); button.disabled = state.busy;
  button.textContent = state.busy ? 'Transaction in progress…' : !state.account ? 'Connect wallet to bet' : `Bet on ${labels(state.selected)[state.side]}`;
  try {
    if (!state.online) throw new Error('Network reads are unavailable. Reconnect before betting.');
    if (template(state.selected).category === 'Squeek' && state.squeekHealthy !== true) throw new Error('Squeek certification is paused, delayed, or unavailable. New stakes are disabled.');
    if (!canBet(state.selected, now())) throw new Error('Betting has closed for this market.');
    const q = quote(state.selected, state.side, $('bet-amount').value);
    $('quote-fee').textContent = `${ether(q.fee, 8)} ETH`;
    $('quote-net').textContent = `${ether(q.net, 8)} ETH`;
    $('quote-return').textContent = `${ether(q.payout, 6)} ETH`;
    $('quote-error').textContent = '';
    if (state.balance != null && state.account && q.gross >= state.balance) throw new Error('Keep enough Sepolia ETH to cover the bet and transaction gas.');
  } catch (error) {
    button.disabled = true; $('quote-error').textContent = errorText(error);
  }
}

async function updateWalletBalance() {
  const account = state.account;
  $('wallet-balance').textContent = account ? 'Checking balance…' : '';
  state.balance = null;
  if (!account) return;
  try { const balance = await state.provider.getBalance(account); if (account !== state.account) return;
    state.balance = balance; $('wallet-balance').textContent = `${ether(balance)} ETH available`; updateQuote();
  } catch { $('wallet-balance').textContent = 'Balance unavailable'; }
}

window.addEventListener('eip6963:announceProvider', event => {
  const { info, provider } = event.detail || {};
  if (info?.uuid && provider?.request) state.wallets.set(info.uuid, { name: info.name || 'Ethereum wallet', provider });
});
window.dispatchEvent(new Event('eip6963:requestProvider'));

function walletPicker() {
  if (state.busy) return;
  $('wallet-error').textContent = '';
  const wallets = [...state.wallets.values()];
  if (!wallets.length && window.ethereum?.request) wallets.push({ name: 'Browser wallet', provider: window.ethereum });
  $('wallet-options').replaceChildren();
  if (!wallets.length) {
    const p = document.createElement('p'); p.className = 'notice'; p.textContent = 'No wallet was detected. Open this site in an Ethereum wallet browser or install a browser wallet, then reload.'; $('wallet-options').append(p);
  }
  wallets.forEach(wallet => {
    const b = document.createElement('button'); b.className = 'wallet-option'; b.textContent = wallet.name;
    b.addEventListener('click', async () => { b.disabled = true; try { await connectWallet(wallet.provider); $('wallet-dialog').close(); } catch (e) { $('wallet-error').textContent = errorText(e); } finally { b.disabled = false; } });
    $('wallet-options').append(b);
  });
  $('wallet-dialog').showModal();
}

async function connectWallet(provider) {
  const accounts = await provider.request({ method: 'eth_requestAccounts' });
  if (!accounts?.[0] || !isAddress(accounts[0])) throw new Error('The wallet did not provide an account.');
  if (state.wallet !== provider) {
    if (state.wallet?.removeListener) { state.wallet.removeListener('accountsChanged', accountChanged); state.wallet.removeListener('chainChanged', chainChanged); }
    state.wallet = provider;
    provider.on?.('accountsChanged', accountChanged); provider.on?.('chainChanged', chainChanged);
  }
  accountChanged(accounts);
  await checkWalletChain();
}

function accountChanged(accounts) {
  const previous = state.account;
  state.account = accounts?.[0] && isAddress(accounts[0]) ? getAddress(accounts[0]) : null;
  if (previous && previous !== state.account) {
    $('bet-dialog').close(); $('claim-dialog').close();
  }
  ++state.generation; state.balance = null; state.positionRows = []; state.positionOffset = 0;
  $('connect').textContent = state.account ? shortAddress(state.account) : 'Connect wallet ↗';
  $('connect').title = state.account || 'Connect an Ethereum wallet';
  renderPositions(); updateWalletBalance();
  if (state.account && state.ready) loadPositions(true).catch(e => toast(errorText(e), true));
}
function chainChanged() { checkWalletChain().catch(e => toast(errorText(e), true)); }
async function checkWalletChain() {
  if (!state.wallet) return;
  const chain = Number(BigInt(await state.wallet.request({ method: 'eth_chainId' })));
  $('network-notice').hidden = chain === CHAIN_ID;
  $('network-notice').textContent = 'Your wallet is on another network. The site reads Sepolia; a transaction will ask you to switch to Sepolia.';
}

async function transaction(label, method, args, overrides = {}) {
  if (!state.account || !state.wallet) { walletPicker(); return false; }
  if (!state.ready || !state.online) { toast('A verified Sepolia deployment and live RPC connection are required.', true); return false; }
  if (state.busy) return false;
  state.busy = true; updateQuote(); $('upkeep').disabled = true;
  const account = state.account;
  let hash;
  try {
    let chain = Number(BigInt(await state.wallet.request({ method: 'eth_chainId' })));
    if (chain !== CHAIN_ID) {
      try { await state.wallet.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xaa36a7' }] }); }
      catch (e) {
        if (e.code !== 4902 && e?.data?.originalError?.code !== 4902) throw e;
        await state.wallet.request({ method: 'wallet_addEthereumChain', params: [{ chainId: '0xaa36a7', chainName: 'Sepolia', nativeCurrency: { name: 'Sepolia ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: [state.config.rpcUrl], blockExplorerUrls: [EXPLORER] }] });
        await state.wallet.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xaa36a7' }] });
      }
    }
    chain = Number(BigInt(await state.wallet.request({ method: 'eth_chainId' })));
    if (chain !== CHAIN_ID) throw new Error('Switch the wallet to Sepolia to continue.');
    const browser = new BrowserProvider(state.wallet, 'any');
    const signer = await browser.getSigner();
    if ((await signer.getAddress()).toLowerCase() !== account.toLowerCase() || account !== state.account) throw new Error('The wallet account changed. Review the transaction again.');
    await state.contract[method].staticCall(...args, { ...overrides, from: account });
    const gas = await state.contract[method].estimateGas(...args, { ...overrides, from: account });
    const request = await state.contract[method].populateTransaction(...args, overrides);
    $('bet-progress').textContent = 'Confirm the transaction in your wallet.';
    if (Number(BigInt(await state.wallet.request({ method: 'eth_chainId' }))) !== CHAIN_ID) throw new Error('The wallet network changed. Review the transaction again.');
    const accounts = await state.wallet.request({ method: 'eth_accounts' });
    if (account !== state.account || accounts?.[0]?.toLowerCase() !== account.toLowerCase()) throw new Error('The wallet account changed. Review the transaction again.');
    const tx = await signer.sendTransaction({ ...request, chainId: CHAIN_ID, gasLimit: gas * 125n / 100n });
    hash = tx.hash; toast(`${label} submitted. Waiting for confirmation.`, false, hash);
    $('bet-progress').textContent = 'Submitted. Waiting for on-chain confirmation…';
    let receipt;
    try { receipt = await tx.wait(1, 120000); }
    catch (e) { if (e.code === 'TRANSACTION_REPLACED' && !e.cancelled && e.receipt) receipt = e.receipt; else throw e; }
    if (!receipt || Number(receipt.status) !== 1) throw new Error('The transaction reverted on-chain.');
    toast(`${label} confirmed.`, false, receipt.hash || hash); $('bet-progress').textContent = 'Confirmed on Sepolia.';
    await refresh(); await loadPositions(true); await updateWalletBalance();
    return true;
  } catch (e) {
    const message = hash && e.code === 'TIMEOUT' ? 'Transaction submitted; confirmation is still pending. Check the explorer before retrying.' : errorText(e);
    toast(message, true, hash); $('bet-progress').textContent = message; return false;
  } finally { state.busy = false; updateQuote(); renderMarkets(); renderPositions(); $('upkeep').disabled = !state.ready || !state.online; }
}

async function loadPositions(reset = false) {
  if (!state.account || !state.ready) { renderPositions(); return; }
  const generation = state.generation, account = state.account;
  const offset = reset ? 0 : state.positionOffset;
  const count = Number(await state.contract.userMarketCount(account));
  const ids = Array.from(await state.contract.positionIds(account, offset, 50));
  const markets = await state.contract.getMarkets(ids);
  const rows = [];
  for (let i = 0; i < ids.length; i += 5) {
    const batch = await Promise.all(ids.slice(i, i + 5).map((id, j) => state.contract.getPosition(id, account).then(p => ({ m: marketObject(markets[i + j], id), p: p.toObject() }))));
    rows.push(...batch);
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
  if (!state.ready) {
    $('position-list').innerHTML = '<div class="empty-state"><h2>Markets are preparing to launch.</h2><p>Positions will appear here after the confirmed contracts are connected.</p></div>';
    $('staked-total').textContent = '—'; $('claim-total').textContent = '—'; return;
  }
  let stake = 0n, claim = 0n;
  $('position-list').innerHTML = state.positionRows.map(({m,p}) => {
    const net = p.noStake + p.yesStake, available = entitlement(m,p), sides = labels(m);
    stake += net; claim += available;
    let action = p.paid ? '<span class="action-label">✓ Payout received</span>'
      : available > 0n ? `<button class="primary small" data-claim="${m.id}" ${state.busy ? 'disabled' : ''}>Claim ${ether(available)} ETH</button>`
      : Number(m.status) < 3 && Number(m.endsAt) <= now() ? `<button class="secondary" data-settle="${m.id}" ${state.busy ? 'disabled' : ''}>${now() >= Number(m.endsAt) + Number(grace(m)) ? 'Refund' : 'Settle'}</button>`
      : Number(m.status) === 3 ? '<span class="muted mini">No winning stake</span>' : '<span class="muted mini">Observing</span>';
    const sideText = [p.yesStake > 0n ? `${sides[1]} · ${ether(p.yesStake)} ETH` : '', p.noStake > 0n ? `${sides[0]} · ${ether(p.noStake)} ETH` : ''].filter(Boolean).join(' / ');
    return `<article class="position-row"><div><span class="tag">#${m.id} · ${STATUS[Number(m.status)]}</span><h3>${esc(question(m))}</h3><p>${esc(sideText)}</p></div><div class="position-cell"><span>Net stake</span>${ether(net)} ETH</div><div class="position-cell"><span>${Number(m.status) >= 3 ? 'Outcome' : 'Observation ends'}</span>${Number(m.status) === 4 ? 'Net refund' : Number(m.status) === 3 ? sides[Number(m.winner)] : date(m.endsAt)}</div>${action}</article>`;
  }).join('') || '<div class="empty-state"><h2>No positions yet.</h2><p>Your bets are recorded on-chain and will appear here.</p><a class="primary" href="#markets">Explore markets</a></div>';
  $('staked-total').textContent = `${ether(stake)} ETH`; $('claim-total').textContent = `${ether(claim)} ETH`;
  $('load-positions').hidden = state.positionOffset >= state.positionCount;
  document.querySelectorAll('[data-claim]').forEach(b => b.addEventListener('click', () => {
    state.claimId = BigInt(b.dataset.claim);
    $('claim-recipient').value = state.account; $('claim-error').textContent = '';
    $('claim-dialog').showModal();
  }));
  document.querySelectorAll('[data-settle]').forEach(b => b.addEventListener('click', async () => {
    if (state.busy) return; b.disabled = true;
    try { const row = state.positionRows.find(r => String(r.m.id) === b.dataset.settle);
      const action = await settlementAction(state.contract, state.provider, row.m, now());
      await transaction(action.method === 'expire' ? 'Refund' : 'Settlement', action.method, action.args);
    } catch (e) { toast(errorText(e), true); } finally { b.disabled = false; }
  }));
}

async function sourceHealth() {
  if (!state.provider || Date.now() - state.lastSource < 60000) return;
  state.lastSource = Date.now();
  const abi = [
    'function state() view returns ((uint64 settledThroughRound,uint64 cumulativeWork,uint96 cumulativeBlockUnits,uint64 blockHeight,uint96 blockProgress,uint32 workPerThousandBlocks,uint256 authorizationNonce,bool paused))',
    'function configuration() view returns ((bytes32 streamId,uint64 genesisTimestamp,uint64 roundDuration,uint64 maxWorkPerRound,uint16 maxRoundsPerBatch,address guardian,address reporter,uint32 initialWorkPerThousandBlocks,uint64 targetBlocksPerActiveRound,uint64 difficultySmoothingRounds,uint96 blockUnitsPerBlock))',
  ];
  try {
    const core = new Contract(CORE, abi, state.provider);
    const [s,c] = await Promise.all([core.state(), core.configuration()]);
    const certifiedAt = c.genesisTimestamp + s.settledThroughRound * c.roundDuration;
    state.squeekHealthy = !s.paused && now() - Number(certifiedAt) <= 21600 && Number(certifiedAt) <= now();
    const delayed = now() - Number(certifiedAt) > 7200 || s.paused;
    $('source-notice').hidden = !delayed;
    $('source-notice').textContent = `Squeek reporting ${s.paused ? 'is paused' : 'is delayed'} · Certified through ${date(certifiedAt)}. Hamster markets need new certification to settle; missing evidence 48 hours after a window ends triggers a net refund. Crypto and network markets use separate sources.`;
  } catch {
    state.squeekHealthy = false;
    $('source-notice').hidden = false;
    $('source-notice').textContent = 'Squeek source health could not be checked. Hamster markets depend on certified Core data; review the source before placing a bet.';
  }
  renderMarkets(); updateQuote();
}

async function refresh() {
  if (state.refreshing || !state.provider) return;
  state.refreshing = true;
  try {
    const block = await state.provider.getBlock('latest');
    if (!block) throw new Error('Sepolia RPC returned no latest block.');
    state.chainTime = block.timestamp; state.observedAt = performance.now();
    if (Date.now() / 1000 - block.timestamp > 180) throw new Error('The Sepolia RPC is serving a stale block.');
    if (state.ready) {
      const ids = Array.from(await state.contract.activeMarketIds({ blockTag: block.number }));
      const markets = await state.contract.getMarkets(ids, { blockTag: block.number });
      state.markets = markets.map((m,i) => marketObject(m,ids[i]));
      if (state.selected) {
        const updated = state.markets.find(m => m.id === state.selected.id);
        if (updated) state.selected = updated;
      }
    }
    state.online = true;
    $('network-notice').hidden = true;
    if (state.wallet) checkWalletChain().catch(() => {});
    $('read-status').innerHTML = `<span class="dot"></span>${state.ready ? 'Live on Sepolia' : 'Sepolia connected · launch preview'} · block ${block.number.toLocaleString()}`;
    $('upkeep').disabled = !state.ready || state.busy;
    renderMarkets(); if ($('bet-dialog').open) renderSides(); updateQuote(); await sourceHealth();
  } catch (e) {
    state.online = false; $('upkeep').disabled = true;
    $('read-status').innerHTML = '<span class="dot warning"></span>Network unavailable · bets disabled';
    renderMarkets(); updateQuote();
    $('network-notice').hidden = false; $('network-notice').textContent = errorText(e);
  } finally { state.refreshing = false; }
}

function route() {
  const name = ['positions','how'].includes(location.hash.slice(1)) ? location.hash.slice(1) : 'markets';
  for (const p of ['markets','positions','how']) $(p + '-page').hidden = p !== name;
  document.querySelectorAll('[data-nav]').forEach(a => { a.classList.toggle('active', a.dataset.nav === name); if (a.dataset.nav === name) a.setAttribute('aria-current','page'); else a.removeAttribute('aria-current'); });
  if (name === 'positions' && state.account && state.ready) loadPositions(true).catch(e => toast(errorText(e), true));
}

async function init() {
  document.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); });
  renderMarkets(); route();
  try {
    const [configResponse, abiResponse] = await Promise.all([fetch('./config.json', { cache: 'no-store' }), fetch('./abi/SqueekPredict.json')]);
    if (!configResponse.ok || !abiResponse.ok) throw new Error('Website configuration or ABI is missing.');
    const [config,abi] = await Promise.all([configResponse.json(),abiResponse.json()]);
    if (config.chainId !== CHAIN_ID || typeof config.rpcUrl !== 'string' || !/^https?:\/\//.test(config.rpcUrl)) throw new Error('This website requires a Sepolia RPC configuration.');
    state.config = config; state.provider = new JsonRpcProvider(config.rpcUrl, CHAIN_ID, { staticNetwork: true, batchMaxCount: 10 });
    if (Number(BigInt(await state.provider.send('eth_chainId', []))) !== CHAIN_ID) throw new Error('The configured RPC is not Sepolia.');
    if (config.contractAddress !== null) {
      if (!isAddress(config.contractAddress) || !/^0x[\da-f]{64}$/i.test(config.runtimeHash || '')) throw new Error('The confirmed contract address or runtime hash is missing. Run the deployment handoff.');
      const code = await state.provider.getCode(config.contractAddress);
      if (code === '0x' || keccak256(code).toLowerCase() !== config.runtimeHash.toLowerCase()) throw new Error('The deployed contract code does not match the website configuration.');
      const contract = new Contract(config.contractAddress, [...abi, 'error CorePaused()', 'error CoreStale(uint256 certifiedAt)', 'error NotCertified(uint64 requiredRound,uint64 certifiedRound)'], state.provider);
      if (Number(await contract.SLOT_COUNT()) !== 14 || Number(await contract.FEE_BPS()) !== 100) throw new Error('The configured contract is not Squeek Predict.');
      state.contract = contract; state.ready = true; $('launch-notice').hidden = true;
      $('contract-link').hidden = false; $('contract-link').href = `${EXPLORER}/address/${config.contractAddress}`;
    }
    await refresh();
  } catch (e) {
    state.ready = false; state.online = false; $('launch-notice').hidden = false;
    $('launch-notice').className = 'notice error'; $('launch-notice').textContent = errorText(e);
    $('read-status').textContent = 'Configuration unavailable · betting disabled'; renderMarkets();
  }
}

$('connect').addEventListener('click', walletPicker);
$('positions-wallet').addEventListener('click', walletPicker);
$('upkeep').addEventListener('click', () => transaction('Market upkeep', 'maintain', []));
document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => $(b.dataset.close).close()));
document.querySelectorAll('[data-filter]').forEach(b => b.addEventListener('click', () => { state.filter = b.dataset.filter; document.querySelectorAll('[data-filter]').forEach(x => x.classList.toggle('selected', x === b)); renderMarkets(); }));
$('search').addEventListener('input', e => { state.search = e.target.value; renderMarkets(); });
$('sort').addEventListener('change', e => { state.sort = e.target.value; renderMarkets(); });
$('clear-search').addEventListener('click', () => { state.search = ''; $('search').value = ''; document.querySelector('[data-filter="All"]').click(); });
$('bet-amount').addEventListener('input', updateQuote);
document.querySelectorAll('[data-amount]').forEach(b => b.addEventListener('click', () => { $('bet-amount').value = b.dataset.amount; updateQuote(); }));
$('bet-form').addEventListener('submit', async e => {
  e.preventDefault(); if (!state.account) { walletPicker(); return; }
  try { const q = quote(state.selected, state.side, $('bet-amount').value);
    if (await transaction('Bet', 'bet', [state.selected.id, state.side], { value: q.gross })) $('bet-dialog').close();
  } catch (error) { $('quote-error').textContent = errorText(error); }
});
$('load-positions').addEventListener('click', async () => { $('load-positions').disabled = true; try { await loadPositions(); } catch (e) { toast(errorText(e), true); } finally { $('load-positions').disabled = false; } });
$('claim-form').addEventListener('submit', async e => {
  e.preventDefault(); $('claim-error').textContent = '';
  try {
    const input = $('claim-recipient').value.trim();
    if (!isAddress(input) || BigInt(input) === 0n || input.toLowerCase() === state.config.contractAddress.toLowerCase()) throw new Error('Enter a valid recipient address that can receive Sepolia ETH.');
    if (await transaction('Payout', 'claim', [state.claimId, getAddress(input)])) $('claim-dialog').close();
  } catch (error) { $('claim-error').textContent = errorText(error); }
});
window.addEventListener('hashchange', route);
setInterval(() => { if (!document.hidden) { refresh(); if (location.hash === '#positions' && state.account && state.ready && !state.busy) loadPositions(true).catch(() => {}); } }, 20000);
setInterval(() => { if (!document.hidden && !state.busy) { renderMarkets(); updateQuote(); } }, 30000);
await init();
