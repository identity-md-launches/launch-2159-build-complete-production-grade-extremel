# IMDPot

A 15-minute jackpot using IMD tickets, with a fixed 5% house fee. This revision replaces the **contract source** randomness with a committed future blockhash, configures Privy email sign-in with app ID **`cmve43hs901uf0gl1dqj33sqc`**, and adds a wallet-gated owner panel.

## Live deployment boundary

The verified Ethereum contract is [`0x37cb0333a2fea358ae057bd85c4437803e5bcbfa`](https://etherscan.io/address/0x37cb0333a2fea358ae057bd85c4437803e5bcbfa). Its immutable runtime is the previous VRF version; it has no proxy or upgrade function. Editing source or an ABI cannot change that code. **No contract or token was deployed, replaced or minted on Ethereum by this assignment.**

The website verifies chain ID and runtime bytecode before enabling transactions. It recognizes the legacy and revised source releases separately. At the existing legacy deployment it displays **New game deployment required**, closes new entries and draw requests, and retains claims, eligible refunds, pending-fee flushing and owner pause/unpause. It does not request or configure Chainlink randomness. It never presents the new source as already deployed.

The future-blockhash implementation is playable in local EVM validation. Live play under the requested system requires a separately authorized deployment of `src/IMDPot.sol:IMDPot`, using the existing IMD token, followed by verified deployment/address/block/ABI updates in the handoff and frontend. A new contract has separate round, prize and loyalty state; existing obligations stay with the old contract. Do not redirect claims or refunds to a new address. No new deployment address is invented here.

The worker's public RPC verification observed legacy round 1, IMD already set, `isConfigured() == false`, and `paused() == false` at Ethereum block **26,221,095**. These are observations, not permanent settings. The dashboard always reads current state.

## Install, preview and rebuild

Source, the unchanged package manifest and npm lockfile are in `frontend/`. The complete production export is in **`dist/`**. Use Node.js 24 and npm:

```bash
npm ci --prefix frontend
npm --prefix frontend run typecheck
npm --prefix frontend test
npm --prefix frontend run build
npm --prefix frontend run preview
```

`preview` prints its local URL. `npm --prefix frontend run dev` runs the source. Serve the root `dist/` directory for static hosting; no backend, private credential or rewrite server is required. Vite uses `base: './'`, assets are local and relative, and section navigation uses hashes. Keep every generated lazy SDK chunk with `index.html`. The production build replaces the export and removes old chunks.

Dependencies and caches are not delivered. Do not commit `node_modules`, source maps, dependency archives or package caches. Existing Foundry configuration, vendored contract dependencies and frontend dependency versions are unchanged.

## Privy and wallets

`frontend/public/site-config.json` contains the exact supplied public Privy app ID; the build copies it to `dist/site-config.json`. The real Privy SDK is bundled lazily. **Continue with Privy** opens email authentication, waits for authentication and wallet readiness, creates an Ethereum wallet if needed, and bridges its EIP-1193 provider into the same transaction flow as other wallets. Manual wallet creation avoids racing automatic creation. Sign-in attempts survive reloads in session storage; disconnect logs out the active Privy session. Errors and cancellation return to the wallet picker with retry guidance.

The public Privy app configuration responds successfully and enables email authentication. Google OAuth is disabled in that app, so the site offers email rather than advertising a non-working Google button. No app secret is needed. A real OTP login and authenticated embedded-wallet recovery were not completed because no inbox or personal authentication was used. The production site's origin settings remain managed in the Privy dashboard. See [Privy's provider setup](https://docs.privy.io/basics/react/setup).

Other wallet options remain under the same connect control: EIP-6963 extension discovery, a generic browser-provider fallback, Coinbase Wallet/Smart Wallet, and phone links into MetaMask, Coinbase Wallet, Rabby and Phantom. Wrong-chain connections offer an Ethereum switch with add-chain fallback. No WalletConnect project ID or relay is required.

## Future-blockhash game

The revised `src/IMDPot.sol` has no oracle interface, coordinator, subscription, callback or retry function. Only the IMD token needs one-time owner configuration. Randomness needs no service fee, LINK or ongoing subscription; normal Ethereum transaction gas still applies.

1. Buy whole tickets at **0.1 IMD each**. The first ticket starts exactly 15 minutes; later purchases do not reset the timer.
2. After the deadline, anyone calls `finalizeRound()`. It closes the round in `Drawing` and commits **`drawBlock = block.number + 3`**. Winners are not selected yet: the future hash does not exist.
3. After that target is mined, anyone calls `finalizeRound()` again. The settlement transaction must be included at **target + 1 through target + 256, inclusive**. The site shows the target, final eligible block and **Settle winners** action.
4. The contract hashes the target blockhash with the chain ID, game address and round ID, saves both hash and derived word, selects up to three weighted tickets without replacement, credits prizes, sends/defer fees, locks the permanent share and opens the next round.
5. If the hash window expires, settlement reverts. Anyone can cancel for **full refunds**. No new target or re-roll is allowed for that round. A paused active round with no commitment can be cancelled 24 hours after its scheduled end. An empty round never starts or cancels.

A committed draw can settle while paused, so the owner cannot veto known winners through the pause button. Claims, refunds and fee flushing also remain available while paused. Pausing blocks new entries and new draw commitments.

**Randomness tradeoff:** future commitment prevents a caller from choosing a known blockhash, but block producers can influence hashes or censor settlement. Participants can also withhold settlement until expiry; any other account can settle during the window. This is not cryptographically unbiased or equivalent to VRF. Monitoring/permissionless settlement is needed before the 256-block expiry. See [Solidity's blockhash semantics and warning](https://docs.soliditylang.org/en/v0.8.26/units-and-global-variables.html#block-and-transaction-properties) and [the threat model](docs/SECURITY.md).

| Pool destination | Share |
| --- | --- |
| First / second / third winning tickets | 40% / 20% / 10% |
| Burn | 10% |
| House treasury | 5% |
| Permanently locked, including rounding dust | 15% |

A wallet can win several places if it holds several tickets. With one ticket, first place receives 70%; with two tickets the prizes are 50% / 20%. Prizes use pull claims. Deferred burn/treasury transfers can be flushed independently. One finalized ticket earns one non-transferable loyalty point. After ten settled rounds, 100 points buy +25% selection weight on the next entered round, capped at +100%; cancelled-round refunds restore spent boosts.

## Owner panel and transaction safeguards

`OwnerPanel.tsx` renders only when the **connected** address equals the current onchain `owner()`, case insensitively. Disconnecting or changing accounts removes it. It includes reviewed pause/unpause actions, token/game/owner/treasury addresses, ticket price, duration, house fee, randomness version, settlement window, obligations and permanent lock totals. The future version also offers irreversible one-time setup using the verified Ethereum IMD token from the supplied network facts. The legacy deployment explains its deployment limitation instead of offering source-only configuration.

UI visibility is convenience; `onlyOwner` enforces authorization onchain. Before an admin transaction the app reads the current owner again. Every signed action checks code, account and network, simulates the call, then waits for a successful receipt. Purchases approve the exact amount only when needed and recheck the round after approval. Wallet refusal, reverts, stale reads and replacement are recoverable states, with explorer links. One confirmation is used; later chain reorganization remains possible.

## Contract build and validation

Foundry and Solidity 0.8.26 use the existing `foundry.toml`, remappings and plain vendored libraries. No build/dependency configuration changes are required:

```bash
forge build
forge test
forge fmt --check
node frontend/scripts/verify-contract.mjs --offline
node frontend/scripts/verify-contract.mjs
```

The last command also checks the deployed Ethereum runtime through a public RPC. `--rpc <url>` selects another Ethereum endpoint. The legacy snapshot in `test/legacy/` exists only to reproduce the pinned deployment ABI/runtime and retain its regression tests; application source no longer depends on it. Use fully qualified `src/IMDPot.sol:IMDPot` when selecting the revised contract because the historical fixture keeps its original name for exact ABI reproduction.

Browser validation is reproducible with Anvil, Chromium and optional external Playwright/axe tooling. Install browser tools outside the repository or supply module paths:

```bash
npm install --prefix /tmp/imdpot-browser playwright @axe-core/playwright
PLAYWRIGHT_BROWSERS_PATH=/tmp/imdpot-browsers /tmp/imdpot-browser/node_modules/.bin/playwright install chromium
PLAYWRIGHT_BROWSERS_PATH=/tmp/imdpot-browsers node frontend/scripts/check-browser.mjs \
  --playwright /tmp/imdpot-browser/node_modules/playwright/index.mjs \
  --axe /tmp/imdpot-browser/node_modules/@axe-core/playwright/dist/index.mjs \
  --live-privy
```

The bounded script owns its local node, preview server and browser, and closes them afterward. It installs actual compiled contract code at the pinned addresses **inside a disposable local EVM only** and drives the committed export under `/preview/`. Wallet providers are local test fixtures; transactions never reach mainnet. `--live-privy` additionally checks the real public app and sign-in form without sending an OTP. Screenshot/test outputs default to `test/scratch/` and are not submitted.

The final production build and typecheck passed, as did 12 frontend tests, 135 Foundry runner entries, 23 browser scenarios and all 16 design-probe checks. Actual commands, six-domain review and limitations are recorded in **[artifacts/validation.md](artifacts/validation.md)**. The implemented visual system is documented in **[DESIGN.md](DESIGN.md)**. Worker-side checks are evidence of these particular runs, not independent certification or proof of complete security/accessibility.
