// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMDPotBase} from "./IMDPotBase.t.sol";
import {IMDPot} from "../src/IMDPot.sol";
import {MockIMDToken} from "./mocks/MockIMDToken.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IVRFConsumerV2Plus, VRFV2PlusClient} from "../src/interfaces/IVRFCoordinatorV2Plus.sol";

/// @notice Boundary values, repeated calls and wrong callers that the main suites do not pin down.
contract IMDPotEdgesTest is IMDPotBase {
    // ------------------------------------------------------------------ timing boundaries

    function test_finalize_boundaryIsExactlyEndTime() public {
        _buy(alice, 1);
        uint64 end = pot.getRound(1).endTime;
        vm.warp(end - 1);
        assertEq(pot.timeRemaining(), 1);
        vm.expectRevert(IMDPot.RoundNotEnded.selector);
        pot.finalizeRound();
        vm.warp(end);
        assertEq(pot.timeRemaining(), 0);
        pot.finalizeRound();
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Drawing));
    }

    function test_finalize_twiceReverts() public {
        _buy(alice, 1);
        _finalize();
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.finalizeRound();
        assertEq(coordinator.nextRequestId(), 2, "only one request was made");
    }

    function test_finalize_afterSettlementRevertsForEmptyNextRound() public {
        _buy(alice, 1);
        _finalizeAndFulfill(7);
        assertEq(pot.currentRoundId(), 2);
        assertEq(uint8(pot.getRound(2).status), uint8(IMDPot.RoundStatus.Open));
        vm.warp(block.timestamp + 365 days);
        // A round nobody enters never starts, so it can never be finalised or cancelled.
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.finalizeRound();
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.cancelRound();
        assertEq(pot.timeRemaining(), 0);
    }

    function test_retry_boundaryIsExactlyOneHourAfterRequest() public {
        _buy(alice, 1);
        _finalize();
        uint64 requestedAt = pot.getRound(1).randomnessRequestedAt;
        vm.warp(uint256(requestedAt) + 1 hours - 1);
        vm.expectRevert(IMDPot.RetryTooEarly.selector);
        pot.retryRandomness();
        vm.warp(uint256(requestedAt) + 1 hours);
        pot.retryRandomness();
        assertEq(pot.getRound(1).randomnessRequestedAt, block.timestamp);
        // The clock restarts with each retry.
        vm.expectRevert(IMDPot.RetryTooEarly.selector);
        pot.retryRandomness();
    }

    function test_nextRoundTimerStartsFromItsOwnFirstDeposit() public {
        _buy(alice, 1);
        _finalizeAndFulfill(1);
        vm.warp(block.timestamp + 3 hours);
        _buy(bob, 1);
        IMDPot.Round memory r2 = pot.getRound(2);
        assertEq(r2.startTime, block.timestamp);
        assertEq(r2.endTime, block.timestamp + 15 minutes);
    }

    // ------------------------------------------------------------------ fulfillment

    function test_fulfill_secondDeliveryOfSameRequestIsIgnored() public {
        _buy(alice, 1);
        _buy(bob, 1);
        uint256 requestId = _finalize();
        coordinator.fulfill(requestId, 5);
        uint256 claimableTotal = pot.totalClaimable();
        uint256 locked = pot.totalLocked();
        uint256 burned = token.balanceOf(DEAD);
        coordinator.fulfill(requestId, 6);
        assertEq(pot.totalClaimable(), claimableTotal);
        assertEq(pot.totalLocked(), locked);
        assertEq(token.balanceOf(DEAD), burned);
        assertEq(pot.getRound(1).randomWord, 5);
        _assertSolvent();
    }

    function test_fulfill_oldRequestCannotSettleALaterRound() public {
        _buy(alice, 1);
        uint256 first = _finalize();
        coordinator.fulfill(first, 1);
        _buy(bob, 1);
        _buy(carol, 1);
        uint256 second = _finalize();
        vm.expectEmit(true, false, false, false);
        emit IMDPot.StaleRandomnessIgnored(first);
        coordinator.fulfill(first, 2);
        assertEq(uint8(pot.getRound(2).status), uint8(IMDPot.RoundStatus.Drawing));
        coordinator.fulfill(second, 3);
        assertEq(uint8(pot.getRound(2).status), uint8(IMDPot.RoundStatus.Finalized));
    }

    function test_fulfill_ownerAndPlayersCannotCall() public {
        _buy(alice, 1);
        uint256 requestId = _finalize();
        uint256[] memory words = new uint256[](1);
        address[3] memory callers = [OWNER, alice, address(pot)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IMDPot.OnlyCoordinatorCanFulfill.selector, callers[i], address(coordinator))
            );
            pot.rawFulfillRandomWords(requestId, words);
        }
    }

    function test_fulfill_settlesWhilePaused() public {
        _buy(alice, 1);
        uint256 requestId = _finalize();
        vm.prank(OWNER);
        pot.pause();
        // Pausing never strands an in-flight draw: the owner cannot block a result they dislike.
        coordinator.fulfill(requestId, 9);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Finalized));
        vm.prank(alice);
        pot.claim();
    }

    function test_fulfill_extraWordsAreIgnoredOnlyFirstUsed() public {
        _buy(alice, 1);
        _buy(bob, 1);
        uint256 requestId = _finalize();
        uint256[] memory words = new uint256[](3);
        words[0] = 11;
        words[1] = 22;
        words[2] = 33;
        coordinator.fulfillRaw(address(pot), requestId, words);
        assertEq(pot.getRound(1).randomWord, 11);
    }

    // ------------------------------------------------------------------ cancel / refund

    function test_cancel_activeRoundRequestsFirstThenCancelsOnceOnly() public {
        _buy(alice, 1);
        _endRound();
        vm.warp(block.timestamp + 24 hours - 1);
        vm.expectRevert(IMDPot.CancelTooEarly.selector);
        pot.cancelRound();
        vm.warp(block.timestamp + 1);
        // An unfinalised round is drawn, not refunded, while the coordinator accepts requests.
        pot.cancelRound();
        IMDPot.Round memory r = pot.getRound(1);
        assertEq(uint8(r.status), uint8(IMDPot.RoundStatus.Drawing));
        assertEq(r.requestCount, 1);
        assertEq(pot.totalRefundable(), 0);
        uint256 requestId = r.vrfRequestId;
        // The fresh request gets its own full delay.
        vm.warp(uint256(r.randomnessRequestedAt) + 24 hours - 1);
        vm.expectRevert(IMDPot.CancelTooEarly.selector);
        pot.cancelRound();
        vm.warp(uint256(r.randomnessRequestedAt) + 24 hours);
        pot.cancelRound();
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Cancelled));
        // The current round is now an untouched round 2.
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.cancelRound();
        assertEq(pot.totalRefundable(), ticketPrice);
        // A word arriving after the cancel changes nothing.
        coordinator.fulfill(requestId, 1);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Cancelled));
        assertEq(pot.totalClaimable(), 0);
        _assertSolvent();
    }

    function test_cancel_worksWhilePausedAndRefundsWhilePaused() public {
        _buy(alice, 2);
        vm.prank(OWNER);
        pot.pause();
        _endRound();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pot.finalizeRound();
        vm.warp(block.timestamp + 24 hours);
        pot.cancelRound();
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        pot.refund(1);
        assertEq(token.balanceOf(alice) - before, 2 * ticketPrice);
    }

    function test_refund_revertsForEveryNonCancelledStatus() public {
        // Open (never started), and a round id that does not exist yet.
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(1);
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(0);
        // Active.
        _buy(alice, 1);
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(1);
        // Drawing.
        uint256 requestId = _finalize();
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(1);
        // Finalized.
        coordinator.fulfill(requestId, 1);
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(1);
    }

    function test_refund_cancelledRoundGivesNoPointsOrRoundCredit() public {
        _buy(alice, 50);
        _endRound();
        vm.warp(block.timestamp + 24 hours);
        // The coordinator rejects requests, so the round cannot be drawn and is cancelled for refunds.
        coordinator.setShouldRevert(true);
        pot.cancelRound();
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Cancelled));
        assertEq(pot.getRound(1).requestCount, 0);
        (uint256 points, uint256 rounds,,) = pot.getPlayer(alice);
        assertEq(points, 0);
        assertEq(rounds, 0);
        vm.prank(alice);
        pot.refund(1);
        pot.syncPoints(alice);
        (points, rounds,,) = pot.getPlayer(alice);
        assertEq(points, 0);
        assertEq(rounds, 0);
    }

    // ------------------------------------------------------------------ claims & fees

    function test_claim_nonWinnerAndNeverPlayedRevert() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IMDPot.NothingToClaim.selector);
        pot.claim();
        for (uint256 i; i < 4; ++i) {
            _buy([alice, bob, carol, dave][i], 1);
        }
        _finalizeAndFulfill(123);
        IMDPot.Round memory r = pot.getRound(1);
        address loser;
        address[4] memory all = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            if (all[i] != r.winners[0] && all[i] != r.winners[1] && all[i] != r.winners[2]) loser = all[i];
        }
        assertTrue(loser != address(0));
        vm.prank(loser);
        vm.expectRevert(IMDPot.NothingToClaim.selector);
        pot.claim();
    }

    function test_claim_blockedWinnerDoesNotBlockOthers() public {
        _buy(alice, 1);
        _buy(bob, 1);
        _buy(carol, 1);
        _finalizeAndFulfill(77);
        IMDPot.Round memory r = pot.getRound(1);
        token.setBlocked(r.winners[0], true);
        vm.prank(r.winners[0]);
        vm.expectRevert("blocked");
        pot.claim();
        // Failed claim is atomic: the prize is still owed.
        assertEq(pot.claimable(r.winners[0]), r.prizes[0]);
        vm.prank(r.winners[1]);
        pot.claim();
        vm.prank(r.winners[2]);
        pot.claim();
        token.setBlocked(r.winners[0], false);
        vm.prank(r.winners[0]);
        pot.claim();
        assertEq(pot.totalClaimable(), 0);
        assertEq(token.balanceOf(address(pot)), pot.totalLocked());
    }

    function test_flush_nothingPendingReverts() public {
        vm.expectRevert(IMDPot.NothingToFlush.selector);
        pot.flushPendingFees();
        _buy(alice, 10);
        _finalizeAndFulfill(1);
        vm.expectRevert(IMDPot.NothingToFlush.selector);
        pot.flushPendingFees();
    }

    function test_flush_stillBlockedKeepsFeePendingThenSucceeds() public {
        token.setBlocked(TREASURY, true);
        _buy(alice, 10);
        _finalizeAndFulfill(1);
        uint256 pool = 10 * ticketPrice;
        assertEq(pot.pendingTreasury(), (pool * 5) / 100);
        assertEq(pot.pendingBurn(), 0);
        assertEq(token.balanceOf(DEAD), pool / 10);

        // Still blocked: the flush does not revert, the treasury leg stays pending and nothing moves.
        vm.expectEmit(true, false, false, true);
        emit IMDPot.FeeTransferDeferred(TREASURY, (pool * 5) / 100);
        pot.flushPendingFees();
        assertEq(pot.pendingTreasury(), (pool * 5) / 100);
        assertEq(token.balanceOf(TREASURY), 0);
        _assertSolvent();

        token.setBlocked(TREASURY, false);
        vm.prank(alice);
        pot.flushPendingFees();
        assertEq(pot.pendingTreasury(), 0);
        assertEq(token.balanceOf(TREASURY), (pool * 5) / 100);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ loyalty

    function test_syncPoints_byThirdPartyOnlyCreditsTheTarget() public {
        _buy(alice, 7);
        _buy(bob, 3);
        _finalizeAndFulfill(1);
        vm.prank(carol);
        pot.syncPoints(alice);
        (uint256 aPoints, uint256 aRounds,,) = pot.getPlayer(alice);
        (uint256 cPoints, uint256 cRounds,,) = pot.getPlayer(carol);
        assertEq(aPoints, 7);
        assertEq(aRounds, 1);
        assertEq(cPoints, 0);
        assertEq(cRounds, 0);
        // Syncing twice credits once.
        pot.syncPoints(alice);
        (aPoints, aRounds,,) = pot.getPlayer(alice);
        assertEq(aPoints, 7);
        assertEq(aRounds, 1);
    }

    function test_points_multiplePurchasesInOneRoundCountAsOneRound() public {
        _buy(alice, 2);
        _buy(alice, 3);
        _buy(alice, 5);
        _finalizeAndFulfill(4);
        (uint256 points, uint256 rounds,,) = pot.getPlayer(alice);
        assertEq(points, 10);
        assertEq(rounds, 1);
        assertEq(pot.getRound(1).participantCount, 1);
        assertEq(pot.getParticipants(1).length, 1);
    }

    function test_redeem_tenRoundsButTooFewPoints() public {
        _playRounds(alice, 9, 10); // 90 points, 10 rounds
        (uint256 points, uint256 rounds,, bool canRedeem) = pot.getPlayer(alice);
        assertEq(points, 90);
        assertEq(rounds, 10);
        assertFalse(canRedeem);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.InsufficientPoints.selector, 90, 100));
        pot.redeemMultiplier();
    }

    function test_redeem_nineRoundsWithManyPointsRejected() public {
        _playRounds(alice, 500, 9);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.InsufficientRoundsPlayed.selector, 9, 10));
        pot.redeemMultiplier();
    }

    function test_redeem_atCapRevertsAndKeepsPoints() public {
        _playRounds(alice, 100, 10); // 1000 points
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            pot.redeemMultiplier();
        }
        (uint256 points,, uint256 boost, bool canRedeem) = pot.getPlayer(alice);
        assertEq(boost, pot.MAX_MULTIPLIER_BONUS_BPS());
        assertEq(points, 600);
        assertFalse(canRedeem);
        vm.prank(alice);
        vm.expectRevert(IMDPot.MultiplierAtMax.selector);
        pot.redeemMultiplier();
        (points,,,) = pot.getPlayer(alice);
        assertEq(points, 600);
    }

    function test_redeem_boostAppliesToAllTicketsOfNextRoundThenIsConsumed() public {
        _playRounds(alice, 100, 10);
        vm.prank(alice);
        pot.redeemMultiplier();
        uint256 round = pot.currentRoundId();
        _buy(alice, 4);
        _buy(alice, 6);
        assertEq(pot.roundBoostBps(round, alice), 2_500);
        assertEq(pot.weightOf(round, alice), 10 * 12_500);
        (,, uint256 pending,) = pot.getPlayer(alice);
        assertEq(pending, 0);
        // Redeeming during a round only affects the next one.
        vm.prank(alice);
        pot.redeemMultiplier();
        _buy(alice, 1);
        assertEq(pot.weightOf(round, alice), 11 * 12_500);
        _buy(bob, 1);
        assertEq(pot.weightOf(round, bob), 10_000);
        _finalizeAndFulfill(5);
        _buy(alice, 1);
        assertEq(pot.weightOf(round + 1, alice), 12_500);
    }

    // ------------------------------------------------------------------ admin

    function test_admin_everyOwnerFunctionRejectsStrangers() public {
        address stranger = makeAddr("stranger");
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        pot.pause();
        vm.expectRevert(unauthorized);
        pot.unpause();
        vm.expectRevert(unauthorized);
        pot.setToken(address(token));
        vm.expectRevert(unauthorized);
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.expectRevert(unauthorized);
        pot.setVrfRequestParams(CALLBACK_GAS, CONFIRMATIONS);
        vm.expectRevert(unauthorized);
        pot.rescueForeignToken(address(token), stranger);
        vm.expectRevert(unauthorized);
        pot.transferOwnership(stranger);
        // Renouncing is disabled for everyone, so the selector is rejected before any ownership check.
        vm.expectRevert(IMDPot.OwnershipCannotBeRenounced.selector);
        pot.renounceOwnership();
        vm.stopPrank();
        assertEq(pot.owner(), OWNER);
    }

    function test_admin_pendingOwnerHasNoPowerUntilAcceptAndOldOwnerLosesIt() public {
        address next = makeAddr("next");
        vm.prank(OWNER);
        pot.transferOwnership(next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        pot.pause();
        vm.prank(next);
        pot.acceptOwnership();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        pot.pause();
        vm.prank(next);
        pot.pause();
        assertTrue(pot.paused());
    }

    function test_admin_pauseAndUnpauseCannotRepeat() public {
        vm.prank(OWNER);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        pot.unpause();
        vm.prank(OWNER);
        pot.pause();
        vm.prank(OWNER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pot.pause();
    }

    function test_admin_pausedBlocksRetry() public {
        _buy(alice, 1);
        _finalize();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(OWNER);
        pot.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pot.retryRandomness();
    }

    function test_admin_vrfConfigBoundariesAccepted() public {
        uint32 minGas = pot.MIN_CALLBACK_GAS_LIMIT();
        uint32 maxGas = pot.MAX_CALLBACK_GAS_LIMIT();
        uint16 maxConf = pot.MAX_REQUEST_CONFIRMATIONS();
        vm.startPrank(OWNER);
        pot.setVrfConfig(address(coordinator), 1, KEY_HASH, minGas, 1, true);
        pot.setVrfConfig(address(coordinator), type(uint256).max, KEY_HASH, maxGas, maxConf, false);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), 1, KEY_HASH, minGas - 1, 1, true);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), 1, KEY_HASH, maxGas + 1, 1, true);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), 1, KEY_HASH, CALLBACK_GAS, maxConf + 1, true);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.NotAContract.selector, alice));
        pot.setVrfConfig(alice, 1, KEY_HASH, CALLBACK_GAS, 1, true);
        vm.stopPrank();
        (, uint256 subId,, uint32 gasLimit, uint16 confirmations, bool native) = pot.vrfConfig();
        assertEq(subId, type(uint256).max);
        assertEq(gasLimit, maxGas);
        assertEq(confirmations, maxConf);
        assertFalse(native);
    }

    function test_admin_setVrfConfigAllowedAgainAfterSettlement() public {
        _buy(alice, 1);
        _finalizeAndFulfill(1);
        MockVRFCoordinator other = new MockVRFCoordinator();
        vm.prank(OWNER);
        pot.setVrfConfig(address(other), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        // The old coordinator loses its callback right immediately.
        uint256[] memory words = new uint256[](1);
        vm.prank(address(coordinator));
        vm.expectRevert(
            abi.encodeWithSelector(IMDPot.OnlyCoordinatorCanFulfill.selector, address(coordinator), address(other))
        );
        pot.rawFulfillRandomWords(1, words);
    }

    function test_admin_setTokenDecimalBounds() public {
        IMDPot fresh = new IMDPot(OWNER);
        MockIMDToken zero = new MockIMDToken(0);
        MockIMDToken tooMany = new MockIMDToken(37);
        MockIMDToken one = new MockIMDToken(1);
        vm.startPrank(OWNER);
        vm.expectRevert(IMDPot.InvalidTokenDecimals.selector);
        fresh.setToken(address(zero));
        vm.expectRevert(IMDPot.InvalidTokenDecimals.selector);
        fresh.setToken(address(tooMany));
        fresh.setToken(address(one));
        vm.stopPrank();
        assertEq(fresh.ticketPrice(), 1);
        IMDPot fresh36 = new IMDPot(OWNER);
        MockIMDToken maxDec = new MockIMDToken(36);
        vm.prank(OWNER);
        fresh36.setToken(address(maxDec));
        assertEq(fresh36.ticketPrice(), 1e35);
    }

    function test_admin_rescueRejectsZeroRecipientAndZeroToken() public {
        MockIMDToken stray = new MockIMDToken(18);
        stray.mint(address(pot), 5 ether);
        vm.startPrank(OWNER);
        vm.expectRevert(IMDPot.ZeroAddress.selector);
        pot.rescueForeignToken(address(stray), address(0));
        vm.expectRevert(IMDPot.CannotRescueGameToken.selector);
        pot.rescueForeignToken(address(0), OWNER);
        pot.rescueForeignToken(address(stray), OWNER);
        vm.stopPrank();
        assertEq(stray.balanceOf(OWNER), 5 ether);
    }

    function test_admin_renounceRejectedMidRoundAndWhilePausedKeepsOwnerAndPendingOwner() public {
        address next = makeAddr("next");
        _buy(alice, 1);
        vm.startPrank(OWNER);
        pot.transferOwnership(next);
        pot.pause();
        vm.expectRevert(IMDPot.OwnershipCannotBeRenounced.selector);
        pot.renounceOwnership();
        vm.stopPrank();
        assertEq(pot.owner(), OWNER);
        assertEq(pot.pendingOwner(), next);
        // The owner can still unpause, so the round is never stuck behind a vanished owner.
        vm.prank(OWNER);
        pot.unpause();
        _buy(bob, 1);
        _finalizeAndFulfill(3);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Finalized));
    }

    function test_admin_setVrfRequestParamsBoundsAndMidRound() public {
        IMDPot fresh = new IMDPot(OWNER);
        vm.prank(OWNER);
        vm.expectRevert(IMDPot.VrfNotConfigured.selector);
        fresh.setVrfRequestParams(CALLBACK_GAS, CONFIRMATIONS);

        uint32 minGas = pot.MIN_CALLBACK_GAS_LIMIT();
        uint32 maxGas = pot.MAX_CALLBACK_GAS_LIMIT();
        uint16 maxConf = pot.MAX_REQUEST_CONFIRMATIONS();
        _buy(alice, 1);
        _finalize();
        vm.startPrank(OWNER);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfRequestParams(minGas - 1, 1);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfRequestParams(maxGas + 1, 1);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfRequestParams(minGas, 0);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfRequestParams(minGas, maxConf + 1);
        // Allowed while Drawing, but the coordinator, subscription and key hash stay locked.
        pot.setVrfRequestParams(maxGas, maxConf);
        vm.expectRevert(IMDPot.RoundNotIdle.selector);
        pot.setVrfConfig(address(coordinator), SUB_ID + 1, KEY_HASH, maxGas, maxConf, false);
        vm.stopPrank();
        (address coord, uint256 subId, bytes32 kh, uint32 gasLimit, uint16 confirmations,) = pot.vrfConfig();
        assertEq(coord, address(coordinator));
        assertEq(subId, SUB_ID);
        assertEq(kh, KEY_HASH);
        assertEq(gasLimit, maxGas);
        assertEq(confirmations, maxConf);
    }

    function test_retry_limitReachedThenCancelAfterLatestRequest() public {
        _buy(alice, 3);
        uint256 first = _finalize();
        uint32 maxRequests = pot.MAX_RANDOMNESS_REQUESTS();
        for (uint256 i = 1; i < maxRequests; ++i) {
            vm.warp(block.timestamp + 1 hours);
            pot.retryRandomness();
        }
        IMDPot.Round memory r = pot.getRound(1);
        assertEq(r.requestCount, maxRequests);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(IMDPot.RetryLimitReached.selector);
        pot.retryRandomness();
        // Every request of the round still maps to it.
        for (uint256 id = first; id < first + maxRequests; ++id) {
            assertEq(pot.requestRound(id), 1);
        }
        vm.warp(uint256(r.randomnessRequestedAt) + 24 hours);
        pot.cancelRound();
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Cancelled));
        vm.prank(alice);
        pot.refund(1);
        assertEq(token.balanceOf(address(pot)), 0);
    }

    function test_vrf_duplicateRequestIdIsRejectedAndPauseStillRescuesFunds() public {
        ConstantIdCoordinator dup = new ConstantIdCoordinator();
        IMDPot fresh = new IMDPot(OWNER);
        vm.startPrank(OWNER);
        fresh.setToken(address(token));
        fresh.setVrfConfig(address(dup), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.stopPrank();
        vm.prank(alice);
        token.approve(address(fresh), type(uint256).max);
        vm.prank(alice);
        fresh.buyTickets(1);
        vm.warp(fresh.getRound(1).endTime);
        fresh.finalizeRound();
        dup.fulfill(address(fresh), 1);
        assertEq(uint8(fresh.getRound(1).status), uint8(IMDPot.RoundStatus.Finalized));

        vm.prank(alice);
        fresh.buyTickets(2);
        vm.warp(fresh.getRound(2).endTime);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.DuplicateRequestId.selector, 42));
        fresh.finalizeRound();
        // A replayed word for the reused id never settles the new round.
        dup.fulfill(address(fresh), 2);
        assertEq(uint8(fresh.getRound(2).status), uint8(IMDPot.RoundStatus.Active));
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.DuplicateRequestId.selector, 42));
        fresh.cancelRound();
        // Pausing skips the request, so the stuck round can still be refunded.
        vm.prank(OWNER);
        fresh.pause();
        fresh.cancelRound();
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        fresh.refund(2);
        assertEq(token.balanceOf(alice) - before, 2 * fresh.ticketPrice());
        assertEq(token.balanceOf(address(fresh)), fresh.totalObligations());
    }

    // ------------------------------------------------------------------ fuzzed properties

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_buy_countBounds(uint256 count) public {
        uint256 maxCount = pot.MAX_TICKETS_PER_PURCHASE();
        count = bound(count, 0, maxCount * 2);
        token.mint(alice, count * ticketPrice);
        if (count == 0 || count > maxCount) {
            vm.prank(alice);
            vm.expectRevert(IMDPot.InvalidTicketCount.selector);
            pot.buyTickets(count);
            return;
        }
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        pot.buyTickets(count);
        assertEq(before - token.balanceOf(alice), count * ticketPrice);
        assertEq(pot.getRound(1).pool, count * ticketPrice);
        assertEq(pot.totalWeight(1), count * 10_000);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_settlement_splitIsExactForAnyPool(uint256 a, uint256 b, uint256 c, uint256 word) public {
        a = bound(a, 1, 1_000_000);
        b = bound(b, 0, 1_000_000);
        c = bound(c, 0, 1_000_000);
        _buy(alice, a);
        if (b > 0) _buy(bob, b);
        if (c > 0) _buy(carol, c);
        uint256 pool = (a + b + c) * ticketPrice;
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        _finalizeAndFulfill(word);
        IMDPot.Round memory r = pot.getRound(1);
        assertEq(r.pool, pool);
        assertEq(token.balanceOf(DEAD) - deadBefore, (pool * 1_000) / 10_000);
        assertEq(token.balanceOf(TREASURY) - treasuryBefore, (pool * 500) / 10_000);
        assertEq(r.prizes[0] + r.prizes[1] + r.prizes[2], pot.totalClaimable());
        assertGe(r.locked, (pool * 1_500) / 10_000);
        assertEq(r.locked + r.burned + r.treasuryFee + pot.totalClaimable(), pool);
        assertEq(token.balanceOf(address(pot)), r.locked + pot.totalClaimable());
        // Winners are drawn tickets: an address may hold several podium places, never more than its tickets.
        address[3] memory all = [alice, bob, carol];
        for (uint256 j; j < 3; ++j) {
            uint256 owed;
            uint256 times;
            for (uint256 i; i < 3; ++i) {
                if (r.winners[i] == all[j]) {
                    owed += r.prizes[i];
                    times++;
                }
            }
            assertEq(pot.claimable(all[j]), owed, "claimable != sum of own podium prizes");
            assertLe(times, pot.ticketsOf(1, all[j]), "won more places than tickets held");
            assertEq(pot.weightOf(1, all[j]), (pot.ticketsOf(1, all[j]) - times) * 10_000, "drawn weight");
        }
        uint256 filled = a + b + c < 3 ? a + b + c : 3;
        for (uint256 i; i < 3; ++i) {
            if (i < filled) {
                assertTrue(r.winners[i] != address(0), "slot left empty with tickets remaining");
                assertGt(pot.ticketsOf(1, r.winners[i]), 0, "winner did not play");
            } else {
                assertEq(r.winners[i], address(0));
                assertEq(r.prizes[i], 0);
            }
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_settlement_soloPlayerAlwaysWinsEverything(uint256 tickets, uint256 word) public {
        tickets = bound(tickets, 1, 1_000_000);
        _buy(dave, tickets);
        _finalizeAndFulfill(word);
        IMDPot.Round memory r = pot.getRound(1);
        // One ticket per podium place: slots beyond the ticket count stay empty and roll up to first.
        for (uint256 k; k < 3; ++k) {
            assertEq(r.winners[k], k < tickets ? dave : address(0));
        }
        assertEq(pot.claimable(dave), _shares(tickets * ticketPrice));
        assertEq(pot.weightOf(1, dave), (tickets - (tickets < 3 ? tickets : 3)) * 10_000);
    }

    /// @dev First prize absorbs the two empty slots: each share is rounded down separately.
    function _shares(uint256 pool) internal pure returns (uint256) {
        return (pool * 4_000) / 10_000 + (pool * 2_000) / 10_000 + (pool * 1_000) / 10_000;
    }
}

/// @notice Coordinator that hands out the same request id every time (a misbehaving or misconfigured coordinator).
contract ConstantIdCoordinator {
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external pure returns (uint256) {
        return 42;
    }

    function fulfill(address consumer, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumerV2Plus(consumer).rawFulfillRandomWords(42, words);
    }
}
