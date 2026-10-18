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
* **Split exactness**: `prizes == 70%`, `burn == 10%`, `fee == 5%`, `lock == remainder`; one drawn ticket per
  podium slot, never more slots per player than tickets held
  (`invariant_prizesSumToSeventyPercentAndSlotsAreFilledByTickets`).

## Threat model and mitigations

| Threat | Mitigation | Test |
| --- | --- | --- |
| Reentrancy through token hooks | `nonReentrant` on `buyTickets`, `finalizeRound`, `retryRandomness`, `cancelRound`, `claim`, `refund`, `redeemMultiplier`, `flushPendingFees`, `rawFulfillRandomWords`; effects before interactions | `test_reentrancy_*` |
| Randomness injection | Only `vrfConfig.coordinator` may call the callback; request id must belong to the round being drawn; unknown or settled ids ignored | `test_fulfill_onlyCoordinator`, `test_randomness_*` |
| Re-rolling a visible word with `retryRandomness` | Every request of the round stays valid (`requestRound` mapping); the first fulfillment settles; retries capped at 4 | `test_randomness_retryCannotVoidPendingFulfillment`, `test_retry_*` |
| Discarding a visible word with `cancelRound` | Cancel requires 24 h since the round end **and** since the latest request | `test_randomness_cancelCannotDiscardFreshRequest`, `test_cancel_requiresDelaySinceEndAndSinceLatestRequest` |
| Dodging the draw by never finalising | `cancelRound` on an `Active` round requests randomness first; refunds only if the coordinator rejects the request or the game is paused | `test_cancel_activeRoundRequestsRandomnessInsteadOfRefunding`, `test_cancel_activeRoundWhilePausedRefundsWithoutRequesting` |
| Sybil splitting of a stake | Draws are per ticket without replacement; a player may fill several slots, so address count is irrelevant | `test_settlement_splittingAStakeAcrossAddressesGivesNoEdge`, `testFuzz_settlement_drawsThreeTicketsWithoutReplacement` |
| Owner swaps coordinator mid-round | `setVrfConfig` requires the current round to have no tickets; `setVrfRequestParams` can only change gas limit and confirmations | `test_randomness_ownerCannotSwapCoordinatorMidRound`, `test_retry_usesUpdatedRequestParams` |
| Late entry after the draw is predictable | Tickets close at `endTime`; VRF is requested only after `endTime` | `test_randomness_lateEntryAfterEndIsImpossible`, `test_buy_closesExactlyAtEndTime` |
| Front-running `finalizeRound` | Permissionless and outcome-independent: the caller learns nothing | by construction |
| Timestamp nudging | Only used for the 15-minute window and the 1h/24h safety delays; never for selection | by construction |
| Flash-loan entry | Funds leave only after the draw (claim) or 24 h cancellation (refund) | `test_custody_flashLoanStyleEntryCannotExitInSameBlock` |
| Fee-on-transfer / rebasing token | Balance-delta check reverts on shortfall; donations never change obligations | `test_buy_rejectsFeeOnTransferShortfall`, `test_custody_directDonationDoesNotChangeObligations` |
| Reverting fee recipient blocks settlement | Non-reverting push with deferral to `pendingBurn`/`pendingTreasury`; `flushPendingFees` pushes each leg independently | `test_settlement_defersFeesWhenRecipientIsBlocked`, `test_settlement_survivesFrozenToken`, `test_flush_legsAreIndependent` |
| Reverting prize recipient | Pull-based `claim` | `test_claim_paysWinnersOnceAndOnlyWinners` |
| Unbounded gas in callback | Fenwick tree: O(log n) per operation; settlement ≈ 560k at 200, ≈ 630k worst at 2048, ≈ 635k at 4096 participants; floor 750k; owner can raise the limit mid-round | `test_fulfill_fitsWithinCallbackGasForManyParticipants`, `test_fulfill_fitsWithinMinimumCallbackGasWith2048Participants`, `test_retry_usesUpdatedRequestParams` |
| VRF outage | `retryRandomness` after 1 h (adds a request, max 4); `cancelRound` + `refund` 24 h after end and latest request; stale deliveries ignored | `test_retry_*`, `test_cancel_*`, `test_randomness_staleWordAfterCancelIsIgnored` |
| Coordinator reverts at request time | `finalizeRound` reverts cleanly; round stays `Active`; `cancelRound` after 24 h re-tries the request and refunds only if it still fails | `test_finalize_revertsWhenCoordinatorRejects`, `test_cancel_whenCoordinatorIsBrokenRefundsEveryone` |
| Access control | `Ownable2Step`; owner from constructor argument; setters validated; `renounceOwnership` disabled | `test_setToken_*`, `test_setVrfConfig_*`, `test_ownership_isTwoStep`, `test_ownership_cannotBeRenounced` |
| Points lost on refund after re-redeeming | Boost above the cap is converted back into points in `refund` | `test_refund_returnsPointsForBoostAboveCap` |
| Draining via rescue | `rescueForeignToken` refuses the game token | `test_rescue_onlyForeignTokensAndOnlyOwner` |
| Integer overflow | 0.8 checked math; weights are `tickets × (10_000 + boost)` with `tickets ≤ 1e6` per purchase | fuzz + invariants |
| A ticket drawn twice | One ticket's weight leaves the tree after each draw | `testFuzz_settlement_drawsThreeTicketsWithoutReplacement`, `test_subtractTakesPartOfALeaf` |
| Multiplier inflating prizes or points | Multiplier only changes tree weight | `test_redeem_stacksToCapAndBoostsOnlyChancesNotPrize` |
| Points withdrawn as tokens | No code path converts points to tokens | `test_points_cannotBeWithdrawnAsTokens` |
| Launch floor | Constructor has no external calls; runtime < 24,576 bytes; no DELEGATECALL/CALLCODE/SELFDESTRUCT | `test_constructor_runsOnEmptyChainAndFitsSizeLimits` |

