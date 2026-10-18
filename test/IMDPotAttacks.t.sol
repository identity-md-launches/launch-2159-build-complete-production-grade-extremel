// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMDPotBase} from "./IMDPotBase.t.sol";
import {IMDPot} from "../src/IMDPot.sol";
import {MockIMDToken} from "./mocks/MockIMDToken.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An ERC-20 with a transfer hook, standing in for a token that lets a recipient re-enter the game.
contract ReentrantToken is ERC20 {
    IMDPot public pot;
    bytes public reentryCall;
    bool public armed;
    bytes public lastRevert;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(IMDPot pot_, bytes calldata call_) external {
        pot = pot_;
        reentryCall = call_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && to != address(pot) && from == address(pot)) {
            armed = false;
            (bool ok, bytes memory data) = address(pot).call(reentryCall);
            require(!ok, "re-entry must fail");
            lastRevert = data;
        }
    }
}

/// @notice Attack scenarios and failure paths.
contract IMDPotAttacksTest is IMDPotBase {
    // ------------------------------------------------------------------ reentrancy

    function _deployWithReentrantToken() internal returns (IMDPot hooked, ReentrantToken hook) {
        hook = new ReentrantToken();
        hooked = new IMDPot(OWNER);
        vm.startPrank(OWNER);
        hooked.setToken(address(hook));
        hooked.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.stopPrank();
        hook.mint(alice, 100 ether);
        vm.prank(alice);
        hook.approve(address(hooked), type(uint256).max);
    }

    function test_reentrancy_claimCannotReenterClaim() public {
        (IMDPot hooked, ReentrantToken hook) = _deployWithReentrantToken();
        vm.prank(alice);
        hooked.buyTickets(10);
        vm.warp(hooked.getRound(1).endTime);
        hooked.finalizeRound();
        coordinator.fulfill(1, 1);
        uint256 prize = hooked.claimable(alice);
        assertEq(prize, 0.7 ether);

        hook.arm(hooked, abi.encodeCall(IMDPot.claim, ()));
        vm.prank(alice);
        hooked.claim();
        assertEq(hook.balanceOf(alice), 100 ether - 1 ether + prize);
        assertEq(hooked.claimable(alice), 0);
        assertEq(bytes4(hook.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hook.balanceOf(address(hooked)), hooked.totalObligations());
    }

    function test_reentrancy_refundCannotReenterRefundOrBuy() public {
        (IMDPot hooked, ReentrantToken hook) = _deployWithReentrantToken();
        vm.prank(alice);
        hooked.buyTickets(10);
        coordinator.setShouldRevert(true);
        vm.warp(hooked.getRound(1).endTime + 24 hours);
        hooked.cancelRound();

        hook.arm(hooked, abi.encodeCall(IMDPot.refund, (1)));
        vm.prank(alice);
        hooked.refund(1);
        assertEq(hook.balanceOf(alice), 100 ether);
        assertEq(bytes4(hook.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hooked.totalRefundable(), 0);
    }

    function test_reentrancy_feePushCannotReenterSettlement() public {
        (IMDPot hooked, ReentrantToken hook) = _deployWithReentrantToken();
        vm.prank(alice);
        hooked.buyTickets(10);
        vm.warp(hooked.getRound(1).endTime);
        hooked.finalizeRound();
        // During the burn transfer inside the callback, try to re-enter buyTickets for the next round.
        hook.arm(hooked, abi.encodeCall(IMDPot.buyTickets, (1)));
        coordinator.fulfill(1, 1);
        assertEq(bytes4(hook.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hooked.currentRoundId(), 2);
        assertEq(hook.balanceOf(DEAD), 0.1 ether);
        assertEq(hook.balanceOf(TREASURY), 0.05 ether);
    }

    // ------------------------------------------------------------------ randomness manipulation

    function test_randomness_cannotBeInjectedByPlayersOrOwner() public {
        _buy(alice, 1);
        _buy(bob, 1);
        uint256 requestId = _finalize();
        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        address[3] memory callers = [alice, OWNER, keeper];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IMDPot.OnlyCoordinatorCanFulfill.selector, callers[i], address(coordinator))
            );
            pot.rawFulfillRandomWords(requestId, words);
        }
    }

    function test_randomness_ownerCannotSwapCoordinatorMidRound() public {
        MockVRFCoordinator rogue = new MockVRFCoordinator();
        _buy(alice, 1);
        vm.prank(OWNER);
        vm.expectRevert(IMDPot.RoundNotIdle.selector);
        pot.setVrfConfig(address(rogue), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        _finalize();
        vm.prank(OWNER);
        vm.expectRevert(IMDPot.RoundNotIdle.selector);
        pot.setVrfConfig(address(rogue), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
    }

    function test_randomness_lateEntryAfterEndIsImpossible() public {
        _buy(alice, 1);
        _endRound();
        // Even before anyone finalises, the pool is closed: nobody can wait for the draw and then join.
        vm.prank(bob);
        vm.expectRevert(IMDPot.RoundClosed.selector);
        pot.buyTickets(1);
        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        vm.expectRevert(IMDPot.RoundClosed.selector);
        pot.buyTickets(1);
    }

    function test_randomness_staleWordAfterCancelIsIgnored() public {
        _buy(alice, 1);
        _buy(bob, 1);
        uint256 requestId = _finalize();
        vm.warp(pot.getRound(1).endTime + 24 hours);
        pot.cancelRound();
        coordinator.fulfill(requestId, 1);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Cancelled));
        assertEq(pot.totalClaimable(), 0);
        assertEq(pot.totalRefundable(), 2 * ticketPrice);
    }

    // ------------------------------------------------------------------ cancellation & refunds

    function test_cancel_requiresDelay() public {
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.cancelRound();
        _buy(alice, 1);
        vm.expectRevert(IMDPot.CancelTooEarly.selector);
        pot.cancelRound();
        vm.warp(pot.getRound(1).endTime + 24 hours - 1);
        vm.expectRevert(IMDPot.CancelTooEarly.selector);
        pot.cancelRound();
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, true, false, true);
        emit IMDPot.RoundCancelled(1, ticketPrice, keeper);
        vm.prank(keeper);
        pot.cancelRound();
        assertEq(pot.currentRoundId(), 2);
    }

    function test_cancel_whenCoordinatorIsBrokenRefundsEveryone() public {
        _buy(alice, 3);
        _buy(bob, 7);
        coordinator.setShouldRevert(true);
        _endRound();
        vm.expectRevert("coordinator: subscription not funded");
        pot.finalizeRound();
        vm.warp(block.timestamp + 24 hours);
        pot.cancelRound();
        assertEq(pot.totalRefundable(), 10 * ticketPrice);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.expectEmit(true, true, false, true);
        emit IMDPot.Refunded(1, alice, 3 * ticketPrice);
        vm.prank(alice);
        pot.refund(1);
        assertEq(token.balanceOf(alice) - aliceBefore, 3 * ticketPrice);
        vm.prank(alice);
        vm.expectRevert(IMDPot.NothingToRefund.selector);
        pot.refund(1);
        vm.prank(carol);
        vm.expectRevert(IMDPot.NothingToRefund.selector);
        pot.refund(1);
        vm.prank(bob);
        pot.refund(1);
        assertEq(pot.totalRefundable(), 0);
        assertEq(token.balanceOf(address(pot)), 0);
        _assertSolvent();

        // The game continues with a fresh round.
        coordinator.setShouldRevert(false);
        _buy(carol, 1);
        assertEq(pot.currentRoundId(), 2);
        assertEq(uint8(pot.getRound(2).status), uint8(IMDPot.RoundStatus.Active));
    }

    function test_refund_rejectsNonCancelledRounds() public {
        _buy(alice, 1);
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(1);
        _finalizeAndFulfill(1);
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(1);
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(99);
    }

    function test_refund_restoresSpentMultiplier() public {
        _playRounds(alice, 100, 10);
        vm.prank(alice);
        pot.redeemMultiplier();
        uint256 roundId = pot.currentRoundId();
        _buy(alice, 1);
        (,, uint256 boost,) = pot.getPlayer(alice);
        assertEq(boost, 0);
        coordinator.setShouldRevert(true);
        vm.warp(pot.getRound(roundId).endTime + 24 hours);
        pot.cancelRound();
        vm.expectEmit(true, true, false, true);
        emit IMDPot.MultiplierRestored(alice, roundId, 2_500);
        vm.prank(alice);
        pot.refund(roundId);
        (,, boost,) = pot.getPlayer(alice);
        assertEq(boost, 2_500);
        assertEq(pot.roundBoostBps(roundId, alice), 0);
    }

    // ------------------------------------------------------------------ hostile token behaviour at settlement

    function test_settlement_defersFeesWhenRecipientIsBlocked() public {
        _buy(alice, 10);
        _buy(bob, 10);
        token.setBlocked(TREASURY, true);
        uint256 pool = 20 * ticketPrice;
        uint256 requestId = _finalize();
        vm.expectEmit(true, false, false, true);
        emit IMDPot.FeeTransferDeferred(TREASURY, pool / 20);
        coordinator.fulfill(requestId, 1);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Finalized), "settlement never reverts");
        assertEq(token.balanceOf(DEAD), pool / 10);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(pot.pendingTreasury(), pool / 20);
        _assertSolvent();

        vm.expectRevert("blocked");
        pot.flushPendingFees();
        token.setBlocked(TREASURY, false);
        vm.prank(keeper);
        pot.flushPendingFees();
        assertEq(token.balanceOf(TREASURY), pool / 20);
        assertEq(pot.pendingTreasury(), 0);
        vm.expectRevert(IMDPot.NothingToFlush.selector);
        pot.flushPendingFees();
    }

    function test_settlement_survivesFrozenToken() public {
        _buy(alice, 10);
        uint256 pool = 10 * ticketPrice;
        uint256 requestId = _finalize();
        token.setFrozen(true);
        coordinator.fulfill(requestId, 1);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Finalized));
        assertEq(pot.pendingBurn(), pool / 10);
        assertEq(pot.pendingTreasury(), pool / 20);
        assertEq(pot.claimable(alice), (pool * 70) / 100);
        _assertSolvent();
        token.setFrozen(false);
        pot.flushPendingFees();
        assertEq(token.balanceOf(DEAD), pool / 10);
        assertEq(token.balanceOf(TREASURY), pool / 20);
    }

    // ------------------------------------------------------------------ custody

    function test_custody_lockedTokensCanNeverLeave() public {
        _buy(alice, 10);
        _buy(bob, 10);
        _buy(carol, 10);
        _finalizeAndFulfill(1);
        uint256 locked = pot.totalLocked();
        assertEq(locked, (30 * ticketPrice * 15) / 100);

        IMDPot.Round memory round = pot.getRound(1);
        for (uint256 i; i < 3; ++i) {
            vm.prank(round.winners[i]);
            pot.claim();
        }
        assertEq(token.balanceOf(address(pot)), locked);

        // No owner function can move the game token.
        vm.startPrank(OWNER);
        vm.expectRevert(IMDPot.CannotRescueGameToken.selector);
        pot.rescueForeignToken(address(token), OWNER);
        vm.stopPrank();
        assertEq(token.balanceOf(address(pot)), locked);
        assertEq(pot.totalObligations(), locked);
    }

    function test_custody_flashLoanStyleEntryCannotExitInSameBlock() public {
        // A borrowed balance can buy tickets, but the tokens stay in the pot until a draw or a cancellation,
        // so nothing can be repaid within the transaction that entered.
        _buy(alice, 1_000);
        vm.prank(alice);
        vm.expectRevert(IMDPot.NothingToClaim.selector);
        pot.claim();
        vm.prank(alice);
        vm.expectRevert(IMDPot.RoundNotCancelled.selector);
        pot.refund(1);
        vm.expectRevert(IMDPot.RoundNotEnded.selector);
        pot.finalizeRound();
        assertEq(token.balanceOf(address(pot)), 1_000 * ticketPrice);
    }

    function test_custody_directDonationDoesNotChangeObligations() public {
        _buy(alice, 1);
        token.mint(address(pot), 1_000 ether);
        _finalizeAndFulfill(1);
        assertEq(pot.claimable(alice), (ticketPrice * 70) / 100);
        assertEq(pot.totalLocked(), (ticketPrice * 15) / 100);
        _assertSolvent();
    }
}
