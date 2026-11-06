# Vendored dependencies

All runtime and Solidity test dependencies are ordinary files. No submodules, package-manager installs, or network downloads are needed to build, test, or serve the delivered app.

| Dependency | Pin and location | License |
| --- | --- | --- |
| forge-std | v1.9.7, commit `77041d2ce690e692d6e03cc812b57d1ddaa4d505`; `lib/forge-std/src/` | MIT / Apache-2.0; both license files included |
| ethers | npm 6.15.0 browser ESM distribution; `web/vendor/ethers-6.15.0.min.js` | MIT; `web/vendor/ethers-LICENSE.md` |
| Inter | rsms/inter v4.1 variable font; `web/assets/InterVariable.woff2` | SIL Open Font License; `web/assets/Inter-LICENSE.txt` |

The ethers file's SHA-256 is `66580dbb32353addbbfd2c1880a29693436c2d41ebdd4bf4a4516b9ad6f5f5ea`.

Sources: [forge-std release](https://github.com/foundry-rs/forge-std/tree/v1.9.7), [ethers package](https://registry.npmjs.org/ethers/6.15.0), [Inter release](https://github.com/rsms/inter/tree/v4.1).

The Squeek read interface describes the public ABI of the specified contract. Source evidence and attribution are in `docs/SOURCES.md`. The small header parser, market implementation, test harnesses and website were written for this project. The supplied eth-security material was read as review background; it is not a runtime dependency.
