# IMDPot security notes

## Assets and invariants

* **Custody**: `token.balanceOf(pot) >= totalLocked + totalClaimable + totalRefundable + pendingBurn + pendingTreasury + livePool`
  (`totalObligations()`); checked by `invariant_balanceCoversObligations` and in most unit tests.
* **Conservation**: every deposited wei is either held, burned, sent to the treasury, or paid out
  (`invariant_depositsAreFullyAccountedFor`).
* **Lock monotonicity**: `totalLocked` never decreases and no code path transfers it (`invariant_lockedNeverDecreases`,
  `test_custody_lockedTokensCanNeverLeave`).
* **Round integrity**: exactly one unsettled round exists at a time; every earlier round is `Finalized` or
  `Cancelled` (`invariant_currentRoundIsNeverSettled`).
* **Split exactness**: `prizes == 70%`, `burn == 10%`, `fee == 5%`, `lock == remainder`; winners distinct
  (`invariant_winnersAreDistinctAndPrizesSumToSeventyPercent`).

## Threat model and mitigations

| Threat | Mitigation | Test |
| --- | --- | --- |
| Reentrancy through token hooks | `nonReentrant` on `buyTickets`, `finalizeRound`, `retryRandomness`, `cancelRound`, `claim`, `refund`, `redeemMultiplier`, `flushPendingFees`, `rawFulfillRandomWords`; effects before interactions | `test_reentrancy_*` |
| Randomness injection | Only `vrfConfig.coordinator` may call the callback; request id must match; stale words ignored | `test_fulfill_onlyCoordinator`, `test_randomness_*` |
| Owner swaps coordinator mid-round | `setVrfConfig` requires the current round to have no tickets | `test_randomness_ownerCannotSwapCoordinatorMidRound` |
| Late entry after the draw is predictable | Tickets close at `endTime`; VRF is requested only after `endTime` | `test_randomness_lateEntryAfterEndIsImpossible`, `test_buy_closesExactlyAtEndTime` |
| Front-running `finalizeRound` | Permissionless and outcome-independent: the caller learns nothing | by construction |
| Timestamp nudging | Only used for the 15-minute window and the 1h/24h safety delays; never for selection | by construction |
| Flash-loan entry | Funds leave only after the draw (claim) or 24 h cancellation (refund) | `test_custody_flashLoanStyleEntryCannotExitInSameBlock` |
| Fee-on-transfer / rebasing token | Balance-delta check reverts on shortfall; donations never change obligations | `test_buy_rejectsFeeOnTransferShortfall`, `test_custody_directDonationDoesNotChangeObligations` |
| Reverting fee recipient blocks settlement | Non-reverting push with deferral to `pendingBurn`/`pendingTreasury` | `test_settlement_defersFeesWhenRecipientIsBlocked`, `test_settlement_survivesFrozenToken` |
| Reverting prize recipient | Pull-based `claim` | `test_claim_paysWinnersOnceAndOnlyWinners` |
| Unbounded gas in callback | Fenwick tree: O(log n) per operation; settlement ≈ 400k–540k gas at 1–200 participants | `test_fulfill_fitsWithinCallbackGasForManyParticipants` |
| VRF outage | `retryRandomness` after 1 h; `cancelRound` + `refund` after 24 h; stale deliveries ignored | `test_retry_*`, `test_cancel_*`, `test_randomness_staleWordAfterCancelIsIgnored` |
| Coordinator reverts at request time | `finalizeRound` reverts cleanly; round stays `Active`; cancel path after 24 h | `test_finalize_revertsWhenCoordinatorRejects`, `test_cancel_whenCoordinatorIsBrokenRefundsEveryone` |
| Access control | `Ownable2Step`; owner from constructor argument; setters validated | `test_setToken_*`, `test_setVrfConfig_*`, `test_ownership_isTwoStep` |
| Draining via rescue | `rescueForeignToken` refuses the game token | `test_rescue_onlyForeignTokensAndOnlyOwner` |
| Integer overflow | 0.8 checked math; weights are `tickets × (10_000 + boost)` with `tickets ≤ 1e6` per purchase | fuzz + invariants |
| Duplicate winners / self-pairing | Weight removal between draws | `testFuzz_settlement_winnersAreDistinctAndWeightsZeroed` |
| Multiplier inflating prizes or points | Multiplier only changes tree weight | `test_redeem_stacksToCapAndBoostsOnlyChancesNotPrize` |
| Points withdrawn as tokens | No code path converts points to tokens | `test_points_cannotBeWithdrawnAsTokens` |
| Launch floor | Constructor has no external calls; runtime < 24,576 bytes; no DELEGATECALL/CALLCODE/SELFDESTRUCT | `test_constructor_runsOnEmptyChainAndFitsSizeLimits` |

## Trust assumptions (documented, intentional)

* **Owner** can pause entries and finalisation. While paused, a round that has ended cannot be finalised; after
  24 hours anyone can cancel it and players get refunds. The owner cannot influence the outcome, take funds, change
  fees or move the lock. Recommend a multisig owner.
* **Owner** sets the Chainlink coordinator. A malicious coordinator address would let its controller choose the
  random word for rounds entered *after* the change (the change is only possible with no tickets in the round and
  emits `VrfConfigSet`). Players and watchers should verify the coordinator matches Chainlink's published address.
* **Chainlink VRF** liveness. Outages degrade to refunds, never to loss.
* **$IMD token** is assumed to be a standard ERC-20 without hooks or fees. A token with a transfer hook could try to
  re-enter; guards make that revert.

## Known limitations

* A whale buying most tickets has proportionally most chances; that is the brief's "equal chance per ticket".
* With fewer than three participants the unfilled podium shares go to first place (documented choice).
* Points are credited lazily (on the player's next interaction or `syncPoints`); `getPlayer` already shows them.
* Rounds cannot be cancelled by anyone before 24 hours after the end, even by the owner. This is deliberate so a
  pending draw can never be aborted once its random word might be known.

## Reviewer checklist (from the eth-security reference)

- [x] Access control on every privileged function; `Ownable2Step`.
- [x] Pausable trade-off flagged (above).
- [x] CEI + `nonReentrant` on all external-calling functions.
- [x] Decimals read from the token; no hard-coded `1e18`.
- [x] No price oracles / no DEX spot prices.
- [x] Multiply before divide; basis points.
- [x] `SafeERC20` for pulls and payouts; non-reverting push for fees.
- [x] Zero-address, zero-amount and bound checks on every public input.
- [x] Events on every state change.
- [x] Maintenance functions permissionless (`finalizeRound`, `retryRandomness`, `cancelRound`, `flushPendingFees`, `syncPoints`).
- [x] No infinite approvals requested by the frontend (exact per-purchase approvals).
- [x] Fee-on-transfer safe (reverts).
- [x] Not upgradeable; no delegatecall; no signatures.
- [x] Fuzz + invariant tests run with the verifier's seed.
- [ ] Slither / Mythril: not available in this environment; run before launch.
- [ ] Independent adversarial review before release.
- [ ] Source verification on Etherscan after the launch (`forge verify-contract`).
