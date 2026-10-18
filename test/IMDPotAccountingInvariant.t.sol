// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Legacy deployment regression. Future-blockhash source is covered by FutureBlockhash.t.sol.

import {Test} from "forge-std/Test.sol";
import {IMDPot} from "./legacy/LegacyIMDPot.sol";
import {MockIMDToken} from "./mocks/MockIMDToken.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

/// @notice Drives full rounds, hostile callers, owner actions and blocked fee recipients, keeping ghost ledgers.
contract IMDPotAccountingHandler is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant TREASURY = 0x0b176115c1Bd31a782133100d3aaA6BE2b16F118;

    IMDPot public pot;
    MockIMDToken public token;
    MockVRFCoordinator public coordinator;
    address public owner;
    address[] public players;

    /// @dev Points spent on multipliers per player.
    mapping(address => uint256) public pointsSpent;
    /// @dev Tokens each player received from claim or refund.
    mapping(address => uint256) public received;
    /// @dev Tokens each player deposited.
    mapping(address => uint256) public deposited;
    /// @dev Count of calls that should have reverted but succeeded.
    uint256 public violations;
    uint256 public redemptions;
    uint256 public cancels;
    uint256 public settlements;

    constructor(IMDPot pot_, MockIMDToken token_, MockVRFCoordinator coordinator_, address owner_) {
        pot = pot_;
        token = token_;
        coordinator = coordinator_;
        owner = owner_;
        for (uint256 i; i < 5; ++i) {
            address p = address(uint160(0xA000 + i));
            players.push(p);
            token.mint(p, 10_000_000 ether);
            vm.prank(p);
            token.approve(address(pot), type(uint256).max);
        }
    }

    function _player(uint256 seed) internal view returns (address) {
        return players[seed % players.length];
    }

    function _buy(address p, uint256 count) internal {
        uint256 price = pot.ticketPrice();
        vm.prank(p);
        try pot.buyTickets(count) {
            deposited[p] += count * price;
        } catch {}
    }

    function buy(uint256 who, uint256 count) external {
        _buy(_player(who), bound(count, 1, 300));
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 26 hours));
    }

    function finalize(uint256 who) external {
        vm.prank(_player(who));
        try pot.finalizeRound() {} catch {}
    }

    function fulfill(uint256 word) external {
        IMDPot.Round memory r = pot.getRound(pot.currentRoundId());
        if (r.status != IMDPot.RoundStatus.Drawing) return;
        coordinator.fulfill(r.vrfRequestId, word);
        settlements++;
    }

    /// @dev Replays an arbitrary earlier request id; only a request issued for the round now drawing may settle it.
    function fulfillStale(uint256 id, uint256 word) external {
        uint256 next = coordinator.nextRequestId();
        if (next == 1) return;
        id = bound(id, 1, next - 1);
        uint256 roundId = pot.currentRoundId();
        IMDPot.Round memory r = pot.getRound(roundId);
        bool live = r.status == IMDPot.RoundStatus.Drawing && pot.requestRound(id) == roundId;
        coordinator.fulfill(id, word);
        if (!live && pot.currentRoundId() != roundId) violations++;
        if (live) settlements++;
    }

    /// @dev Plays a whole round: two or three players buy, the round ends and is settled.
    function playRound(uint256 seed, uint256 a, uint256 b, uint256 word) external {
        _playRound(seed % players.length, a, b, word);
    }

    /// @dev Plays several rounds in a row so the ten-round multiplier gate is reachable within the depth.
    function playManyRounds(uint256 seed, uint256 n, uint256 word) external {
        n = bound(n, 1, 10);
        seed = seed % players.length;
        for (uint256 i; i < n; ++i) {
            _playRound(seed, 10 + i, 1 + i, uint256(keccak256(abi.encode(word, i))));
            if (i % 3 == 2) seed++;
        }
    }

    function _playRound(uint256 seed, uint256 a, uint256 b, uint256 word) internal {
        uint256 roundId = pot.currentRoundId();
        if (pot.getRound(roundId).status == IMDPot.RoundStatus.Drawing) return;
        _buy(_player(seed), bound(a, 1, 60));
        _buy(_player(seed + 1), bound(b, 1, 60));
        if (seed % 3 == 0) _buy(_player(seed + 2), 1);
        IMDPot.Round memory r = pot.getRound(pot.currentRoundId());
        if (r.status != IMDPot.RoundStatus.Active) return;
        if (block.timestamp < r.endTime) vm.warp(r.endTime);
        try pot.finalizeRound() {
            coordinator.fulfill(pot.getRound(roundId).vrfRequestId, word);
            settlements++;
        } catch {}
    }

    function retry() external {
        try pot.retryRandomness() {} catch {}
    }

    function cancel() external {
        try pot.cancelRound() {
            cancels++;
        } catch {}
    }

    /// @dev A round nobody settles for a day: anyone may call cancel. An unfinalised round is drawn instead while
    ///      the coordinator accepts; a drawing round is cancelled once a day has passed since its latest request.
    function stallAndCancel(uint256 who, uint256 count) external {
        _buy(_player(who), bound(count, 1, 40));
        IMDPot.Round memory r = pot.getRound(pot.currentRoundId());
        if (r.status != IMDPot.RoundStatus.Active && r.status != IMDPot.RoundStatus.Drawing) return;
        uint256 from = r.endTime;
        if (r.status == IMDPot.RoundStatus.Drawing && r.randomnessRequestedAt > from) from = r.randomnessRequestedAt;
        uint256 at = from + pot.CANCEL_DELAY();
        if (block.timestamp < at) vm.warp(at);
        try pot.cancelRound() {
            cancels++;
        } catch {
            violations++;
        }
    }

    function claim(uint256 who) external {
        address p = _player(who);
        uint256 amount = pot.claimable(p);
        uint256 before = token.balanceOf(p);
        vm.prank(p);
        try pot.claim() {
            if (token.balanceOf(p) - before != amount) violations++;
            received[p] += amount;
        } catch {}
    }

    function refund(uint256 who, uint256 roundId) external {
        address p = _player(who);
        roundId = bound(roundId, 1, pot.currentRoundId());
        uint256 amount = pot.ticketsOf(roundId, p) * pot.ticketPrice();
        vm.prank(p);
        try pot.refund(roundId) {
            received[p] += amount;
        } catch {}
    }

    function redeem(uint256 who) external {
        address p = _player(who);
        vm.prank(p);
        try pot.redeemMultiplier() {
            pointsSpent[p] += pot.MULTIPLIER_COST_POINTS();
            redemptions++;
        } catch {}
    }

    function flush() external {
        try pot.flushPendingFees() {} catch {}
    }

    function sync(uint256 who) external {
        pot.syncPoints(_player(who));
    }

    function toggleFeeBlock(bool dead, bool blocked) external {
        token.setBlocked(dead ? DEAD : TREASURY, blocked);
    }

    function ownerPause(bool on) external {
        vm.prank(owner);
        if (on) {
            try pot.pause() {} catch {}
        } else {
            try pot.unpause() {} catch {}
        }
    }

    /// @dev Neither the owner nor anyone else may ever move IMD out through an admin path.
    function ownerTriesToDrain(uint256 who) external {
        vm.prank(owner);
        try pot.rescueForeignToken(address(token), owner) {
            violations++;
        } catch {}
        address p = _player(who);
        vm.prank(p);
        try pot.rescueForeignToken(address(token), p) {
            violations++;
        } catch {}
        vm.prank(p);
        try pot.pause() {
            violations++;
        } catch {}
    }

    /// @dev Only the coordinator may deliver randomness.
    function strangerFulfills(uint256 who, uint256 word) external {
        IMDPot.Round memory r = pot.getRound(pot.currentRoundId());
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(_player(who));
        try pot.rawFulfillRandomWords(r.vrfRequestId, words) {
            violations++;
        } catch {}
        vm.prank(owner);
        try pot.rawFulfillRandomWords(r.vrfRequestId, words) {
            violations++;
        } catch {}
    }

    function playerCount() external view returns (uint256) {
        return players.length;
    }
}

