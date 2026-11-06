const paths = {
  spark: '<path d="M12 2v20M2 12h20M5 5l14 14M5 19 19 5"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
  run: '<path d="m3 17 6-6 4 4 8-11M15 4h6v6"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/>',
  eth: '<path d="m12 2 7 10-7 4-7-4 7-10Zm-7 13 7 7 7-7-7 4-7-4Z"/><path d="M12 2v14M5 12l7-4 7 4" opacity=".5"/>',
  btc: '<path d="M9 3v18m4-18v3m0 12v3M6 6h8a3 3 0 0 1 0 6H8m-2 0h9a3 3 0 0 1 0 6H6"/>',
  gas: '<path d="M3 21h12M5 21V4h8v17M5 10h8m0 3h3v5a2 2 0 0 0 4 0V8l-3-3"/><path d="M18 6v4h2"/>',
  blocks: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  pause: '<circle cx="12" cy="12" r="9"/><path d="M10 9v6m4-6v6"/>',
  activity: '<path d="M2 12h4l3-8 6 16 3-8h4"/>',
  shield: '<path d="m12 2 8 4v6c0 5-8 10-8 10S4 17 4 12V6l8-4Z"/><path d="m8 12 3 3 5-6"/>',
  wallet: '<path d="M20 8V5a2 2 0 0 0-2-2H6a3 3 0 0 0 0 6h15v12H6a3 3 0 0 1-3-3V6"/><path d="M21 12h-6v5h6m-3-2.5h.01"/>',
};
export function icon(name) {
  return `<svg class="ui-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${paths[name] || paths.activity}</svg>`;
}
