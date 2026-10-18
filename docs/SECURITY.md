# IMDPot security notes

This document describes **`src/IMDPot.sol` in this revision**. It is not a third-party audit. The verified live Ethereum deployment still runs the legacy code reproduced in `test/legacy/LegacyIMDPot.sol`. Source changes cannot upgrade that immutable contract, and no mainnet transaction was sent by this assignment.

## Future-blockhash lifecycle

`Open` has no timer. The first token deposit creates `Active`, with a fixed deadline 900 seconds later. Ticket purchases are rejected at the deadline, including before anybody finalizes.

The first permissionless `finalizeRound()` after the deadline moves the round to `Drawing` and records `block.number + 3`. This target is immutable. No current hash, caller-supplied random word, timestamp or `prevrandao` is used to pick winners. A second call can settle only when the committed target is a past block and still lies within the 256-block EVM lookup window.

The entropy is `keccak256(abi.encode(blockhash(drawBlock), block.chainid, address(this), roundId))`. Settlement stores both the target hash and derived word for later audit. Neither the settlement caller nor its timestamp/block number enters the seed. A zero/missing hash reverts; it is never used as a fallback seed.

The contract has no coordinator, oracle subscription, LINK payment, randomness callback or retry/re-roll entrypoint. Callers pay ordinary transaction gas for commitment and settlement. Permissionless settlement is required; there is no claim of automatic background execution.

## Trust and manipulation limits

