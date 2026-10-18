// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMDPotBase} from "./IMDPotBase.t.sol";
import {IMDPot} from "../src/IMDPot.sol";
import {VRFV2PlusClient} from "../src/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockIMDToken} from "./mocks/MockIMDToken.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {DeployIMDPot} from "../script/DeployIMDPot.s.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Normal flows: configuration, rounds, settlement, claims, points, multipliers.
contract IMDPotTest is IMDPotBase {
    // ------------------------------------------------------------------ deployment & configuration

    function test_constructor_setsLaunchOwnerNotDeployer() public {
        IMDPot fresh = new DeployIMDPot().deploy(OWNER);
        assertEq(fresh.owner(), OWNER);
        assertTrue(fresh.owner() != address(this));
        assertEq(fresh.currentRoundId(), 1);
        assertFalse(fresh.isConfigured());
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new IMDPot(address(0));
    }

    function test_constructor_runsOnEmptyChainAndFitsSizeLimits() public {
        // Deploy from a brand-new address space with no other contract referenced by the constructor.
        IMDPot fresh = new IMDPot(OWNER);
        bytes memory code = address(fresh).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function test_setToken_setsTicketPriceFromDecimals() public view {
        assertEq(address(pot.token()), address(token));
        assertEq(ticketPrice, 0.1 ether);
        assertTrue(pot.isConfigured());
    }

    function test_setToken_sixDecimals() public {
        IMDPot fresh = new IMDPot(OWNER);
        MockIMDToken six = new MockIMDToken(6);
        vm.prank(OWNER);
        fresh.setToken(address(six));
        assertEq(fresh.ticketPrice(), 100_000);
    }

    function test_setToken_validation() public {
        IMDPot fresh = new IMDPot(OWNER);
        vm.startPrank(OWNER);
        vm.expectRevert(IMDPot.ZeroAddress.selector);
        fresh.setToken(address(0));
        vm.expectRevert(abi.encodeWithSelector(IMDPot.NotAContract.selector, alice));
        fresh.setToken(alice);
        MockIMDToken zero = new MockIMDToken(0);
        vm.expectRevert(IMDPot.InvalidTokenDecimals.selector);
        fresh.setToken(address(zero));
        fresh.setToken(address(token));
        vm.expectRevert(IMDPot.TokenAlreadySet.selector);
        fresh.setToken(address(token));
        vm.stopPrank();
    }

    function test_setToken_onlyOwner() public {
        IMDPot fresh = new IMDPot(OWNER);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setToken(address(token));
    }

    function test_setVrfConfig_validation() public {
        vm.startPrank(OWNER);
        vm.expectRevert(IMDPot.ZeroAddress.selector);
        pot.setVrfConfig(address(0), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.NotAContract.selector, alice));
        pot.setVrfConfig(alice, SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), 0, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), SUB_ID, bytes32(0), CALLBACK_GAS, CONFIRMATIONS, false);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, 100_000, CONFIRMATIONS, false);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, 3_000_000, CONFIRMATIONS, false);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, 0, false);
        vm.expectRevert(IMDPot.InvalidVrfConfig.selector);
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, 201, false);
        pot.setVrfConfig(address(coordinator), 5, KEY_HASH, 750_000, 5, true);
        vm.stopPrank();
        (address coord, uint256 sub, bytes32 kh, uint32 gas, uint16 conf, bool native) = pot.vrfConfig();
        assertEq(coord, address(coordinator));
        assertEq(sub, 5);
        assertEq(kh, KEY_HASH);
        assertEq(gas, 750_000);
        assertEq(conf, 5);
        assertTrue(native);
    }

    function test_setVrfConfig_onlyOwnerAndOnlyBetweenRounds() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);

        _buy(alice, 1);
        vm.prank(OWNER);
        vm.expectRevert(IMDPot.RoundNotIdle.selector);
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);

        _finalize();
        vm.prank(OWNER);
        vm.expectRevert(IMDPot.RoundNotIdle.selector);
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);

        coordinator.fulfill(1, 42);
        vm.prank(OWNER);
        pot.setVrfConfig(address(coordinator), 9, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
    }

    function test_buy_revertsUntilConfigured() public {
        IMDPot fresh = new IMDPot(OWNER);
        vm.prank(alice);
        vm.expectRevert(IMDPot.TokenNotConfigured.selector);
        fresh.buyTickets(1);
        vm.prank(OWNER);
        fresh.setToken(address(token));
        vm.prank(alice);
        vm.expectRevert(IMDPot.VrfNotConfigured.selector);
        fresh.buyTickets(1);
        vm.prank(OWNER);
        fresh.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.prank(alice);
        token.approve(address(fresh), 1 ether);
        vm.prank(alice);
        fresh.buyTickets(1);
        assertEq(fresh.getRound(1).pool, 0.1 ether);
    }

    function test_ownership_isTwoStep() public {
        vm.prank(OWNER);
        pot.transferOwnership(alice);
        assertEq(pot.owner(), OWNER);
        assertEq(pot.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        pot.acceptOwnership();
        vm.prank(alice);
        pot.acceptOwnership();
        assertEq(pot.owner(), alice);
    }

    // ------------------------------------------------------------------ entering a round

    function test_buy_firstTicketStartsTimer() public {
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Open));
        assertEq(pot.timeRemaining(), 0);
        vm.warp(block.timestamp + 3 days); // the round does not start on its own
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Open));

        vm.expectEmit(true, false, false, true);
        emit IMDPot.RoundStarted(1, uint64(block.timestamp), uint64(block.timestamp + 15 minutes));
        _buy(alice, 3);

        IMDPot.Round memory round = pot.getRound(1);
        assertEq(uint8(round.status), uint8(IMDPot.RoundStatus.Active));
        assertEq(round.startTime, block.timestamp);
        assertEq(round.endTime, block.timestamp + 15 minutes);
        assertEq(round.pool, 3 * ticketPrice);
        assertEq(round.totalTickets, 3);
        assertEq(round.participantCount, 1);
        assertEq(pot.ticketsOf(1, alice), 3);
        assertEq(pot.weightOf(1, alice), 3 * 10_000);
        assertEq(pot.timeRemaining(), 15 minutes);
        assertEq(token.balanceOf(address(pot)), 3 * ticketPrice);
    }

    function test_buy_laterTicketsDoNotExtendTimer() public {
        _buy(alice, 1);
        uint64 endTime = pot.getRound(1).endTime;
        vm.warp(block.timestamp + 10 minutes);
        _buy(bob, 2);
        _buy(alice, 2);
        assertEq(pot.getRound(1).endTime, endTime);
        assertEq(pot.getRound(1).participantCount, 2);
        assertEq(pot.ticketsOf(1, alice), 3);
        assertEq(pot.weightOf(1, alice), 30_000);
        assertEq(pot.weightOf(1, bob), 20_000);
        assertEq(pot.totalWeight(1), 50_000);
        address[] memory participants = pot.getParticipants(1);
        assertEq(participants.length, 2);
        assertEq(participants[0], alice);
        assertEq(participants[1], bob);
    }

    function test_buy_validatesCount() public {
        vm.prank(alice);
        vm.expectRevert(IMDPot.InvalidTicketCount.selector);
        pot.buyTickets(0);
        uint256 tooMany = pot.MAX_TICKETS_PER_PURCHASE() + 1;
        vm.prank(alice);
        vm.expectRevert(IMDPot.InvalidTicketCount.selector);
        pot.buyTickets(tooMany);
    }

    function test_buy_requiresAllowanceAndBalance() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pot), 0, ticketPrice)
        );
        pot.buyTickets(1);
        vm.prank(poor);
        token.approve(address(pot), type(uint256).max);
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, ticketPrice));
        pot.buyTickets(1);
    }

    function test_buy_rejectsFeeOnTransferShortfall() public {
        token.setFeeBps(100);
        vm.prank(alice);
        vm.expectRevert(IMDPot.TransferAmountMismatch.selector);
        pot.buyTickets(1);
    }

    function test_buy_closesExactlyAtEndTime() public {
        _buy(alice, 1);
        uint64 endTime = pot.getRound(1).endTime;
        vm.warp(endTime - 1);
        _buy(bob, 1);
        vm.warp(endTime);
        vm.prank(carol);
        vm.expectRevert(IMDPot.RoundClosed.selector);
        pot.buyTickets(1);
        assertEq(pot.timeRemaining(), 0);
    }

    function test_buy_rejectedWhileDrawing() public {
        _buy(alice, 1);
        _finalize();
        vm.prank(bob);
        vm.expectRevert(IMDPot.RoundDrawing.selector);
        pot.buyTickets(1);
    }

    // ------------------------------------------------------------------ finalizing

    function test_finalize_revertsWithoutRoundOrBeforeEnd() public {
        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.finalizeRound();
        _buy(alice, 1);
        vm.warp(pot.getRound(1).endTime - 1);
        vm.expectRevert(IMDPot.RoundNotEnded.selector);
        pot.finalizeRound();
    }

    function test_finalize_anyoneCanCallAndRequestsVrfWithConfiguredParams() public {
        _buy(alice, 1);
        _endRound();
        vm.expectEmit(true, true, true, true);
        emit IMDPot.RandomnessRequested(1, 1, keeper);
        vm.prank(keeper);
        pot.finalizeRound();

        IMDPot.Round memory round = pot.getRound(1);
        assertEq(uint8(round.status), uint8(IMDPot.RoundStatus.Drawing));
        assertEq(round.vrfRequestId, 1);
        assertEq(round.randomnessRequestedAt, block.timestamp);
        (
            address consumer,
            bytes32 keyHash,
            uint256 subId,
            uint16 confirmations,
            uint32 gas,
            uint32 numWords,
            bytes memory extraArgs,
            bool fulfilled
        ) = coordinator.requests(1);
        assertEq(consumer, address(pot));
        assertEq(keyHash, KEY_HASH);
        assertEq(subId, SUB_ID);
        assertEq(confirmations, CONFIRMATIONS);
        assertEq(gas, CALLBACK_GAS);
        assertEq(numWords, 1);
        assertEq(extraArgs, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), false));
        assertFalse(fulfilled);

        vm.expectRevert(IMDPot.RoundNotActive.selector);
        pot.finalizeRound();
    }

    function test_finalize_revertsWhenCoordinatorRejects() public {
        _buy(alice, 1);
        _endRound();
        coordinator.setShouldRevert(true);
        vm.expectRevert("coordinator: subscription not funded");
        pot.finalizeRound();
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Active));
    }

    function test_settlement_splitsPoolExactly() public {
        _buy(alice, 10);
        _buy(bob, 20);
        _buy(carol, 70);
        uint256 pool = 100 * ticketPrice;
        assertEq(pot.getRound(1).pool, pool);

        uint256 requestId = _finalize();
        coordinator.fulfill(requestId, 123_456_789);

        IMDPot.Round memory round = pot.getRound(1);
        assertEq(uint8(round.status), uint8(IMDPot.RoundStatus.Finalized));
        assertEq(round.randomWord, 123_456_789);
        assertEq(round.burned, pool / 10);
        assertEq(round.treasuryFee, pool / 20);
        assertEq(round.locked, (pool * 15) / 100);
        assertEq(round.prizes[0], (pool * 40) / 100);
        assertEq(round.prizes[1], (pool * 20) / 100);
        assertEq(round.prizes[2], (pool * 10) / 100);
        assertTrue(round.winners[0] != address(0) && round.winners[1] != address(0) && round.winners[2] != address(0));
        assertTrue(round.winners[0] != round.winners[1]);
        assertTrue(round.winners[0] != round.winners[2]);
        assertTrue(round.winners[1] != round.winners[2]);

        assertEq(token.balanceOf(DEAD), pool / 10);
        assertEq(token.balanceOf(TREASURY), pool / 20);
        assertEq(pot.totalLocked(), (pool * 15) / 100);
        assertEq(pot.totalClaimable(), (pool * 70) / 100);
        assertEq(pot.claimable(round.winners[0]), (pool * 40) / 100);
        assertEq(pot.claimable(round.winners[1]), (pool * 20) / 100);
        assertEq(pot.claimable(round.winners[2]), (pool * 10) / 100);
        assertEq(token.balanceOf(address(pot)), (pool * 85) / 100);
        _assertSolvent();

        // Next round is open with no timer.
        assertEq(pot.currentRoundId(), 2);
        assertEq(uint8(pot.getRound(2).status), uint8(IMDPot.RoundStatus.Open));
        assertEq(pot.timeRemaining(), 0);
    }

    function test_settlement_dustGoesToLock() public {
        MockIMDToken odd = new MockIMDToken(1); // ticket price = 1 wei so pools need not divide evenly
        IMDPot fresh = new IMDPot(OWNER);
        vm.startPrank(OWNER);
        fresh.setToken(address(odd));
        fresh.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.stopPrank();
        odd.mint(alice, 1_000);
        vm.startPrank(alice);
        odd.approve(address(fresh), 1_000);
        fresh.buyTickets(7);
        vm.stopPrank();
        vm.warp(fresh.getRound(1).endTime);
        fresh.finalizeRound();
        coordinator.fulfill(1, 1);
        IMDPot.Round memory round = fresh.getRound(1);
        // 7 wei: burn 0, fee 0, prizes 2 + 1 + 0 (rolled to first => 3), lock 4 absorbs all dust.
        assertEq(round.burned, 0);
        assertEq(round.treasuryFee, 0);
        assertEq(round.prizes[0], 3);
        assertEq(round.locked, 4);
        assertEq(
            round.burned + round.treasuryFee + round.prizes[0] + round.prizes[1] + round.prizes[2] + round.locked, 7
        );
        assertEq(odd.balanceOf(address(fresh)), fresh.totalObligations());
    }

    function test_settlement_singleParticipantTakesWholePrizeShare() public {
        _buy(alice, 5);
        uint256 pool = 5 * ticketPrice;
        _finalizeAndFulfill(99);
        IMDPot.Round memory round = pot.getRound(1);
        assertEq(round.winners[0], alice);
        assertEq(round.winners[1], address(0));
        assertEq(round.winners[2], address(0));
        assertEq(round.prizes[0], (pool * 70) / 100);
        assertEq(round.prizes[1], 0);
        assertEq(round.prizes[2], 0);
        assertEq(pot.claimable(alice), (pool * 70) / 100);
        assertEq(pot.totalLocked(), (pool * 15) / 100);
        _assertSolvent();
    }

    function test_settlement_twoParticipantsRollThirdPrizeToFirst() public {
        _buy(alice, 5);
        _buy(bob, 5);
        uint256 pool = 10 * ticketPrice;
        _finalizeAndFulfill(7);
        IMDPot.Round memory round = pot.getRound(1);
        assertTrue(round.winners[0] != address(0) && round.winners[1] != address(0));
        assertTrue(round.winners[0] != round.winners[1]);
        assertEq(round.winners[2], address(0));
        assertEq(round.prizes[0], (pool * 50) / 100);
        assertEq(round.prizes[1], (pool * 20) / 100);
        assertEq(round.prizes[2], 0);
        assertEq(pot.totalClaimable(), (pool * 70) / 100);
    }

    function testFuzz_settlement_winnersAreDistinctAndWeightsZeroed(uint256 word) public {
        _buy(alice, 1);
        _buy(bob, 50);
        _buy(carol, 3);
        _buy(dave, 1_000);
        _finalizeAndFulfill(word);
        IMDPot.Round memory round = pot.getRound(1);
        for (uint256 i; i < 3; ++i) {
            assertTrue(round.winners[i] != address(0));
            assertEq(pot.weightOf(1, round.winners[i]), 0);
            for (uint256 j = i + 1; j < 3; ++j) {
                assertTrue(round.winners[i] != round.winners[j]);
            }
        }
        // Exactly one participant remains undrawn, with its full weight.
        assertEq(pot.totalWeight(1), pot.ticketsOf(1, _loser(round.winners)) * 10_000);
        assertEq(pot.totalClaimable(), (round.pool * 70) / 100);
        _assertSolvent();
    }

    function _loser(address[3] memory winners) internal view returns (address) {
        address[4] memory all = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            if (all[i] != winners[0] && all[i] != winners[1] && all[i] != winners[2]) return all[i];
        }
        revert("no loser");
    }

    function test_settlement_moreTicketsMeanMoreFirstPlaceWins() public {
        // dave holds 90% of the tickets; over many independent random words he should take first place
        // far more often than alice, bob and carol combined. Deterministic words keep the test reproducible.
        uint256 daveWins;
        uint256 rounds = 60;
        for (uint256 i; i < rounds; ++i) {
            _buy(alice, 1);
            _buy(bob, 1);
            _buy(carol, 1);
            _buy(dave, 27);
            uint256 roundId = _finalizeAndFulfill(uint256(keccak256(abi.encode("fair", i))));
            if (pot.getRound(roundId).winners[0] == dave) daveWins++;
        }
        assertGt(daveWins, (rounds * 75) / 100, "weighted selection favours the larger holder");
        assertLt(daveWins, rounds, "small holders still win sometimes");
    }

    // ------------------------------------------------------------------ randomness delivery

    function test_fulfill_onlyCoordinator() public {
        _buy(alice, 1);
        uint256 requestId = _finalize();
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.OnlyCoordinatorCanFulfill.selector, alice, address(coordinator)));
        pot.rawFulfillRandomWords(requestId, words);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.OnlyCoordinatorCanFulfill.selector, OWNER, address(coordinator)));
        pot.rawFulfillRandomWords(requestId, words);
    }

    function test_fulfill_ignoresUnknownRequestAndEmptyWords() public {
        _buy(alice, 1);
        uint256 requestId = _finalize();
        uint256[] memory words = new uint256[](1);
        words[0] = 5;
        vm.expectEmit(true, false, false, true);
        emit IMDPot.StaleRandomnessIgnored(requestId + 1);
        coordinator.fulfillRaw(address(pot), requestId + 1, words);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Drawing));

        uint256[] memory none = new uint256[](0);
        vm.expectEmit(true, false, false, true);
        emit IMDPot.StaleRandomnessIgnored(requestId);
        coordinator.fulfillRaw(address(pot), requestId, none);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Drawing));

        coordinator.fulfill(requestId, 5);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Finalized));
        // A duplicate delivery after settlement is ignored too.
        coordinator.fulfill(requestId, 6);
        assertEq(pot.currentRoundId(), 2);
        assertEq(pot.getRound(1).randomWord, 5);
    }

    function test_fulfill_fitsWithinCallbackGasForManyParticipants() public {
        for (uint256 i; i < 40; ++i) {
            address p = makeAddr(string(abi.encodePacked("p", i)));
            _fund(p);
            _buy(p, 1 + i);
        }
        uint256 requestId = _finalize();
        bool ok = coordinator.fulfillWithGas(requestId, 31_337, 600_000);
        assertTrue(ok, "settlement must fit the documented callback gas");
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Finalized));
    }

    function test_retry_reRequestsAfterDelayAndIgnoresOldFulfillment() public {
        _buy(alice, 1);
        _buy(bob, 1);
        uint256 first = _finalize();
        vm.expectRevert(IMDPot.RetryTooEarly.selector);
        pot.retryRandomness();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        pot.retryRandomness();
        uint256 second = pot.getRound(1).vrfRequestId;
        assertEq(second, first + 1);
        coordinator.fulfill(first, 1); // stale, ignored
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Drawing));
        coordinator.fulfill(second, 2);
        assertEq(uint8(pot.getRound(1).status), uint8(IMDPot.RoundStatus.Finalized));
        assertEq(pot.getRound(1).randomWord, 2);
    }

    function test_retry_revertsWhenNotDrawing() public {
        vm.expectRevert(IMDPot.RoundNotDrawing.selector);
        pot.retryRandomness();
        _buy(alice, 1);
        vm.expectRevert(IMDPot.RoundNotDrawing.selector);
        pot.retryRandomness();
    }

    // ------------------------------------------------------------------ claims

    function test_claim_paysWinnersOnceAndOnlyWinners() public {
        _buy(alice, 10);
        _buy(bob, 10);
        _buy(carol, 10);
        _finalizeAndFulfill(11);
        IMDPot.Round memory round = pot.getRound(1);
        address first = round.winners[0];
        uint256 before = token.balanceOf(first);
        uint256 prize = pot.claimable(first);

        vm.expectEmit(true, false, false, true);
        emit IMDPot.PrizeClaimed(first, prize);
        vm.prank(first);
        pot.claim();
        assertEq(token.balanceOf(first) - before, prize);
        assertEq(pot.claimable(first), 0);
        assertEq(pot.totalClaimable(), round.prizes[1] + round.prizes[2]);

        vm.prank(first);
        vm.expectRevert(IMDPot.NothingToClaim.selector);
        pot.claim();
        vm.prank(dave);
        vm.expectRevert(IMDPot.NothingToClaim.selector);
        pot.claim();
        _assertSolvent();
    }

    function test_claim_accumulatesAcrossRounds() public {
        _buy(alice, 1);
        _finalizeAndFulfill(1);
        _buy(alice, 1);
        _finalizeAndFulfill(2);
        assertEq(pot.claimable(alice), (2 * ticketPrice * 70) / 100);
        vm.prank(alice);
        pot.claim();
        assertEq(pot.totalClaimable(), 0);
        assertEq(token.balanceOf(address(pot)), pot.totalLocked());
    }

    // ------------------------------------------------------------------ loyalty points & multiplier

    function test_points_creditedProportionallyAfterFinalization() public {
        _buy(alice, 30);
        _buy(bob, 70);
        (uint256 pts,,,) = pot.getPlayer(alice);
        assertEq(pts, 0, "no points before the round is final");
        _finalizeAndFulfill(3);

        (uint256 alicePts, uint256 aliceRounds,,) = pot.getPlayer(alice);
        (uint256 bobPts, uint256 bobRounds,,) = pot.getPlayer(bob);
        assertEq(alicePts, 30);
        assertEq(bobPts, 70);
        assertEq(aliceRounds, 1);
        assertEq(bobRounds, 1);

        vm.expectEmit(true, true, false, true);
        emit IMDPot.PointsCredited(alice, 1, 30, 1);
        pot.syncPoints(alice);
        (alicePts, aliceRounds,,) = pot.getPlayer(alice);
        assertEq(alicePts, 30);
        assertEq(aliceRounds, 1);
        pot.syncPoints(alice); // idempotent
        (alicePts, aliceRounds,,) = pot.getPlayer(alice);
        assertEq(alicePts, 30);
        assertEq(aliceRounds, 1);
    }

    function test_points_syncOnNextPurchaseAndNotForCancelledRounds() public {
        _buy(alice, 4);
        _finalizeAndFulfill(1);
        _buy(alice, 6); // syncs round 1 then enters round 2
        (uint256 pts, uint256 rounds,,) = pot.getPlayer(alice);
        assertEq(pts, 4);
        assertEq(rounds, 1);

        coordinator.setShouldRevert(true);
        vm.warp(pot.getRound(2).endTime + 24 hours);
        pot.cancelRound();
        (pts, rounds,,) = pot.getPlayer(alice);
        assertEq(pts, 4, "cancelled rounds earn nothing");
        assertEq(rounds, 1);
        pot.syncPoints(alice);
        (pts, rounds,,) = pot.getPlayer(alice);
        assertEq(pts, 4);
        assertEq(rounds, 1);
    }

    function test_redeem_requiresTenRoundsAndPoints() public {
        _playRounds(alice, 10, 9);
        (uint256 pts, uint256 rounds,, bool canRedeem) = pot.getPlayer(alice);
        assertEq(pts, 90);
        assertEq(rounds, 9);
        assertFalse(canRedeem);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.InsufficientRoundsPlayed.selector, 9, 10));
        pot.redeemMultiplier();

        _playRounds(alice, 5, 1);
        (pts, rounds,, canRedeem) = pot.getPlayer(alice);
        assertEq(pts, 95);
        assertEq(rounds, 10);
        assertFalse(canRedeem);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMDPot.InsufficientPoints.selector, 95, 100));
        pot.redeemMultiplier();

        _playRounds(alice, 5, 1);
        (,,, canRedeem) = pot.getPlayer(alice);
        assertTrue(canRedeem);
        vm.expectEmit(true, false, false, true);
        emit IMDPot.MultiplierRedeemed(alice, 100, 2_500);
        vm.prank(alice);
        pot.redeemMultiplier();
        uint256 boost;
        (pts, rounds, boost,) = pot.getPlayer(alice);
        assertEq(pts, 0);
        assertEq(rounds, 11);
        assertEq(boost, 2_500);
    }

    function test_redeem_stacksToCapAndBoostsOnlyChancesNotPrize() public {
        _playRounds(alice, 100, 10); // 1_000 points, 10 rounds
        vm.startPrank(alice);
        pot.redeemMultiplier();
        pot.redeemMultiplier();
        pot.redeemMultiplier();
        pot.redeemMultiplier();
        (uint256 pts,, uint256 boost,) = pot.getPlayer(alice);
        assertEq(boost, 10_000);
        assertEq(pts, 600);
        vm.expectRevert(IMDPot.MultiplierAtMax.selector);
        pot.redeemMultiplier();
        vm.stopPrank();

        // The boost is consumed by the next round and doubles alice's selection weight only.
        uint256 roundId = pot.currentRoundId();
        vm.expectEmit(true, true, false, true);
        emit IMDPot.TicketsPurchased(roundId, alice, 10, 10 * ticketPrice, 10_000);
        _buy(alice, 10);
        _buy(bob, 10);
        _buy(alice, 5); // later tickets in the same round carry the same boost
        assertEq(pot.roundBoostBps(roundId, alice), 10_000);
        assertEq(pot.weightOf(roundId, alice), 15 * 20_000);
        assertEq(pot.weightOf(roundId, bob), 10 * 10_000);
        (,, boost,) = pot.getPlayer(alice);
        assertEq(boost, 0);

        uint256 pool = 25 * ticketPrice;
        _finalizeAndFulfill(5);
        IMDPot.Round memory round = pot.getRound(roundId);
        assertEq(round.prizes[0], (pool * 50) / 100, "prize split ignores the multiplier");
        assertEq(round.prizes[1], (pool * 20) / 100);
        (pts,,,) = pot.getPlayer(alice);
        assertEq(pts, 615, "points come from tickets, not weight");
        // The boost does not carry into the following round.
        _buy(alice, 1);
        assertEq(pot.weightOf(pot.currentRoundId(), alice), 10_000);
    }

    function test_points_cannotBeWithdrawnAsTokens() public {
        _playRounds(alice, 100, 10);
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        pot.redeemMultiplier();
        assertEq(token.balanceOf(alice), balanceBefore, "points never turn into IMD");
        assertEq(token.balanceOf(address(pot)), pot.totalObligations(), "redeeming moves no tokens");
    }

    // ------------------------------------------------------------------ pause

    function test_pause_blocksEntryAndFinalizeButNotExits() public {
        _buy(alice, 1);
        _finalizeAndFulfill(1);
        _buy(alice, 1);
        _buy(bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pot.pause();
        vm.prank(OWNER);
        pot.pause();

        vm.prank(carol);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pot.buyTickets(1);
        _endRound();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pot.finalizeRound();

        // Prizes from the earlier round stay claimable while paused.
        vm.prank(alice);
        pot.claim();

        // The stuck round can still be cancelled and refunded while paused.
        vm.warp(block.timestamp + 24 hours);
        pot.cancelRound();
        vm.prank(bob);
        pot.refund(2);
        assertEq(pot.ticketsOf(2, bob), 0);

        vm.prank(OWNER);
        pot.unpause();
        _buy(carol, 1);
        assertEq(pot.currentRoundId(), 3);
    }

    // ------------------------------------------------------------------ rescue

    function test_rescue_onlyForeignTokensAndOnlyOwner() public {
        MockIMDToken other = new MockIMDToken(18);
        other.mint(address(pot), 5 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pot.rescueForeignToken(address(other), alice);
        vm.startPrank(OWNER);
        vm.expectRevert(IMDPot.CannotRescueGameToken.selector);
        pot.rescueForeignToken(address(token), OWNER);
        vm.expectRevert(IMDPot.ZeroAddress.selector);
        pot.rescueForeignToken(address(other), address(0));
        pot.rescueForeignToken(address(other), OWNER);
        vm.stopPrank();
        assertEq(other.balanceOf(OWNER), 5 ether);
    }

    function test_deployScript_deploysWithExplicitOwner() public {
        DeployIMDPot deployer = new DeployIMDPot();
        IMDPot deployed = deployer.deploy(alice);
        assertEq(deployed.owner(), alice);
        assertEq(deployed.TREASURY(), TREASURY);
        assertEq(deployed.DEAD_ADDRESS(), DEAD);
        assertEq(deployed.ROUND_DURATION(), 15 minutes);
    }
}
