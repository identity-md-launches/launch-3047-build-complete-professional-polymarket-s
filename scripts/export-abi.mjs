import { readFile, mkdir, writeFile } from 'node:fs/promises';
const root = new URL('../', import.meta.url);
await mkdir(new URL('web/abi/', root), { recursive: true });
for (const name of ['SqueekPredict', 'SqueekMetrics']) {
  const artifact = JSON.parse(await readFile(new URL(`out/${name}.sol/${name}.json`, root), 'utf8'));
  await writeFile(new URL(`web/abi/${name}.json`, root), JSON.stringify(artifact.abi, null, 2) + '\n');
}
console.log('Exported the compiler ABIs to web/abi.');
