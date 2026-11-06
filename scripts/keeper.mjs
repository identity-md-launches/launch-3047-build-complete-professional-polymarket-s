import { readFile, writeFile, rename } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import { resolve } from 'node:path';
import { Contract, JsonRpcProvider, getAddress, keccak256, parseUnits } from '../web/vendor/ethers-6.15.0.min.js';
import { runCycle } from './keeper-lib.mjs';
import { CHAIN_ID } from '../web/lib/markets.js';

const { values } = parseArgs({ options: {
  config: { type: 'string', default: 'web/config.json' }, 'dry-run': { type: 'boolean', default: false },
  once: { type: 'boolean', default: false }, 'interval-ms': { type: 'string', default: '30000' },
  'signer-rpc': { type: 'string' }, account: { type: 'string' }, 'state-file': { type: 'string', default: 'keeper-state.json' },
  'max-transactions': { type: 'string', default: '12' }, 'max-gas-price-gwei': { type: 'string', default: '30' },
} });
const interval = Number(values['interval-ms']), maxTransactions = Number(values['max-transactions']);
if (!Number.isInteger(interval) || interval < 100 || interval > 3600000) throw new Error('Interval must be 100–3600000 ms.');
if (!Number.isInteger(maxTransactions) || maxTransactions < 1 || maxTransactions > 100) throw new Error('Use 1–100 transactions per cycle.');
if (!values['dry-run'] && (!values['signer-rpc'] || !values.account)) throw new Error('Use --dry-run for reads, or explicitly supply --signer-rpc and --account for an operator-managed signer.');
const config = JSON.parse(await readFile(values.config, 'utf8'));
if (config.chainId !== CHAIN_ID || !config.contractAddress || !config.runtimeHash) throw new Error('Launch is pending: configure the website from a confirmed Sepolia deployment first.');
const address = getAddress(config.contractAddress);
const provider = new JsonRpcProvider(config.rpcUrl, CHAIN_ID, { staticNetwork: true });
let signerProvider;
let stopped = false;
process.on('SIGINT', () => { stopped = true; }); process.on('SIGTERM', () => { stopped = true; });
try {
  if (Number(BigInt(await provider.send('eth_chainId', []))) !== CHAIN_ID) throw new Error('Reader RPC is not Sepolia.');
  const code = await provider.getCode(address);
  if (code === '0x' || keccak256(code).toLowerCase() !== config.runtimeHash.toLowerCase()) throw new Error('Runtime identity mismatch.');
  const abi = JSON.parse(await readFile(new URL('../web/abi/SqueekPredict.json', import.meta.url), 'utf8'));
  const contract = new Contract(address, abi, provider);
  let signer;
  if (!values['dry-run']) {
    signerProvider = new JsonRpcProvider(values['signer-rpc'], CHAIN_ID, { staticNetwork: true });
    if (Number(BigInt(await signerProvider.send('eth_chainId', []))) !== CHAIN_ID) throw new Error('Signer RPC is not Sepolia.');
    signer = await signerProvider.getSigner(getAddress(values.account));
  }
  let checkpoint = { chainId: CHAIN_ID, address, nextScan: '1', pending: [] };
  try {
    const saved = JSON.parse(await readFile(values['state-file'], 'utf8'));
    if (saved.chainId === CHAIN_ID && saved.address?.toLowerCase() === address.toLowerCase()) checkpoint = saved;
  } catch (e) { if (e.code !== 'ENOENT') throw new Error('Keeper state file is invalid; use a new explicit state path to rescan.'); }
  const maxFee = parseUnits(values['max-gas-price-gwei'], 'gwei');
  if (maxFee <= 0n) throw new Error('The gas price ceiling must be positive.');
  const send = async ({ method, args }) => {
    const from = signer ? await signer.getAddress() : undefined;
    await contract[method].staticCall(...args, ...(from ? [{ from }] : []));
    if (values['dry-run']) { console.log(`Ready: ${method}(${args[0] ?? ''}) — no transaction sent.`); return false; }
    const fees = await provider.getFeeData();
    if (!fees.maxFeePerGas || fees.maxFeePerGas > maxFee) throw new Error('Network gas exceeds the operator ceiling; skipped.');
    const gas = await contract[method].estimateGas(...args, { from });
    const gasLimit = gas * 125n / 100n;
    if (gasLimit > 8_000_000n) throw new Error('Transaction exceeds the keeper gas budget.');
    const request = await contract[method].populateTransaction(...args);
    if (await provider.getBalance(from) < gasLimit * fees.maxFeePerGas) throw new Error('Operator has insufficient Sepolia ETH for gas.');
    const tx = await signer.sendTransaction({ ...request, chainId: CHAIN_ID, gasLimit, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas ?? 0n });
    console.log(`Submitted ${method}: ${tx.hash}`);
    const receipt = await tx.wait(1, 120000);
    if (!receipt || Number(receipt.status) !== 1) throw new Error(`Transaction did not succeed: ${tx.hash}`);
    return true;
  };
  do {
    try {
      const result = await runCycle({ contract, provider, send, checkpoint, maxTransactions, log: message => console.log(message) });
      console.log(JSON.stringify(result));
      if (!values['dry-run']) {
        const path = resolve(values['state-file']);
        await writeFile(path + '.next', JSON.stringify(checkpoint, null, 2) + '\n');
        await rename(path + '.next', path);
      }
    } catch (e) { console.error(`Cycle failed: ${e.shortMessage || e.message}`); if (values.once) process.exitCode = 1; }
    if (values.once || stopped) break;
    // Small sleeps keep signals responsive; test with --interval-ms 100 and mocked providers.
    const until = Date.now() + interval;
    while (!stopped && Date.now() < until) await new Promise(resolve => setTimeout(resolve, Math.min(1000, until - Date.now())));
  } while (!stopped);
} finally { provider.destroy(); signerProvider?.destroy(); }
