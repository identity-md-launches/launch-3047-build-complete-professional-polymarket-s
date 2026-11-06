import test from 'node:test';
import assert from 'node:assert/strict';
import { runCycle, PAY_BATCHES } from '../scripts/keeper-lib.mjs';

function fixture() {
  const now=Math.floor(Date.now()/1000);
  const markets=new Map(Array.from({length:14},(_,i)=>[BigInt(i+1),{templateId:i,status:1,closesAt:BigInt(now+43200),endsAt:BigInt(now+86400),paymentCursor:0n}]));
  markets.set(1n,{templateId:0,status:2,endsAt:BigInt(now-3600),paymentCursor:0n});
  markets.set(2n,{templateId:5,status:2,endsAt:BigInt(now-172800),paymentCursor:0n});
  markets.set(3n,{templateId:7,status:3,endsAt:BigInt(now-600),paymentCursor:0n});
  markets.set(4n,{templateId:3,status:0,endsAt:0n,paymentCursor:0n});
  const observing=[0n,0n,0n,0n,0n,20n,0n,0n,0n,0n,0n,0n,0n,0n];
  markets.set(20n,{templateId:5,status:1,closesAt:BigInt(now-43200),endsAt:BigInt(now+600),paymentCursor:0n});
  const contract={activeMarketIds:async()=>Array.from(markets.keys()).slice(0,14),observingMarketIds:async()=>observing,getMarkets:async ids=>ids.map(id=>({...markets.get(id)})),getMarket:async id=>({...markets.get(id)}),nextMarketId:async()=>21n,bettorCount:async id=>id===3n?45n:0n,
    open:{staticCall:async()=>{throw new Error('source unavailable');}},settleSqueek:{staticCall:async()=>{throw new Error('not certified');}},expire:{staticCall:async()=>{}}};
  const actions=[];
  const send=async action=>{actions.push(action);const m=markets.get(action.args[0]);if(action.method==='expire')m.status=4;if(action.method==='pay')m.paymentCursor+=BigInt(action.args[1]);return true;};
  return {contract,provider:{getBlock:async()=>({timestamp:now})},send,actions,markets,observing,now,checkpoint:{nextScan:'1',pending:[]}};
}
test('keeper isolates unavailable data while refunding and advancing bounded payouts',async()=>{
  const f=fixture();const result=await runCycle({...f,maxTransactions:2});
  assert.deepEqual(f.actions.map(a=>a.method),['expire','pay']);
  assert.equal(result.attempted,2);assert.equal(f.markets.get(2n).status,4);assert.equal(f.markets.get(3n).paymentCursor,40n);
  assert.ok(f.checkpoint.pending.includes('1'));assert.ok(f.checkpoint.pending.includes('3'));
  await runCycle({...f,maxTransactions:2});assert.ok(!f.checkpoint.pending.includes('3'));
});
test('upkeep is triggered when a bettable market closes or an observing market ends',async()=>{
  const f=fixture();f.markets.get(6n).closesAt=BigInt(f.now-1);
  await runCycle({...f,maxTransactions:1});assert.equal(f.actions[0].method,'maintain');
  const g=fixture();g.markets.get(20n).endsAt=BigInt(g.now-1);
  await runCycle({...g,maxTransactions:1});assert.equal(g.actions[0].method,'maintain');
  const h=fixture();await runCycle({...h,maxTransactions:1});assert.notEqual(h.actions[0]?.method,'maintain');
});
test('a payment batch the sender refuses is retried smaller and does not consume the cycle budget',async()=>{
  const f=fixture();
  f.send=async action=>{f.actions.push(action);if(action.method==='pay'&&action.args[1]>10)throw Object.assign(new Error('Transaction exceeds the keeper gas budget.'),{code:'NOT_SENT'});
    const m=f.markets.get(action.args[0]);if(action.method==='expire')m.status=4;if(action.method==='pay')m.paymentCursor+=BigInt(action.args[1]);return true;};
  const result=await runCycle({...f,maxTransactions:2});
  assert.deepEqual(f.actions.filter(a=>a.method==='pay').map(a=>a.args[1]),[40,20,10]);
  assert.equal(f.markets.get(3n).paymentCursor,10n);assert.equal(result.attempted,2);assert.equal(result.completed,2);
  assert.deepEqual(PAY_BATCHES,[40,20,10,5]);
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
