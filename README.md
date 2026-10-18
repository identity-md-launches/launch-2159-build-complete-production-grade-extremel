# IMDPot

A fast, provably fair 15-minute jackpot played only with the **$IMD** token. The platform never risks its own
capital: every round is funded entirely by ticket sales and the house earns a fixed 5% fee.

## Dashboard: install, preview and rebuild

The finished static website is committed in **`dist/`**. Its React/TypeScript source, Vite configuration, package manifest and npm lockfile live in **`frontend/`**. Serve `dist/` directly; the publisher does not need to rebuild it. Assets use relative URLs (`base: './'`), and section navigation uses hashes, so it works below a static gateway path without a rewrite server.

Use Node.js 24 (validated with 24.21.0) and npm:

```bash
npm ci --prefix frontend
npm --prefix frontend run typecheck
npm --prefix frontend test
npm --prefix frontend run build
npm --prefix frontend run preview
```

The preview command prints its local URL. `npm --prefix frontend run dev` runs the source during development. A production build replaces the root `dist/` completely, including all lazy wallet/Privy chunks. Keep the complete export together. Do not add `node_modules`, caches, source maps or dependency archives to the submission. No npm registry mirror or backend is required.

The dashboard reads the verified **Ethereum mainnet** contract at [`0x37cb0333a2fea358ae057bd85c4437803e5bcbfa`](https://etherscan.io/address/0x37cb0333a2fea358ae057bd85c4437803e5bcbfa). Public read sources are [PublicNode](https://ethereum-rpc.publicnode.com) and [dRPC](https://eth.drpc.org). `frontend/src/config.ts` contains the pinned deployment, chain and expected runtime hash. The IMD token address and decimals come from the live contract; the app never substitutes a different token. Round reads refresh every 15 seconds and fee history every 30 seconds. Stale/error reads disable signed actions and expose retry.

### Wallets and Privy

The first-screen wallet picker supports named browser extensions via EIP-6963, a generic EIP-1193 fallback, Coinbase Wallet/Smart Wallet and phone links into MetaMask, Coinbase Wallet, Rabby and Phantom. The connected control shows the address and offers disconnect. A wrong-network connection offers an Ethereum switch and add-chain fallback. No WalletConnect relay or project ID is required.

Privy is a real, locally bundled, lazy React SDK integration for email/Google login and an Ethereum embedded wallet. The handoff supplies no Privy app ID. Its existing owner-settable option is retained in `frontend/public/site-config.json`:

- Set `privyAppId` to the actual public app ID from the owner's Privy dashboard.
- Configure the final site's permitted origin and login methods in that Privy app.
- Rebuild and serve the full `dist/` export. No secret key belongs in the site.

The delivered value is empty, so the picker explicitly says Privy is awaiting setup; browser wallets and Coinbase still work. Nothing uses an invented app ID. See [Privy's setup documentation](https://docs.privy.io/basics/react/setup) for its app-ID and origin requirements.

### Live readiness and transaction behavior

At validation on **2026-10-18**, the deployed game was in round 1, with an empty pool, no token configured and no VRF coordinator configured (`isConfigured() == false`). The website reflects that state and prevents purchases. The existing post-launch owner configuration described below must happen before real play can begin; this frontend job sends no owner or game transactions.

A purchase reviews whole tickets and exact IMD cost, approves only that amount if needed, then separately confirms `buyTickets`. Approval alone never counts as a purchase. The app rechecks deployment code, account, chain, round, cost and entry availability before proceeding. Transactions are simulated first and success requires a successful Ethereum receipt. Receipt confirmation uses one block; a later reorganization is still possible. Wallet cancellation, reverts and replacement are reported with explorer links.

The 15-minute timer remains at its idle duration until the first onchain purchase. After the deadline, anyone may finalize; this requests VRF, and a later callback settles prizes and opens the next round. Claims aggregate all unclaimed wins. Loyalty balances include lazily credited finalized rounds. History reads at most 2,000 blocks per page in 500-block requests, shows 20 newest transfer events per page, and provides earlier-block navigation back to deployment. Winners inspect up to 10 recent completed/cancelled rounds and show the three most recent finalized rounds with winners. Refund lookup accepts an explicit past round number so older refunds remain reachable.

### Worker validation

The worker ran the production build, TypeScript check, eight domain/ABI tests, thirteen isolated Chromium interaction scenarios, the pinned taste@1 design probe (16/16 passed) and an axe scan (zero violations in the checked page state). Browser scenarios cover purchase/approval ordering, an allowance already in place, wallet refusal, a closing round during approval, finalize, claims, multiplier redemption, paused refunds, wrong-chain switching, transfer filters, RPC failure/retry and the mobile wallet picker. They use intercepted test providers and never sign or broadcast real transactions.

The export was served under `/preview/` and inspected with the supplied browser tool. Chromium reflow was checked at 320, 390, 620, 760, 980 and 1440px; the opening 390×844 screen includes the game and buy action. WebKit binaries downloaded but could not launch because this runtime lacks its system libraries. Physical wallet apps, actual Coinbase passkeys, a live Privy login without an app ID, native zoom and screen-reader sessions were not exercised. Public RPC requests sometimes returned HTTP 403/400 during the supplied browser session; the UI's recovery state and assigned Ethereum reads were checked separately.

Actual results, six-domain Better Interface coverage, corrections and limitations are in **[artifacts/validation.md](artifacts/validation.md)**. The implemented design system is in **[DESIGN.md](DESIGN.md)**. The contract ABI/runtime can be rechecked with Foundry installed:

```bash
node frontend/scripts/verify-contract.mjs --offline  # compiled source and committed ABI
node frontend/scripts/verify-contract.mjs            # also verify deployed Ethereum code
```

```
src/IMDPot.sol                      the game (single contract, ~14 KB runtime)
src/libraries/WeightedTree.sol      O(log n) weighted selection without replacement (Fenwick tree)
src/interfaces/IVRFCoordinatorV2Plus.sol  minimal Chainlink VRF v2.5 interface + request encoding
script/DeployIMDPot.s.sol           reviewable deploy helper (tests call `deploy(owner)` directly)
test/                               75 Foundry tests: flows, attacks, fuzz, invariants
frontend/                           React + TypeScript dashboard, wallet connectors, source and npm lockfile
dist/                               complete static production export
DESIGN.md                           implemented interface system
artifacts/validation.md             worker checks, design review and limitations
docs/SECURITY.md                    threat model, trust assumptions, review notes
```

## Game rules

| Rule | Implementation |
| --- | --- |
| Only $IMD | `setToken` is called once by the owner; `buyTickets` pulls `count × ticketPrice` of that token and nothing else. |
| Minimum ticket 0.1 IMD | `ticketPrice = 10^decimals / 10`; tickets are whole numbers, so 0.1 IMD is the minimum and the unit. |
| 15-minute rounds | `ROUND_DURATION = 15 minutes`. `endTime = startTime + 15 min`, tickets close exactly at `endTime`. |
| Timer starts with the first deposit | A round is `Open` (no timer) until the first `buyTickets`; later purchases never extend it. |
| No deposit, no round | An `Open` round stays open indefinitely; nothing can finalize or cancel it. |
| Anyone finalizes | `finalizeRound()` after `endTime` requests a Chainlink VRF random word (status `Drawing`). |
| Automatic settlement | The VRF callback `rawFulfillRandomWords` atomically: picks the top 3, credits 40/20/10% as claimable, pushes 10% to `0x…dEaD`, pushes 5% to the treasury `0x0b176115c1Bd31a782133100d3aaA6BE2b16F118`, locks 15%, and opens the next round. |
| 15% locked forever | `totalLocked` only increases. No function in the contract can transfer $IMD except `claim`, `refund` and the two fee pushes, each bounded by its own accounting. `rescueForeignToken` refuses the game token. |
| Loyalty points | 1 point per ticket in every **finalized** round, credited lazily on the player's next action or via `syncPoints`. Points are a mapping, not a token: non-transferable and never convertible to $IMD. |
| Multiplier | After 10 finalized rounds, `redeemMultiplier` burns 100 points for +25% ticket weight on the player's *next* round, stackable to +100% (2× chances). It changes selection weight only, never the prize split or the points earned. |
| Equal chance per ticket | Three winning **tickets** are drawn without replacement: draw k uses `keccak256(randomWord, k) mod remainingWeight`, and only the drawn ticket's weight (`10_000 + boost`) leaves the tree before the next draw. A player holding several tickets can take more than one podium place, and splitting a stake over many addresses changes nothing. |
| Fewer than 3 tickets | Missing podium slots roll up to first place (1 ticket → 70%, 2 tickets → 50% / 20%). With 3+ tickets every slot is filled, possibly by the same player. |
| Rounding | Every share rounds down; the lock absorbs the dust, so `prizes + burn + fee + locked == pool` exactly. |

### Round lifecycle

```
Open ──first ticket──▶ Active ──endTime, finalizeRound()──▶ Drawing ──VRF callback (any request)──▶ Finalized
                          │                                    │  ▲
                          │                                    │  └── retryRandomness() after 1 h adds a request (max 4)
                          │                                    │
                          │              endTime + 24 h AND latest request + 24 h, cancelRound()
                          │                                    └──▶ Cancelled (refund(roundId) per player)
                          └── endTime + 24 h, cancelRound(): tries to request randomness first ──▶ Drawing,
                              and only cancels if the coordinator rejects the request (or the game is paused)
```

* **Every randomness request of a round stays valid.** `retryRandomness()` adds a request instead of replacing
  the previous one, so whichever word the coordinator delivers first settles the round. A participant who sees a
  delayed fulfillment in the mempool cannot void it by re-requesting. Requests are capped at
  `MAX_RANDOMNESS_REQUESTS = 4` per round so the owner's VRF spend is bounded and cancellation eventually opens.
* **`Cancelled` is the only escape hatch** and is permissionless and time-locked: 24 hours after the round's end
  *and* 24 hours after its latest randomness request, so a request whose word might already be known can never be
  aborted. A round nobody finalised cannot be cancelled to dodge the draw: `cancelRound()` on an `Active` round first
  requests randomness and only cancels when the coordinator rejects the request (subscription unfunded or
  misconfigured) or the game is paused. Cancelled tickets are refunded 1:1; a multiplier spent on that round is
  restored, and any part of it that no longer fits under the cap is returned as the points it cost.
* A fulfillment for an unknown request id, for a round already settled or cancelled, or with no words is ignored
  with `StaleRandomnessIgnored` and never changes state.
* Burn and treasury pushes use a non-reverting transfer; if the token refuses them (paused token, blocked
  recipient) the amounts accrue to `pendingBurn`/`pendingTreasury` and anyone can `flushPendingFees()`, which
  pushes each leg independently. The settlement itself therefore never reverts inside the VRF callback.

## Security design

See [docs/SECURITY.md](docs/SECURITY.md) for the full threat model. In short:

* **Reentrancy**: `nonReentrant` on every function that moves tokens or mutates round state, plus
  checks-effects-interactions everywhere; tested with a hook token that re-enters `claim`, `refund`, `buyTickets`.
* **Randomness**: Chainlink VRF v2.5 only. The callback is restricted to the configured coordinator, the request id
  must belong to the round being drawn, and the coordinator, subscription and key hash can only change while the
  current round has **no tickets**, so nobody enters under one randomness source and is drawn under another (the
  owner may raise the callback gas limit or confirmations at any time; neither influences the word). No
  `block.timestamp`, `blockhash` or `prevrandao` is ever used for selection, and once a request is out neither a
  retry nor a cancellation can discard its word.
* **Front-running / late entry**: tickets close at `endTime` strictly before randomness can be requested, so the
  outcome is unknowable while entry is possible. Finalizing is permissionless and idempotent.
* **Flash loans**: tokens are custodied until the draw or a cancellation; nothing can be withdrawn in the same block.
* **Fee-on-transfer / lying tokens**: `buyTickets` measures the balance delta and reverts on any shortfall;
  outbound transfers use `SafeERC20`.
* **Access control**: `Ownable2Step` with the owner passed as the only constructor argument (never the deployer).
  Owner powers are limited to configuration, pause and rescuing foreign tokens. `renounceOwnership` is disabled:
  the owner is the only account that can unpause or follow a coordinator migration.
* **Pause**: blocks `buyTickets`, `finalizeRound`, `retryRandomness`. `claim`, `refund`, `cancelRound` and the VRF
  callback keep working so user funds are never trapped by the pause.
* **Arithmetic**: Solidity 0.8 checked math, multiply-before-divide in basis points, dust absorbed by the lock.
* **Denial of service**: no unbounded loops over participants (Fenwick tree); prizes are pull-based; settlement
  gas grows logarithmically with participants: ≈ 560k at 200 one-ticket players, ≈ 630k worst case at 2048 and
  ≈ 635k at 4096 (measured over 24 and 8 random words). The accepted callback gas floor is 750k and the owner can
  raise the limit mid-round if a fulfillment ever runs out of gas.
* **Launch constraints**: constructor makes no external call, runtime is ~14 KB (< 24,576), no
  `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`, all library functions internal, `bytecode_hash = "none"`.

## Build and test

```bash
forge build
FOUNDRY_FUZZ_SEED=0x3536c5d1688abacdecb4ee8dfcee5e1c2d326e82736be69c3cd737ff8552c9e5 forge test
forge fmt --check
```

Dependencies are vendored as plain files in `lib/` (OpenZeppelin Contracts v5.4.0, forge-std v1.9.7); no submodules,
no network needed. Compiler pinned to `solc = "0.8.26"` in `foundry.toml`.

## Deployment

The IMD launch factory deploys `IMDPot` from its bytecode with a single constructor argument:

| Argument | Value |
| --- | --- |
| `owner_` | `$owner` (`0x34284C5C4c54d5f8e7E14E2D1a3DcD48899928EA`) |

Fixed values are constants in the contract: treasury `0x0b176115c1Bd31a782133100d3aaA6BE2b16F118`, burn address
`0x000000000000000000000000000000000000dEaD`, shares 40/20/10/10/5/15, 15-minute rounds.

`script/DeployIMDPot.s.sol` is a rehearsal helper: `deploy(address owner)` is what the tests call; `run()` reads
`IMDPOT_OWNER` from the environment. The worker never broadcasts; IMD's deployer launches through the factory.

### After launch (owner responsibilities)

The game refuses tickets (`TokenNotConfigured` / `VrfNotConfigured`) until both settings below are in place.

1. **`setToken(address imd)`** — once, irreversible. Set to the $IMD ERC-20 contract on Ethereum mainnet (the
   requester's token; the brief did not include its address, so it is an owner setting rather than a guess).
   The contract reads `decimals()` and derives the 0.1 IMD ticket price.
2. **`setVrfConfig(coordinator, subscriptionId, keyHash, callbackGasLimit, requestConfirmations, nativePayment)`**
   * `coordinator`: Chainlink's published **VRF v2.5 coordinator for Ethereum mainnet** (look it up in Chainlink's
     VRF "Supported networks" documentation; verify the address has code and check it against the docs before setting).
   * `subscriptionId`: a VRF v2.5 subscription created at vrf.chain.link by the owner, funded with LINK (or ETH with
     `nativePayment = true`), **with the IMDPot address added as a consumer**.
   * `keyHash`: the gas-lane key hash published alongside the coordinator.
   * `callbackGasLimit`: `1_000_000` recommended (settlement measures ≈ 630k worst case at 2048 participants;
     allowed range 750k–2.5M). Chainlink v2.5 bills the gas actually used, so headroom costs nothing.
   * `requestConfirmations`: `3` (the coordinator's minimum) unless a deeper reorg margin is wanted.
   * This setter only works while the current round has no tickets (`RoundNotIdle` otherwise).
   * **`setVrfRequestParams(callbackGasLimit, requestConfirmations)`** adjusts only these two values and works at
     any time, including mid-round, so a round whose fulfillment ran out of gas (or whose confirmations the
     coordinator rejects) is rescued by the next `retryRandomness` instead of waiting for cancellation.
3. **Keep the subscription funded.** Each round costs one VRF request, plus one per retry (at most 4 per round). If
   requests revert, `finalizeRound` reverts, and 24 hours after the round end anyone can cancel it for refunds
   (`cancelRound` re-tries the request first and only cancels if the coordinator still rejects it).
4. **Operate the keeper (optional).** `finalizeRound`, `retryRandomness`, `cancelRound`, `flushPendingFees` and
   `syncPoints` are permissionless; the frontend exposes them, and a cron/keeper can call them for better UX. A
   keeper that calls `finalizeRound` promptly keeps the cancellation window as far away as possible.
5. **Ownership**: transfer the owner to a multisig with `transferOwnership` + `acceptOwnership` (two-step).
   `renounceOwnership` is disabled on purpose.
6. **Frontend**: the verified deployment and Ethereum network are already pinned in `frontend/src/config.ts`.
   Build and serve `dist/` as described above. The owner's optional public Privy app ID is set in
   `frontend/public/site-config.json`; the SDK and embedded-wallet bridge are included in this export.

### Chosen constants (open numbers in the brief)

| Constant | Value | Why |
| --- | --- | --- |
| `MAX_TICKETS_PER_PURCHASE` | 1,000,000 | Input sanity bound; 100k IMD per transaction. |
| `VRF_RETRY_DELAY` | 1 hour | Chainlink normally fulfils in minutes; after an hour anyone may add a second request (the first stays valid). |
| `MAX_RANDOMNESS_REQUESTS` | 4 per round | Bounds the owner's VRF spend from permissionless retries and guarantees the cancel window eventually opens (at most ~27 h after the first request). |
| `CANCEL_DELAY` | 24 hours after `endTime` and after the latest request | Long enough that cancellation is a genuine last resort and that no in-flight word can be discarded, short enough that funds are never stuck. |
| `ROUNDS_FOR_MULTIPLIER` | 10 | From the brief. |
| `MULTIPLIER_COST_POINTS` | 100 points (= 10 IMD of tickets) | Keeps redemption meaningful. |
| `MULTIPLIER_STEP_BPS` / `MAX_MULTIPLIER_BONUS_BPS` | +25% per redemption, cap +100% | Extra chances without letting a loyal whale dominate. |
| `MIN_/MAX_CALLBACK_GAS_LIMIT` | 750k–2.5M | Settlement measures ≈ 630k worst case at 2048 participants and ≈ 635k at 4096 (≈ +5–20k per doubling), so 750k covers any round mainnet can fill in 15 minutes; 2.5M is Chainlink's ceiling. |

## Assumptions and open items

* $IMD is a standard ERC-20 (18 decimals expected, any 1–36 handled) without transfer fees to or from the pot.
  A fee-on-transfer token makes `buyTickets` revert by design. With 18 decimals the ticket price (1e17) is divisible
  by 20, so every share is exact; with a 1- or 2-decimal token the 5%/10%/third-prize shares of tiny pools round
  down to zero and the dust goes to the lock (a drawn third-place ticket can then be credited 0). $IMD has 18
  decimals, so this is documented rather than guarded.
* The Chainlink coordinator and key hash are not hard-coded because no verified chain reference was available to
  this build; they are owner settings with validation and events. Until set, the game is closed.
* Tests use `MockVRFCoordinator`, which demonstrates the contract's behaviour under delivery, late delivery, missing
  delivery and revert, **not** production randomness.
* Tests passing is not an audit. This contract custodies user funds and should receive an independent adversarial
  review before launch; see `docs/SECURITY.md` for the reviewer checklist and known trust assumptions.
