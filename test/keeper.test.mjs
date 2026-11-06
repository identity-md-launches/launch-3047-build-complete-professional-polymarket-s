import test from 'node:test';
import assert from 'node:assert/strict';
import { runCycle } from '../scripts/keeper-lib.mjs';

function fixture() {
  const now=Math.floor(Date.now()/1000);
  const markets=new Map(Array.from({length:14},(_,i)=>[BigInt(i+1),{templateId:i,status:1,endsAt:BigInt(now+86400),paymentCursor:0n}]));
  markets.set(1n,{templateId:0,status:2,endsAt:BigInt(now-3600),paymentCursor:0n});
  markets.set(2n,{templateId:5,status:2,endsAt:BigInt(now-172800),paymentCursor:0n});
  markets.set(3n,{templateId:7,status:3,endsAt:BigInt(now-600),paymentCursor:0n});
  markets.set(4n,{templateId:3,status:0,endsAt:0n,paymentCursor:0n});
  const contract={activeMarketIds:async()=>Array.from(markets.keys()),getMarkets:async ids=>ids.map(id=>({...markets.get(id)})),getMarket:async id=>({...markets.get(id)}),nextMarketId:async()=>15n,bettorCount:async id=>id===3n?45n:0n,
    open:{staticCall:async()=>{throw new Error('source unavailable');}},settleSqueek:{staticCall:async()=>{throw new Error('not certified');}},expire:{staticCall:async()=>{}}};
  const actions=[];
  const send=async action=>{actions.push(action);const m=markets.get(action.args[0]);if(action.method==='expire')m.status=4;if(action.method==='pay')m.paymentCursor+=40n;return true;};
  return {contract,provider:{getBlock:async()=>({timestamp:now})},send,actions,markets,checkpoint:{nextScan:'1',pending:[]}};
}
test('keeper isolates unavailable data while refunding and advancing bounded payouts',async()=>{
  const f=fixture();const result=await runCycle({...f,maxTransactions:2});
  assert.deepEqual(f.actions.map(a=>a.method),['expire','pay']);
  assert.equal(result.attempted,2);assert.equal(f.markets.get(2n).status,4);assert.equal(f.markets.get(3n).paymentCursor,40n);
  assert.ok(f.checkpoint.pending.includes('1'));assert.ok(f.checkpoint.pending.includes('3'));
  await runCycle({...f,maxTransactions:2});assert.ok(!f.checkpoint.pending.includes('3'));
});
test('dry-run sender does not remove unsettled jobs or claim execution',async()=>{
  const f=fixture();f.send=async()=>false;const result=await runCycle({...f,maxTransactions:1});
  assert.equal(result.completed,0);assert.equal(result.attempted,1);assert.ok(f.checkpoint.pending.includes('2'));
  assert.equal(f.markets.get(2n).status,2);
});
test('keeper rejects stale RPC blocks and invalid budgets',async()=>{
  const f=fixture();f.provider.getBlock=async()=>({timestamp:1});
  await assert.rejects(()=>runCycle(f),/stale/);
  await assert.rejects(()=>runCycle({...f,maxTransactions:0}),/budget/);
});
