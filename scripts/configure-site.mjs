import { readFile, writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import { Contract, JsonRpcProvider, getAddress, keccak256 } from '../web/vendor/ethers-6.15.0.min.js';
import { CHAIN_ID, CORE } from '../web/lib/markets.js';
import { verifyRuntime } from './runtime.mjs';

const { values } = parseArgs({ options: { address: { type: 'string' }, 'deployment-tx': { type: 'string' }, 'rpc-url': { type: 'string', default: 'https://ethereum-sepolia-rpc.publicnode.com' }, output: { type: 'string' } } });
if (!values.address || !/^0x[\da-f]{64}$/i.test(values['deployment-tx'] || '')) throw new Error('Supply --address and --deployment-tx from the confirmed launch handoff. This command only reads the chain.');
const address = getAddress(values.address);
const provider = new JsonRpcProvider(values['rpc-url'], CHAIN_ID, { staticNetwork: true });
try {
  if (Number(BigInt(await provider.send('eth_chainId', []))) !== CHAIN_ID) throw new Error('RPC must be Sepolia.');
  const receipt = await provider.getTransactionReceipt(values['deployment-tx']);
  if (!receipt || receipt.status !== 1) throw new Error('The deployment transaction is not confirmed successfully.');
  const abi = JSON.parse(await readFile(new URL('../web/abi/SqueekPredict.json', import.meta.url), 'utf8'));
  const contract = new Contract(address, abi, provider);
  const events = receipt.logs.filter(l => l.address.toLowerCase() === address.toLowerCase())
    .map(l => { try { return contract.interface.parseLog(l); } catch { return null; } }).filter(l => l?.name === 'MarketScheduled');
  // The constructor is the only code path that emits MarketScheduled for ids 1..14, so these logs in the
  // receipt prove the deployment without historical state, which public RPCs prune after ~10,000 blocks.
  if (events.length !== 14 || events.some((e,i) => Number(e.args.marketId) !== i + 1 || Number(e.args.templateId) !== i)) throw new Error('The receipt does not contain the fourteen constructor market events at this address.');
  const code = await provider.getCode(address);
  if (code === '0x') throw new Error('No code is deployed at this address.');
  const artifact = JSON.parse(await readFile(new URL('../out/SqueekPredict.sol/SqueekPredict.json', import.meta.url), 'utf8'));
  verifyRuntime(artifact, code);
  const metrics = new Contract(await contract.metrics(), ['function core() view returns (address)'], provider);
  const metricsArtifact = JSON.parse(await readFile(new URL('../out/SqueekMetrics.sol/SqueekMetrics.json', import.meta.url), 'utf8'));
  verifyRuntime(metricsArtifact, await provider.getCode(await metrics.getAddress()));
  const expectedEth = '0x694AA1769357215DE4FAC081bf1f309aDC325306';
  const expectedBtc = '0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43';
  if (Number(await contract.SLOT_COUNT()) !== 14 || Number(await contract.FEE_BPS()) !== 100
    || (await metrics.core()).toLowerCase() !== CORE.toLowerCase()
    || (await contract.ethFeed()).toLowerCase() !== expectedEth.toLowerCase()
    || (await contract.btcFeed()).toLowerCase() !== expectedBtc.toLowerCase()) throw new Error('Deployment parameters do not match the documented release.');
  const config = { chainId: CHAIN_ID, rpcUrl: values['rpc-url'], contractAddress: address, deploymentBlock: receipt.blockNumber,
    runtimeHash: keccak256(code), deploymentTransaction: receipt.hash };
  const output = values.output || new URL('../web/config.json', import.meta.url);
  await writeFile(output, JSON.stringify(config, null, 2) + '\n');
  console.log(`Verified Sepolia deployment ${address} at block ${receipt.blockNumber}. Website configuration written.`);
} finally { provider.destroy(); }
