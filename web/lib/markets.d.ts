export interface Template { category: 'Squeek' | 'Crypto' | 'Network'; icon: string; horizon: string; metric: string; strike: bigint | null; kind: number }
export interface MarketLike {
  id: bigint | null; templateId: number | bigint; status: number | bigint; strike: bigint | null;
  noPool: bigint; yesPool: bigint; volume: bigint; startsAt: bigint; closesAt: bigint; endsAt: bigint;
  winner?: number | bigint; [key: string]: unknown;
}
export interface PositionLike { noStake: bigint; yesStake: bigint; paid: boolean; [key: string]: unknown }
export const CHAIN_ID: number;
export const CORE: string;
export const EXPLORER: string;
export const STATUS: string[];
export const TEMPLATES: Template[];
export function template(m: MarketLike): Template;
export function money(x: bigint | number): string;
export function ether(x: bigint | null | undefined, places?: number): string;
export function shortAddress(x: string): string;
export function gasAmount(wei: bigint | number): string;
export function grace(m: MarketLike): bigint;
export function question(m: MarketLike): string;
export function labels(m: MarketLike): [string, string];
export function poolOdds(m: MarketLike): [number, number];
export function timeLeft(time: bigint | number, now: number): string;
export function canBet(m: MarketLike, now: number): boolean;
export function quote(m: MarketLike, side: number, input: string): { gross: bigint; fee: bigint; net: bigint; payout: bigint };
export function entitlement(m: MarketLike, p: PositionLike): bigint;
export function rules(m: MarketLike): string;
export function previewMarkets(): MarketLike[];
export function escapeHtml(s: unknown): string;
