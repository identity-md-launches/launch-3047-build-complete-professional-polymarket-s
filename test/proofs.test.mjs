import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { keccak256, toBeHex } from '../web/vendor/ethers-6.15.0.min.js';
import { encodeHeader, findPriceRound, findNativeHeaders, settlementAction } from '../web/lib/proofs.js';

const fixture=JSON.parse(await readFile(new URL('./fixtures/sepolia-headers.json',import.meta.url),'utf8'));

test('real Sepolia Amsterdam headers reproduce both canonical block hashes offline', () => {
  for(const b of [fixture.parent,fixture.target]) assert.equal(keccak256(encodeHeader(b)),b.hash);
  assert.equal(fixture.target.parentHash,fixture.parent.hash);
  assert.ok(fixture.target.blockAccessListHash); assert.ok(fixture.target.slotNumber);
});
test('tampered or omitted header fields fail before sending evidence', () => {
  assert.throws(()=>encodeHeader({...fixture.target,baseFeePerGas:'0x9999'}),/hash/);
  assert.throws(()=>encodeHeader({...fixture.target,gasUsed:null}),/omitted/);
  assert.throws(()=>encodeHeader({...fixture.target,blockAccessListHash:null}),/Incomplete/);
  assert.throws(()=>encodeHeader({...fixture.target,slotNumber:null}),/hash/);
});

const phase=1n<<64n;
function feedMock({phaseChanged=false,gap=null}={}) {
  const round=async id=>{ if(id===gap)throw new Error('missing round'); const local=id-phase; return [id,2000_00000000n,local*60n,local*60n,id]; };
  return {latestRoundData:()=>round((phaseChanged ? 2n<<64n : phase)+200n),getRoundData:round};
}
test('price search finds the unique last round at or before the deadline', async () => {
  assert.equal(await findPriceRound(feedMock(),phase+1n,6000n),phase+100n);
  assert.equal(await findPriceRound(feedMock(),phase+1n,6030n),phase+100n);
});
test('price search refuses missing history, phase changes, or missing successor', async () => {
  await assert.rejects(()=>findPriceRound(feedMock({phaseChanged:true}),phase+1n,6000n),/phase changed/);
  await assert.rejects(()=>findPriceRound(feedMock({gap:phase+101n}),phase+1n,6000n),/missing/);
  await assert.rejects(()=>findPriceRound(feedMock(),phase+1n,12000n),/Waiting/);
});

function nativeMock(extra=1n) {
  const n=BigInt(fixture.target.number), t=BigInt(fixture.target.timestamp);
  return {send:async(method,[tag])=>{
    assert.equal(method,'eth_getBlockByNumber');
    const number=tag==='latest'?n+extra:BigInt(tag);
    if(number===n-1n)return fixture.parent;
    if(number===n)return fixture.target;
    return {number:toBeHex(number),timestamp:toBeHex(t+(number-n)*12n)};
  }};
}
test('native proof identifies the first boundary block using authentic headers', async()=>{
  const m={startBlock:BigInt(fixture.parent.number),endsAt:BigInt(fixture.target.timestamp)};
  const [a,b]=await findNativeHeaders(nativeMock(),m);
  assert.equal(keccak256(a),fixture.parent.hash);assert.equal(keccak256(b),fixture.target.hash);
});
test('native proof waits for confirmation and refuses an expired BLOCKHASH window', async()=>{
  const m={startBlock:BigInt(fixture.parent.number),endsAt:BigInt(fixture.target.timestamp)};
  await assert.rejects(()=>findNativeHeaders(nativeMock(0n),m),/confirmation/);
  const [a]=await findNativeHeaders(nativeMock(256n),m);assert.equal(keccak256(a),fixture.parent.hash);
  await assert.rejects(()=>findNativeHeaders(nativeMock(8000n),m),/elapsed/);
});
test('timeout and physical-data actions require no off-chain value reporting', async()=>{
  const m={id:12n,templateId:11,endsAt:1000n};
  assert.deepEqual(await settlementAction({}, {},m,1000),{method:'settleSqueek',args:[12n]});
  assert.deepEqual(await settlementAction({}, {},m,173800),{method:'expire',args:[12n]});
  await assert.rejects(()=>settlementAction({}, {},m,999),/not ended/);
});
