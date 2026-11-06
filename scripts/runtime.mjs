/** Compare all deployed bytes except the compiler-declared immutable slots.
 * The caller separately checks each immutable dependency through its getter. */
export function verifyRuntime(artifact, deployed) {
  const bytecode = artifact.deployedBytecode;
  if (!/^0x[\da-f]+$/i.test(bytecode?.object || '') || !/^0x[\da-f]+$/i.test(deployed)) throw new Error('Missing or unlinked runtime bytecode.');
  const expected = Buffer.from(bytecode.object.slice(2), 'hex');
  const actual = Buffer.from(deployed.slice(2), 'hex');
  if (expected.length !== actual.length) throw new Error('Deployed runtime length does not match the local build.');
  for (const refs of Object.values(bytecode.immutableReferences || {})) {
    for (const {start,length} of refs) {
      if (!Number.isInteger(start) || !Number.isInteger(length) || start < 0 || length <= 0 || start + length > expected.length) throw new Error('Invalid compiler immutable reference.');
      expected.fill(0,start,start+length); actual.fill(0,start,start+length);
    }
  }
  if (!expected.equals(actual)) throw new Error('Deployed runtime does not match the local compiler build.');
}
