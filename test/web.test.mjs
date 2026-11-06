import test from 'node:test';
import assert from 'node:assert/strict';
import { parseEther } from '../web/vendor/ethers-6.15.0.min.js';
import { quote, poolOdds, entitlement, canBet, previewMarkets, question, escapeHtml, gasAmount, grace, rules } from '../web/lib/markets.js';

const market = { templateId: 5, strike: 2000_00000000n, noPool: parseEther('2.97'), yesPool: parseEther('0.99'), status: 1, closesAt: 200n };

test('quote matches the contract fee and net-pool accounting', () => {
  const q = quote(market, 1, '1');
  assert.equal(q.fee, parseEther('0.01')); assert.equal(q.net, parseEther('0.99'));
  assert.equal(q.payout, parseEther('2.475'));
  assert.deepEqual(poolOdds(market), [75,25]);
  assert.deepEqual(poolOdds({noPool:0n,yesPool:0n}), [50,50]);
});
test('invalid amounts never produce signable quotes', () => {
  for (const input of ['', '-1', '1e2', 'NaN', '0.0009', '100.000001', '1.0000000000000000001']) assert.throws(() => quote(market, 1, input));
  assert.equal(quote(market,0,'0.001').gross, parseEther('0.001'));
});
test('the exact betting cutoff is closed', () => {
  assert.equal(canBet(market,199),true); assert.equal(canBet(market,200),false);
  assert.equal(canBet({...market,status:3},100),false);
});
test('positions distinguish paid, winning, losing, and refunded stakes', () => {
  const p={noStake:0n,yesStake:parseEther('0.495'),paid:false};
  assert.equal(entitlement({...market,status:3,winner:1},p),parseEther('1.98'));
  assert.equal(entitlement({...market,status:3,winner:0},p),0n);
  assert.equal(entitlement({...market,status:4},p),p.yesStake);
  assert.equal(entitlement({...market,status:3,winner:1},{...p,paid:true}),0n);
});
test('preview has fourteen named templates, no invented deployment IDs or pools', () => {
  const previews=previewMarkets(); assert.equal(previews.length,14);
  for(const m of previews){assert.equal(m.id,null);assert.equal(m.noPool+m.yesPool,0n);assert.ok(question(m).length>20);}
  assert.match(question(previews[5]),/opening price/);
  assert.equal(escapeHtml('<script>"&'), '&lt;script&gt;&quot;&amp;');
});
test('scheduled on-chain slots show template thresholds while their stored strike is unset', () => {
  for (const m of previewMarkets()) assert.equal(question({...m, id: BigInt(m.templateId + 1), strike: 0n}), question(m));
  assert.match(question({templateId: 0, status: 0n, strike: 0n}), /100 Squeek blocks/);
  assert.match(question({templateId: 1, status: 0n, strike: 0n}), /950 Squeek blocks/);
  assert.match(question({templateId: 3, status: 0n, strike: 0n}), /120 minutes/);
  assert.match(question({templateId: 8, status: 0n, strike: 0n}), /opening level/);
});
test('base-fee strikes are shown exactly, in wei when below a thousandth of a gwei', () => {
  for (const [strike, text] of [[7n, '7 wei'], [17n, '17 wei'], [499n, '499 wei'], [999_999n, '999,999 wei'], [1_000_000n, '0.001 gwei'], [10_000_000_000n, '10 gwei']]) {
    assert.equal(gasAmount(strike), text);
    assert.equal(question({ templateId: 8, status: 1, strike }), `Sepolia base fee above ${text} in 24h?`);
  }
  assert.doesNotMatch(question({ templateId: 8, status: 1, strike: 17n }), /0 gwei/);
});
test('grace periods and cutoff rules follow the market kind', () => {
  assert.equal(grace({ templateId: 8 }), 86400n); assert.equal(grace({ templateId: 9 }), 86400n);
  assert.equal(grace({ templateId: 5 }), 172800n); assert.equal(grace({ templateId: 0 }), 172800n);
  assert.match(rules({ templateId: 9 }), /after 24 hours/); assert.match(rules({ templateId: 0 }), /after 48 hours/);
  assert.match(rules({ templateId: 0 }), /closes when the observation window starts/);
  assert.match(rules({ templateId: 5 }), /halfway through/);
});
