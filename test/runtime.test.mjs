import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyRuntime } from '../scripts/runtime.mjs';

test('runtime verification masks only compiler-declared immutable bytes',()=>{
  const artifact={deployedBytecode:{object:'0x6000000060',immutableReferences:{source:[{start:1,length:3}]}}};
  assert.doesNotThrow(()=>verifyRuntime(artifact,'0x60abcdef60'));
  assert.throws(()=>verifyRuntime(artifact,'0x61abcdef60'),/does not match/);
  assert.throws(()=>verifyRuntime(artifact,'0x60ab60'),/length/);
  assert.throws(()=>verifyRuntime(artifact,'0x'),/Missing/);
});