**A future blockhash is not cryptographically unbiased randomness.** A block proposer/builder can influence the target hash, withhold a block or censor calls. Ethereum reorganizations can also change the target or settlement. Domain separation prevents cross-round/deployment seed reuse; it does not remove validator influence. This implements the requested inexpensive method without claiming VRF-level guarantees. Solidity explicitly warns about blockhash randomness: [block properties](https://docs.soliditylang.org/en/v0.8.26/units-and-global-variables.html#block-and-transaction-properties).

Once the target exists, every observer can calculate the outcome. A losing participant can refuse to settle, but cannot prevent others from doing so. If everybody withholds settlement or inclusion is censored until target + 257, the round becomes refundable. This permits selective abandonment at the community/validator level. There is deliberately no re-roll that an individual caller could use to search for a better result.

Owners cannot change the fixed three-block delay, choose an entropy provider, change prize shares, change a committed target, move the permanent lock or withdraw the game token. An owner can pause before a draw is committed. An already committed draw can settle while paused, so pause cannot veto a visible outcome. Claims, refunds and fee flushing also work while paused. Ownership is transferable using `Ownable2Step`; renunciation is disabled so a pause remains reversible.

## Recovery and accounting

| Situation | Behavior |
| --- | --- |
| Calling finalize before deadline | `RoundNotEnded`; no commitment |
| Calling again before/at target | `DrawNotReady`; existing target remains unchanged |
| Settlement at target + 1 through target + 256 | Uses the same target hash, regardless of caller or settlement timing |
| Settlement after target + 256 | `DrawExpired`; no fallback randomness |
| Expired commitment | Anyone can cancel, including while paused, and every ticket is fully refundable |
| Active round paused before commitment | After end + 24 hours, anyone can cancel for full refunds |
| Active unpaused round | Must commit a draw; cannot cancel to avoid one |
| Empty round | Never starts, finalizes or cancels |
| Burn or treasury token transfer fails | Settlement records independent pending balances; anyone can retry each leg with `flushPendingFees` |

Cancellation never distributes prizes or fees. Refunds zero the caller's ticket balance before transferring tokens, prevent duplicate withdrawals, and restore consumed multipliers. Boost exceeding the cap converts back into its point cost. Cancelled rounds earn no loyalty points.

The fixed pool split remains 40% / 20% / 10% prizes, 10% burn, 5% treasury and a permanent 15% lock including rounding dust. Fewer than three tickets roll unfilled prizes up to first place. Weighted Fenwick-tree selection removes one winning ticket at a time, preserving the player's remaining tickets. One wallet may win several slots only if it holds enough tickets.

`totalObligations()` includes the live round, all claims/refunds, locked tokens and pending fees. Test ledgers check token conservation and agreement with every finalized/cancelled round. No owner path rescues IMD. Incoming transfers must match the exact expected balance delta, rejecting fee-on-transfer behavior. Pull-based claims and bounded prize selection avoid loops over all winners/participants.

## Safeguards and evidence

| Property | Evidence in this revision |
| --- | --- |
| Future target and strict block boundaries | `test_firstFinalizeCommitsFutureBlockWithoutPayingOrSelectingWinners`, `test_cannotUseCurrentOrFutureHashAndCannotRerollCommitment`, `test_lastReadableBlockSettlesButCannotCancel` |
| No zero seed or re-roll | `test_missingHashNeverFallsBackToTimestampOrZero`, `test_expiredHashCannotSettleOrRerollButRefundsEntirePool` |
| Caller/timing independence | `test_settlementCallerAndTimingCannotAlterTheCommittedOutcome` |
| Owner cannot suppress a committed draw by pausing | `test_ownerPauseBlocksEntriesAndCommitmentButNotCommittedSettlementOrClaim`, `test_ownerCannotCancelReadableCommittedDrawEvenAfter24Hours` |
| Reentrancy protection | `nonReentrant` on entries, draw/settlement, cancellation, claim/refund, multiplier and fee flushing; `test_reentrancyDuringSettlementAndClaimCannotMutateTheRoundOrDrainFunds` |
| Prize accounting and valid winners | Fuzz test `testFuzz_settlementAccountsForEntirePoolAndDrawsOnlyExistingTickets` (256 runs), single/two-ticket tests, four stateful accounting invariants |
| Loyalty/refund consistency | `test_loyaltyRedemptionAndCancelledMultiplierRestoration` and accounting invariant ledgers |
| Access control | `test_onlyOwnerCanAdministerAndTokenCannotChange`; onchain `onlyOwner` plus fresh owner read before frontend admin writes |
| Fee transfer failures | `test_feeFailureDefersFeesWithoutBlockingSettlement` and stateful recipient blocking |
| Full interaction path | Production-export Playwright checks against actual compiled code in a disposable local Anvil chain |

`test/FutureBlockhash.t.sol` and `test/FutureAccountingInvariant.t.sol` exercise the revised contract. Existing legacy tests remain bound to the historical snapshot and are regression evidence for that deployed version, not evidence for future-blockhash randomness. `test/WeightedTree.t.sol` tests the shared weighted selection library.

## Website boundary

The site verifies Ethereum chain ID and exact known runtime bytecode before reads and signed actions. It chooses the matching round ABI rather than decoding the revised struct against the legacy deployment. Unknown code fails closed. Legacy entries/draw requests are intentionally disabled; claims and eligible refunds continue against their original contract.

The owner panel requires an active wallet connection matching `owner()`. Visibility is not authorization: the contract still checks `onlyOwner`. Admin actions review consequences and refresh the owner before sending. Token setup selects the supplied network's real IMD token once; it never creates a new token.

Transactions simulate first, confirm account/network again, use exact purchase approval, recheck deadline/round after approval and require a successful receipt. Finalization also checks the reviewed round has not changed. UI error/stale gates are not substitutes for onchain checks. A user should verify transaction destinations in their wallet. Public RPCs and third-party wallet/auth services have their own availability limits.

## Remaining verification limits

The worker did not deploy or transact on mainnet, complete an email OTP login, use physical wallet apps/passkeys, perform a screen-reader session or commission an independent security audit. Local deterministic tests cannot establish resistance to validator/builder collusion, censorship or real consensus reorganization. Native-device and native browser zoom coverage is limited as recorded in `artifacts/validation.md`. No claim of guaranteed winnings, unbiased randomness or full accessibility compliance is made.
