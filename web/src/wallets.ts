import { WALLET_ICONS } from './wallet-icons';

/** Minimal EIP-1193 provider surface the site uses. */
export interface Eip1193 {
  request(args: { method: string; params?: unknown[] | object }): Promise<any>;
  on?(event: string, listener: (...args: any[]) => void): void;
  removeListener?(event: string, listener: (...args: any[]) => void): void;
}

export interface WalletEntry { id: string; name: string; icon?: string; rdns?: string; provider: Eip1193 }

export const SITE_NAME = 'Squeek Predict';

/** EIP-6963: every installed extension announces itself with its own name and icon. */
const discovered = new Map<string, WalletEntry>();
const listeners = new Set<() => void>();
window.addEventListener('eip6963:announceProvider', (event: Event) => {
  const { info, provider } = (event as CustomEvent).detail || {};
  if (!info?.uuid || typeof provider?.request !== 'function') return;
  const icon = typeof info.icon === 'string' && /^data:image\//.test(info.icon) ? info.icon : undefined;
  discovered.set(info.uuid, { id: info.rdns || info.uuid, rdns: info.rdns, name: info.name || 'Browser wallet', icon, provider });
  listeners.forEach(l => l());
});
window.dispatchEvent(new Event('eip6963:requestProvider'));

export const onWalletsChanged = (fn: () => void) => { listeners.add(fn); };

/** Extensions found by EIP-6963; the legacy window.ethereum only when discovery named none. */
export function injectedWallets(): WalletEntry[] {
  const list = [...discovered.values()];
  const legacy = (window as any).ethereum as Eip1193 | undefined;
  if (!list.length && legacy?.request) list.push({ id: 'injected', name: 'Browser wallet', provider: legacy });
  return list;
}

let coinbase: Eip1193 | null = null;
/** Coinbase Wallet / Smart Wallet through the Coinbase SDK: the app on desktop, a passkey wallet anywhere. */
export async function coinbaseProvider(chainId: number): Promise<Eip1193> {
  if (coinbase) return coinbase;
  const { createCoinbaseWalletSDK } = await import('@coinbase/wallet-sdk');
  const sdk = createCoinbaseWalletSDK({
    appName: SITE_NAME,
    appLogoUrl: new URL('./favicon.svg', location.href).href,
    appChainIds: [chainId],
    preference: { options: 'all' },
  });
  coinbase = sdk.getProvider() as unknown as Eip1193;
  return coinbase;
}

/**
 * Mobile without a relay: a phone browser has no extension, so the sheet offers to open this page
 * inside a wallet's own browser, where that wallet is injected. Each link is the one its vendor documents.
 */
export const OPEN_IN: ReadonlyArray<{ id: string; name: string; href: (url: string) => string }> = [
  // https://docs.metamask.io/metamask-connect/evm/guides/metamask-exclusive/use-deeplinks
  { id: 'metamask', name: 'MetaMask', href: url => `https://link.metamask.io/dapp/${url.replace(/^https?:\/\//, '')}` },
  // https://docs.cdp.coinbase.com/wallet-sdk/docs/deep-link
  { id: 'coinbase', name: 'Coinbase Wallet', href: url => `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(url)}` },
  // https://docs.phantom.com/phantom-deeplinks/other-methods/browse
  { id: 'phantom', name: 'Phantom', href: url => `https://phantom.app/ul/browse/${encodeURIComponent(url)}?ref=${encodeURIComponent(new URL(url).origin)}` },
];

/** A phone or tablet browser with no injected provider is the case the links exist for. */
export const isMobileBrowser = () => /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) && !(window as any).ethereum;

export const iconUrl = (id: string) => WALLET_ICONS[id] ? `data:image/svg+xml;utf8,${encodeURIComponent(WALLET_ICONS[id])}` : undefined;

const STORE = 'squeek.wallet';
export const rememberWallet = (id: string | null) => { try { id ? localStorage.setItem(STORE, id) : localStorage.removeItem(STORE); } catch { /* storage blocked */ } };
export const rememberedWallet = () => { try { return localStorage.getItem(STORE); } catch { return null; } };