/// @notice Exact accounting: every token in the contract is owed to someone, and the ledgers agree with the rounds.
contract IMDPotAccountingInvariantTest is Test {
    address internal constant OWNER = 0x34284C5C4c54d5f8e7E14E2D1a3DcD48899928EA;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant TREASURY = 0x0b176115c1Bd31a782133100d3aaA6BE2b16F118;

    IMDPot internal pot;
    MockIMDToken internal token;
    MockVRFCoordinator internal coordinator;
    IMDPotAccountingHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockIMDToken(18);
        coordinator = new MockVRFCoordinator();
        pot = new IMDPot(OWNER);
        vm.startPrank(OWNER);
        pot.setToken(address(token));
        pot.setVrfConfig(address(coordinator), 1, keccak256("kh"), 750_000, 3, false);
        vm.stopPrank();
        handler = new IMDPotAccountingHandler(pot, token, coordinator, OWNER);
        targetContract(address(handler));
    }

    /// @dev Nothing but this game's ledgers sends IMD here, so the balance equals the obligations exactly.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    function invariant_balanceEqualsObligationsAndLedgersAgree() public view {
        assertEq(token.balanceOf(address(pot)), pot.totalObligations(), "balance != obligations");

        uint256 sumClaimable;
        for (uint256 i; i < handler.playerCount(); ++i) {
            sumClaimable += pot.claimable(handler.players(i));
        }
        assertEq(sumClaimable, pot.totalClaimable(), "claimable ledger");

        uint256 locked;
        uint256 burned;
        uint256 fees;
        uint256 refundable;
        uint256 price = pot.ticketPrice();
        for (uint256 id = 1; id < pot.currentRoundId(); ++id) {
            IMDPot.Round memory r = pot.getRound(id);
            if (r.status == IMDPot.RoundStatus.Finalized) {
                locked += r.locked;
                burned += r.burned;
                fees += r.treasuryFee;
            } else {
                for (uint256 i; i < handler.playerCount(); ++i) {
                    refundable += pot.ticketsOf(id, handler.players(i)) * price;
                }
            }
        }
        assertEq(pot.totalLocked(), locked, "lock ledger");
        assertEq(token.balanceOf(DEAD) + pot.pendingBurn(), burned, "burn ledger");
        assertEq(token.balanceOf(TREASURY) + pot.pendingTreasury(), fees, "treasury ledger");
        assertEq(pot.totalRefundable(), refundable, "refund ledger");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    function invariant_pointsMatchFinalizedTicketsAndBoostIsCapped() public view {
        uint256 maxBoost = pot.MAX_MULTIPLIER_BONUS_BPS();
        for (uint256 i; i < handler.playerCount(); ++i) {
            address p = handler.players(i);
            uint256 earned;
            uint256 rounds;
            for (uint256 id = 1; id < pot.currentRoundId(); ++id) {
                if (pot.getRound(id).status != IMDPot.RoundStatus.Finalized) continue;
                uint256 t = pot.ticketsOf(id, p);
                earned += t;
                if (t > 0) rounds++;
                assertLe(pot.roundBoostBps(id, p), maxBoost, "round boost above cap");
            }
            (uint256 points, uint256 roundsPlayed, uint256 pending,) = pot.getPlayer(p);
            assertEq(points + handler.pointsSpent(p), earned, "points != finalized tickets - spent");
            assertEq(roundsPlayed, rounds, "rounds played");
            assertLe(pending, maxBoost, "pending boost above cap");
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    function invariant_noUnauthorizedSuccessAndWinnersArePlayers() public view {
        assertEq(handler.violations(), 0, "an unauthorized call succeeded");
        for (uint256 id = 1; id < pot.currentRoundId(); ++id) {
            IMDPot.Round memory r = pot.getRound(id);
            if (r.status != IMDPot.RoundStatus.Finalized) continue;
            assertLe(r.requestCount, pot.MAX_RANDOMNESS_REQUESTS(), "too many requests");
            uint256 filled = r.totalTickets < 3 ? r.totalTickets : 3;
            for (uint256 k; k < 3; ++k) {
                if (k < filled) {
                    address w = r.winners[k];
                    assertTrue(w != address(0), "empty podium slot with tickets left");
                    uint256 tickets = pot.ticketsOf(id, w);
                    assertGt(tickets, 0, "winner did not play");
                    uint256 times;
                    for (uint256 j; j < 3; ++j) {
                        if (r.winners[j] == w) times++;
                    }
                    assertLe(times, tickets, "more podium places than tickets");
                    // Each drawn ticket takes exactly one ticket's weight out of the tree.
                    assertEq(
                        pot.weightOf(id, w),
                        (tickets - times) * (10_000 + pot.roundBoostBps(id, w)),
                        "drawn ticket weight not removed"
                    );
                } else {
                    assertEq(r.winners[k], address(0));
                    assertEq(r.prizes[k], 0);
                }
            }
        }
    }

    /// @dev Across all players, nobody can take out more than was put in (the 30% house/burn/lock never returns).
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    function invariant_playersCollectivelyNeverProfit() public view {
        uint256 inTotal;
        uint256 outTotal;
        for (uint256 i; i < handler.playerCount(); ++i) {
            address p = handler.players(i);
            inTotal += handler.deposited(p);
            outTotal += handler.received(p);
        }
        assertLe(outTotal + pot.totalClaimable() + pot.totalRefundable(), inTotal);
        assertEq(inTotal, token.balanceOf(address(pot)) + token.balanceOf(DEAD) + token.balanceOf(TREASURY) + outTotal);
    }
}
