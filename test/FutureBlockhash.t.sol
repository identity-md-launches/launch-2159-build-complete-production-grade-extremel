// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDPot} from "../src/IMDPot.sol";
import {DeployIMDPot} from "../script/DeployIMDPot.s.sol";
import {MockIMDToken} from "./mocks/MockIMDToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FutureHookToken is ERC20 {
    address public game;
    bytes public payload;
    bytes public rejected;
    bool private armed;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function arm(address target, bytes calldata callData) external {
        game = target;
        payload = callData;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == game) {
            armed = false;
            (bool ok, bytes memory reason) = game.call(payload);
            require(!ok, "re-entry unexpectedly succeeded");
            rejected = reason;
        }
    }
}

contract FutureBlockhashTest is Test {
    IMDPot internal pot;
    MockIMDToken internal token;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(100);
        pot = new DeployIMDPot().deploy(owner);
        token = new MockIMDToken(18);
        vm.prank(owner);
        pot.setToken(address(token));
        _fund(alice);
        _fund(bob);
    }

    function _fund(address player) internal {
        token.mint(player, 1_000_000 ether);
        vm.prank(player);
        token.approve(address(pot), type(uint256).max);
    }

    function _buy(address player, uint256 count) internal {
        vm.prank(player);
        pot.buyTickets(count);
    }

    function _commit() internal returns (uint256 target) {
        vm.warp(pot.getRound(pot.currentRoundId()).endTime);
        vm.prank(keeper);
        pot.finalizeRound();
        return pot.getRound(pot.currentRoundId()).drawBlock;
    }

    function _settle(bytes32 entropy) internal {
        uint256 target = pot.getRound(pot.currentRoundId()).drawBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, entropy);
        vm.prank(bob);
        pot.finalizeRound();
    }

    function test_tokenAloneConfiguresGameWithoutOracle() public view {
        assertTrue(pot.isConfigured());
        assertEq(pot.owner(), owner);
        assertEq(pot.ticketPrice(), 0.1 ether);
        assertEq(pot.DRAW_DELAY_BLOCKS(), 3);
        assertEq(pot.BLOCKHASH_WINDOW(), 256);
        assertLt(address(pot).code.length, 24_576);
    }

    function test_emptyRoundNeverStartsAndCannotFinalize() public {
        vm.warp(block.timestamp + 365 days);
        assertEq(pot.getRound(1).startTime, 0);
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.finalizeRound();
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.cancelRound();
    }

    function test_firstTicketStartsTimerAndLaterTicketDoesNotResetIt() public {
        _buy(alice, 1);
        uint64 end = pot.getRound(1).endTime;
        assertEq(end - pot.getRound(1).startTime, 900);
        vm.warp(end - 1);
        _buy(bob, 1);
        assertEq(pot.getRound(1).endTime, end);
        vm.expectRevert(IMDPot.RoundNotEnded.selector);
        pot.finalizeRound();
        vm.warp(end);
        vm.expectRevert(IMDPot.RoundClosed.selector);
        pot.buyTickets(1);
        pot.finalizeRound();
        assertEq(pot.getRound(1).drawBlock, 103);
    }

    function test_firstFinalizeCommitsFutureBlockWithoutPayingOrSelectingWinners() public {
        _buy(alice, 10);
        uint256 target = _commit();
        IMDPot.Round memory round = pot.getRound(1);
        assertEq(target, 103);
        assertEq(uint8(round.status), uint8(IMDPot.RoundStatus.Drawing));
        assertEq(round.drawBlockHash, bytes32(0));
        assertEq(round.randomWord, 0);
        assertEq(pot.totalClaimable(), 0);
        assertEq(pot.currentRoundId(), 1);
        assertEq(token.balanceOf(address(pot)), round.pool);
    }

    function test_cannotUseCurrentOrFutureHashAndCannotRerollCommitment() public {
        _buy(alice, 5);
        uint256 target = _commit();
        for (uint256 n = 100; n <= target; ++n) {
            vm.roll(n);
            vm.expectRevert(abi.encodeWithSelector(IMDPot.DrawNotReady.selector, target));
            pot.finalizeRound();
            assertEq(pot.getRound(1).drawBlock, target);
        }
        vm.expectRevert(IMDPot.RoundDrawing.selector);
        _buy(bob, 1);
    }

    function test_hashIsBoundToChainContractAndRoundAndSavedForAudit() public {
        _buy(alice, 10);
        _buy(bob, 10);
        uint256 target = _commit();
        bytes32 entropy = keccak256("future block");
        _settle(entropy);
        IMDPot.Round memory round = pot.getRound(1);
        assertEq(round.drawBlock, target);
        assertEq(round.drawBlockHash, entropy);
        assertEq(round.randomWord, uint256(keccak256(abi.encode(entropy, block.chainid, address(pot), uint256(1)))));
        assertEq(uint8(round.status), uint8(IMDPot.RoundStatus.Finalized));
        assertEq(pot.currentRoundId(), 2);
        assertEq(pot.getRound(2).startTime, 0);
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.finalizeRound();
    }

    function test_missingHashNeverFallsBackToTimestampOrZero() public {
        _buy(alice, 1);
        uint256 target = _commit();
        vm.roll(target + 1);
        vm.setBlockhash(target, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IMDPot.DrawHashUnavailable.selector, target));
        pot.finalizeRound();
        assertEq(pot.currentRoundId(), 1);
        assertEq(pot.totalClaimable(), 0);
    }

    function test_lastReadableBlockSettlesButCannotCancel() public {
        _buy(alice, 10);
        uint256 target = _commit();
        vm.roll(target + 256);
        vm.setBlockhash(target, keccak256("last readable"));
        vm.expectRevert(IMDPot.CancelTooEarly.selector);
        pot.cancelRound();
        pot.finalizeRound();
        assertEq(pot.currentRoundId(), 2);
    }

    function test_expiredHashCannotSettleOrRerollButRefundsEntirePool() public {
        _buy(alice, 10);
        _buy(bob, 5);
        uint256 target = _commit();
        vm.roll(target + 257);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.DrawExpired.selector, target));
        pot.finalizeRound();
        assertEq(pot.getRound(1).drawBlock, target);
        vm.prank(keeper);
        pot.cancelRound();
        assertEq(pot.totalRefundable(), 1.5 ether);
        assertEq(pot.totalLocked(), 0);
        assertEq(pot.currentRoundId(), 2);
        vm.prank(alice);
        pot.refund(1);
        vm.prank(bob);
        pot.refund(1);
        assertEq(token.balanceOf(alice), 1_000_000 ether);
        assertEq(token.balanceOf(bob), 1_000_000 ether);
        assertEq(pot.totalRefundable(), 0);
        vm.prank(alice);
        vm.expectRevert(IMDPot.NothingToRefund.selector);
        pot.refund(1);
        (uint256 points, uint256 played,,) = pot.getPlayer(alice);
        assertEq(points, 0);
        assertEq(played, 0);
    }

    function test_ownerPauseBlocksEntriesAndCommitmentButNotCommittedSettlementOrClaim() public {
        _buy(alice, 10);
        vm.prank(owner);
        pot.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _buy(bob, 1);
        vm.warp(pot.getRound(1).endTime);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pot.finalizeRound();
        vm.prank(owner);
        pot.unpause();
        pot.finalizeRound();
        vm.prank(owner);
        pot.pause();
        _settle(keccak256("paused settlement"));
        vm.prank(alice);
        pot.claim();
        assertEq(token.balanceOf(alice), 1_000_000 ether - 0.3 ether);
        assertEq(pot.totalClaimable(), 0);
    }

    function test_onlyOwnerCanAdministerAndTokenCannotChange() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pot.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pot.setToken(address(token));
        vm.prank(owner);
        vm.expectRevert(IMDPot.TokenAlreadySet.selector);
        pot.setToken(address(token));
        vm.prank(owner);
        vm.expectRevert(IMDPot.CannotRescueGameToken.selector);
        pot.rescueForeignToken(address(token), owner);
        vm.prank(owner);
        vm.expectRevert(IMDPot.OwnershipCannotBeRenounced.selector);
        pot.renounceOwnership();
    }

    function test_uncommittedRoundOnlyRefundableAfter24HoursWhilePaused() public {
        _buy(alice, 1);
        uint256 deadline = pot.getRound(1).endTime + pot.CANCEL_DELAY();
        vm.warp(deadline);
        vm.expectRevert(IMDPot.CancelTooEarly.selector);
        pot.cancelRound();
        vm.prank(owner);
        pot.pause();
        vm.warp(deadline - 1);
        vm.expectRevert(IMDPot.CancelTooEarly.selector);
        pot.cancelRound();
        vm.warp(deadline);
        pot.cancelRound();
        vm.prank(alice);
        pot.refund(1);
        assertEq(token.balanceOf(alice), 1_000_000 ether);
    }

    function test_ownerCannotCancelReadableCommittedDrawEvenAfter24Hours() public {
        _buy(alice, 1);
        _commit();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        pot.pause();
        vm.expectRevert(IMDPot.CancelTooEarly.selector);
        pot.cancelRound();
        _settle(keccak256("still same target"));
    }

    function test_feeFailureDefersFeesWithoutBlockingSettlement() public {
        _buy(alice, 10);
        token.setBlocked(pot.DEAD_ADDRESS(), true);
        token.setBlocked(pot.TREASURY(), true);
        _commit();
        _settle(keccak256("fees"));
        assertEq(pot.pendingBurn(), 0.1 ether);
        assertEq(pot.pendingTreasury(), 0.05 ether);
        assertEq(pot.totalLocked(), 0.15 ether);
        assertEq(pot.totalClaimable(), 0.7 ether);
        assertEq(token.balanceOf(address(pot)), pot.totalObligations());
        token.setBlocked(pot.DEAD_ADDRESS(), false);
        pot.flushPendingFees();
        assertEq(pot.pendingBurn(), 0);
        assertEq(pot.pendingTreasury(), 0.05 ether);
        token.setBlocked(pot.TREASURY(), false);
        pot.flushPendingFees();
        assertEq(token.balanceOf(address(pot)), pot.totalObligations());
    }

    function test_singleAndTwoTicketRoundsRollUnfilledPrizesIntoFirstPlace() public {
        _buy(alice, 1);
        _commit();
        _settle(keccak256("one ticket"));
        IMDPot.Round memory one = pot.getRound(1);
        assertEq(one.prizes[0], 0.07 ether);
        assertEq(one.prizes[1] + one.prizes[2], 0);
        _buy(alice, 2);
        _commit();
        _settle(keccak256("two tickets"));
        IMDPot.Round memory two = pot.getRound(2);
        assertEq(two.prizes[0], 0.1 ether);
        assertEq(two.prizes[1], 0.04 ether);
        assertEq(two.prizes[2], 0);
        assertEq(token.balanceOf(address(pot)), pot.totalObligations());
    }

    function test_settlementCallerAndTimingCannotAlterTheCommittedOutcome() public {
        _buy(alice, 3);
        _buy(bob, 7);
        uint256 target = _commit();
        uint256 snapshot = vm.snapshotState();
        bytes32 entropy = keccak256("fixed target hash");
        _settle(entropy);
        IMDPot.Round memory early = pot.getRound(1);
        vm.revertToState(snapshot);
        vm.roll(target + 200);
        vm.setBlockhash(target, entropy);
        vm.prank(owner);
        pot.finalizeRound();
        IMDPot.Round memory later = pot.getRound(1);
        assertEq(early.randomWord, later.randomWord);
        for (uint256 i; i < 3; ++i) {
            assertEq(early.winners[i], later.winners[i]);
        }
    }

    function test_reentrancyDuringSettlementAndClaimCannotMutateTheRoundOrDrainFunds() public {
        FutureHookToken hook = new FutureHookToken();
        IMDPot hooked = new IMDPot(owner);
        vm.prank(owner);
        hooked.setToken(address(hook));
        hook.mint(alice, 10 ether);
        vm.prank(alice);
        hook.approve(address(hooked), 1 ether);
        vm.prank(alice);
        hooked.buyTickets(10);
        vm.warp(hooked.getRound(1).endTime);
        hooked.finalizeRound();
        uint256 target = hooked.getRound(1).drawBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("hook"));
        hook.arm(address(hooked), abi.encodeCall(IMDPot.finalizeRound, ()));
        hooked.finalizeRound();
        assertEq(bytes4(hook.rejected()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hooked.currentRoundId(), 2);
        hook.arm(address(hooked), abi.encodeCall(IMDPot.claim, ()));
        vm.prank(alice);
        hooked.claim();
        assertEq(bytes4(hook.rejected()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hooked.totalClaimable(), 0);
        assertEq(hook.balanceOf(address(hooked)), hooked.totalObligations());
    }

    function test_loyaltyRedemptionAndCancelledMultiplierRestoration() public {
        for (uint256 i; i < 10; ++i) {
            _buy(alice, 10);
            _commit();
            _settle(keccak256(abi.encode("loyalty", i)));
        }
        (uint256 points, uint256 played,, bool canRedeem) = pot.getPlayer(alice);
        assertEq(points, 100);
        assertEq(played, 10);
        assertTrue(canRedeem);
        vm.prank(alice);
        pot.redeemMultiplier();
        _buy(alice, 1);
        assertEq(pot.roundBoostBps(11, alice), 2500);
        uint256 target = _commit();
        vm.roll(target + 257);
        pot.cancelRound();
        vm.prank(alice);
        pot.refund(11);
        uint256 pending;
        (points, played, pending,) = pot.getPlayer(alice);
        assertEq(points, 0);
        assertEq(played, 10);
        assertEq(pending, 2500);
    }

    function testFuzz_settlementAccountsForEntirePoolAndDrawsOnlyExistingTickets(
        uint256 aliceCount,
        uint256 bobCount,
        bytes32 entropy
    ) public {
        aliceCount = bound(aliceCount, 1, 100_000);
        bobCount = bound(bobCount, 0, 100_000);
        vm.assume(entropy != bytes32(0));
        _buy(alice, aliceCount);
        if (bobCount > 0) _buy(bob, bobCount);
        _commit();
        _settle(entropy);
        IMDPot.Round memory round = pot.getRound(1);
        uint256 total = aliceCount + bobCount;
        uint256 pool = total * pot.ticketPrice();
        assertEq(
            round.prizes[0] + round.prizes[1] + round.prizes[2] + round.burned + round.treasuryFee + round.locked, pool
        );
        uint256 aliceWins;
        uint256 bobWins;
        for (uint256 i; i < 3; ++i) {
            if (i < total) {
                assertTrue(round.winners[i] == alice || (bobCount > 0 && round.winners[i] == bob));
                if (round.winners[i] == alice) aliceWins++;
                else bobWins++;
            } else {
                assertEq(round.winners[i], address(0));
                assertEq(round.prizes[i], 0);
            }
        }
        assertLe(aliceWins, aliceCount);
        assertLe(bobWins, bobCount);
        assertEq(token.balanceOf(address(pot)), pot.totalObligations());
        assertEq(pot.weightOf(1, alice), (aliceCount - aliceWins) * 10_000);
        assertEq(pot.weightOf(1, bob), (bobCount - bobWins) * 10_000);
    }
}