## Trust assumptions (documented, intentional)

* **Owner** can pause entries and finalisation. While paused, a round that has ended cannot be finalised; after
  24 hours anyone can cancel it and players get refunds (that round's burn, fee and lock are forgone). The owner
  cannot influence the outcome of a round that has a request out, take funds, change fees or move the lock, and
  cannot renounce ownership. Recommend a multisig owner.
* **Owner** sets the Chainlink coordinator. A malicious coordinator address would let its controller choose the
  random word for rounds entered *after* the change (the change is only possible with no tickets in the round and
  emits `VrfConfigSet`). Players and watchers should verify the coordinator matches Chainlink's published address;
  the contract NatSpec states this trust assumption too. The owner may change the callback gas limit and
  confirmations at any time; neither can influence the delivered word.
* **Chainlink VRF** liveness. Outages degrade to refunds, never to loss. Every request of a round stays valid, so
  a late fulfillment is honoured rather than discarded; at most 4 requests are paid per round.
* **$IMD token** is assumed to be a standard ERC-20 without hooks or fees. A token with a transfer hook could try to
  re-enter; guards make that revert.

## Known limitations

* A whale buying most tickets has proportionally most chances and may take several podium places; that is the
  brief's "equal chance per ticket". Winners are tickets, not addresses, so the podium is not guaranteed to show
  three different players.
* With fewer than three tickets the unfilled podium shares go to first place (documented choice).
* With a token of 1–2 decimals the small shares of tiny pools truncate to zero (dust goes to the lock); $IMD has 18
  decimals, where every share is exact.
* Points are credited lazily (on the player's next interaction or `syncPoints`); `getPlayer` already shows them.
* Rounds cannot be cancelled by anyone before 24 hours after the end and 24 hours after the latest randomness
  request, even by the owner. This is deliberate so a pending draw can never be aborted once its random word
  might be known. Because retries are capped at 4 and need an hour between them, the cancel window opens at the
  latest ~27 hours after the first request.
* A paused game lets a round be cancelled 24 hours after its end without a draw. This is the pause's documented
  cost: the owner can forgo one round's fees, never take or trap funds.

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
