# IMDPot

A fast, provably fair 15-minute jackpot played only with the **$IMD** token. The platform never risks its own
capital: every round is funded entirely by ticket sales and the house earns a fixed 5% fee.

```
src/IMDPot.sol                      the game (single contract, ~14 KB runtime)
src/libraries/WeightedTree.sol      O(log n) weighted selection without replacement (Fenwick tree)
src/interfaces/IVRFCoordinatorV2Plus.sol  minimal Chainlink VRF v2.5 interface + request encoding
script/DeployIMDPot.s.sol           reviewable deploy helper (tests call `deploy(owner)` directly)
test/                               61 Foundry tests: flows, attacks, fuzz, invariants
frontend/                           static casino-style web app (ethers.js vendored, any EIP-1193 wallet, Privy hook)
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
| Equal chance per ticket | Selection is weight-proportional, without replacement: draw k uses `keccak256(randomWord, k) mod remainingWeight`, and a drawn player's whole weight is removed before the next draw, so the three winners are always distinct. |
| Fewer than 3 players | Missing podium slots roll up to first place (1 player → 70%, 2 players → 50% / 20%). |
| Rounding | Every share rounds down; the lock absorbs the dust, so `prizes + burn + fee + locked == pool` exactly. |

### Round lifecycle

```
Open ──first ticket──▶ Active ──endTime, finalizeRound()──▶ Drawing ──VRF callback──▶ Finalized
                          │                                    │  ▲
                          │                                    │  └── retryRandomness() after 1 h (new request id)
                          └──── endTime + 24 h, cancelRound() ─┴──▶ Cancelled (refund(roundId) per player)
```

* `Active`/`Drawing` → `Cancelled` is the only escape hatch and is permissionless, time-locked and only reachable
  when randomness has not arrived for 24 hours after the round ended (coordinator reverting, subscription unfunded,
  callback gas too low, oracle outage). Cancelled tickets are refunded 1:1; a multiplier spent on that round is restored.
* A fulfillment that arrives for a superseded request id, after a cancel, or with no words is ignored with
  `StaleRandomnessIgnored` and never changes state.
* Burn and treasury pushes use a non-reverting transfer; if the token refuses them (paused token, blocked
  recipient) the amounts accrue to `pendingBurn`/`pendingTreasury` and anyone can `flushPendingFees()`. The
  settlement itself therefore never reverts inside the VRF callback.

## Security design

See [docs/SECURITY.md](docs/SECURITY.md) for the full threat model. In short:

* **Reentrancy**: `nonReentrant` on every function that moves tokens or mutates round state, plus
  checks-effects-interactions everywhere; tested with a hook token that re-enters `claim`, `refund`, `buyTickets`.
* **Randomness**: Chainlink VRF v2.5 only. The callback is restricted to the configured coordinator, the request id
  must match the live request, and the VRF configuration can only change while the current round has **no tickets**,
  so nobody enters under one randomness source and is drawn under another. No `block.timestamp`, `blockhash` or
  `prevrandao` is ever used for selection.
* **Front-running / late entry**: tickets close at `endTime` strictly before randomness can be requested, so the
  outcome is unknowable while entry is possible. Finalizing is permissionless and idempotent.
* **Flash loans**: tokens are custodied until the draw or a cancellation; nothing can be withdrawn in the same block.
* **Fee-on-transfer / lying tokens**: `buyTickets` measures the balance delta and reverts on any shortfall;
  outbound transfers use `SafeERC20`.
* **Access control**: `Ownable2Step` with the owner passed as the only constructor argument (never the deployer).
  Owner powers are limited to configuration, pause and rescuing foreign tokens.
* **Pause**: blocks `buyTickets`, `finalizeRound`, `retryRandomness`. `claim`, `refund`, `cancelRound` and the VRF
  callback keep working so user funds are never trapped by the pause.
* **Arithmetic**: Solidity 0.8 checked math, multiply-before-divide in basis points, dust absorbed by the lock.
* **Denial of service**: no unbounded loops over participants (Fenwick tree); prizes are pull-based; settlement
  gas is roughly 400k–540k regardless of participant count (measured with 1, 3, 40 and 200 participants).
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
   * `callbackGasLimit`: `750_000` recommended (settlement measures ≈ 400k–540k; allowed range 600k–2.5M).
   * `requestConfirmations`: `3` (the coordinator's minimum) unless a deeper reorg margin is wanted.
   * This setter only works while the current round has no tickets (`RoundNotIdle` otherwise).
3. **Keep the subscription funded.** Each round costs one VRF request. If requests revert, `finalizeRound` reverts,
   and after 24 hours anyone can cancel the round for refunds.
4. **Operate the keeper (optional).** `finalizeRound`, `retryRandomness`, `cancelRound`, `flushPendingFees` and
   `syncPoints` are permissionless; the frontend exposes them, and a cron/keeper can call them for better UX.
5. **Ownership**: transfer the owner to a multisig with `transferOwnership` + `acceptOwnership` (two-step).
6. **Frontend**: set `contractAddress`, `chainId`, optionally `readRpcUrl` and `privyAppId` in `frontend/config.js`
   and host the `frontend/` folder statically. Any EIP-6963/EIP-1193 wallet works out of the box; a Privy or other
   SDK provider plugs in through `window.imdpot.connectProvider(provider)`.

### Chosen constants (open numbers in the brief)

| Constant | Value | Why |
| --- | --- | --- |
| `MAX_TICKETS_PER_PURCHASE` | 1,000,000 | Input sanity bound; 100k IMD per transaction. |
| `VRF_RETRY_DELAY` | 1 hour | Chainlink normally fulfils in minutes; a stuck request can be re-issued by anyone. |
| `CANCEL_DELAY` | 24 hours after `endTime` | Long enough that cancellation is a genuine last resort, short enough that funds are never stuck. |
| `ROUNDS_FOR_MULTIPLIER` | 10 | From the brief. |
| `MULTIPLIER_COST_POINTS` | 100 points (= 10 IMD of tickets) | Keeps redemption meaningful. |
| `MULTIPLIER_STEP_BPS` / `MAX_MULTIPLIER_BONUS_BPS` | +25% per redemption, cap +100% | Extra chances without letting a loyal whale dominate. |
| `MIN_/MAX_CALLBACK_GAS_LIMIT` | 600k–2.5M | Below 600k settlement can run out of gas; 2.5M is Chainlink's ceiling. |

## Assumptions and open items

* $IMD is a standard ERC-20 (18 decimals expected, any 1–36 handled) without transfer fees to or from the pot.
  A fee-on-transfer token makes `buyTickets` revert by design.
* The Chainlink coordinator and key hash are not hard-coded because no verified chain reference was available to
  this build; they are owner settings with validation and events. Until set, the game is closed.
* Tests use `MockVRFCoordinator`, which demonstrates the contract's behaviour under delivery, late delivery, missing
  delivery and revert, **not** production randomness.
* Tests passing is not an audit. This contract custodies user funds and should receive an independent adversarial
  review before launch; see `docs/SECURITY.md` for the reviewer checklist and known trust assumptions.
