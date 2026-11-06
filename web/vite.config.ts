import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';

// The shared libraries in lib/ import the vendored ethers bundle so the Node scripts and tests can
// load them without a package install. The site build resolves that same import to the npm package.
export default defineConfig({
  base: './',
  root: fileURLToPath(new URL('.', import.meta.url)),
  publicDir: 'public',
  resolve: { alias: [{ find: /^.*\/vendor\/ethers-6\.15\.0\.min\.js$/, replacement: 'ethers' }] },
  build: {
    outDir: fileURLToPath(new URL('../dist', import.meta.url)),
    emptyOutDir: true,
    target: 'es2022',
    assetsInlineLimit: 0,
    chunkSizeWarningLimit: 900,
  },
});
