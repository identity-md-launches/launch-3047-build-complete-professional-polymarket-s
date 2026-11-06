import type { Contract, JsonRpcProvider } from 'ethers';
import type { MarketLike } from './markets.js';
export const FEED_ABI: string[];
export function settlementAction(contract: Contract, provider: JsonRpcProvider, market: MarketLike, now: number): Promise<{ method: string; args: unknown[] }>;
