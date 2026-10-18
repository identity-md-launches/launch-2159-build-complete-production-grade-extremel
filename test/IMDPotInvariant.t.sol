// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Legacy deployment regression. Future-blockhash source is covered by FutureBlockhash.t.sol.

import {Test} from "forge-std/Test.sol";
import {IMDPot} from "./legacy/LegacyIMDPot.sol";
import {MockIMDToken} from "./mocks/MockIMDToken.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

/// @notice Drives the game through random sequences of player and keeper actions.
contract IMDPotHandler is Test {
    IMDPot public pot;
    MockIMDToken public token;
    MockVRFCoordinator public coordinator;
    address[] public players;
    uint256 public totalDeposited;
    uint256 public totalPaidOut;
    uint256 public fulfilled;
    uint256 public cancelled;

    constructor(IMDPot pot_, MockIMDToken token_, MockVRFCoordinator coordinator_) {
        pot = pot_;
        token = token_;
        coordinator = coordinator_;
        for (uint256 i; i < 6; ++i) {
            address p = address(uint160(0x1000 + i));
            players.push(p);
            token.mint(p, 1_000_000 ether);
            vm.prank(p);
            token.approve(address(pot), type(uint256).max);
        }
    }

    function buy(uint256 who, uint256 count) external {
        address p = players[who % players.length];
        count = bound(count, 1, 500);
        vm.prank(p);
        try pot.buyTickets(count) {
            totalDeposited += count * pot.ticketPrice();
        } catch {}
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 30 hours));
    }

    function finalize() external {
        try pot.finalizeRound() {} catch {}
    }

    function fulfill(uint256 word) external {
        uint256 roundId = pot.currentRoundId();
        IMDPot.Round memory round = pot.getRound(roundId);
        if (round.status != IMDPot.RoundStatus.Drawing) return;
        coordinator.fulfill(round.vrfRequestId, word);
        fulfilled++;
    }

    function retry() external {
        try pot.retryRandomness() {} catch {}
    }

    function cancel() external {
        try pot.cancelRound() {
            cancelled++;
        } catch {}
    }

    function claim(uint256 who) external {
        address p = players[who % players.length];
        uint256 amount = pot.claimable(p);
        vm.prank(p);
        try pot.claim() {
            totalPaidOut += amount;
        } catch {}
    }

    function refund(uint256 who, uint256 roundId) external {
        address p = players[who % players.length];
        roundId = bound(roundId, 1, pot.currentRoundId());
        uint256 amount = pot.ticketsOf(roundId, p) * pot.ticketPrice();
        vm.prank(p);
        try pot.refund(roundId) {
            totalPaidOut += amount;
        } catch {}
    }

    function redeem(uint256 who) external {
        address p = players[who % players.length];
        vm.prank(p);
        try pot.redeemMultiplier() {} catch {}
    }

    function flush() external {
        try pot.flushPendingFees() {} catch {}
    }

    function playerCount() external view returns (uint256) {
        return players.length;
    }
}

/// @notice Conservation of funds and monotonic lock under random action sequences.
contract IMDPotInvariantTest is Test {
    address internal constant OWNER = 0x34284C5C4c54d5f8e7E14E2D1a3DcD48899928EA;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant TREASURY = 0x0b176115c1Bd31a782133100d3aaA6BE2b16F118;

    IMDPot internal pot;
    MockIMDToken internal token;
    MockVRFCoordinator internal coordinator;
    IMDPotHandler internal handler;
    uint256 internal lastLocked;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockIMDToken(18);
        coordinator = new MockVRFCoordinator();
        pot = new IMDPot(OWNER);
        vm.startPrank(OWNER);
        pot.setToken(address(token));
        pot.setVrfConfig(address(coordinator), 1, keccak256("kh"), 750_000, 3, false);
        vm.stopPrank();
        handler = new IMDPotHandler(pot, token, coordinator);
        targetContract(address(handler));
    }

    function invariant_balanceCoversObligations() public view {
        assertGe(token.balanceOf(address(pot)), pot.totalObligations());
    }

    function invariant_depositsAreFullyAccountedFor() public view {
        uint256 held = token.balanceOf(address(pot));
        uint256 burned = token.balanceOf(DEAD);
        uint256 fees = token.balanceOf(TREASURY);
        assertEq(handler.totalDeposited(), held + burned + fees + handler.totalPaidOut());
    }

    function invariant_lockedNeverDecreases() public {
        uint256 locked = pot.totalLocked();
        assertGe(locked, lastLocked);
        lastLocked = locked;
    }

    function invariant_currentRoundIsNeverSettled() public view {
        IMDPot.Round memory round = pot.getRound(pot.currentRoundId());
        assertTrue(round.status != IMDPot.RoundStatus.Finalized && round.status != IMDPot.RoundStatus.Cancelled);
        for (uint256 id = 1; id < pot.currentRoundId(); ++id) {
            IMDPot.RoundStatus status = pot.getRound(id).status;
            assertTrue(status == IMDPot.RoundStatus.Finalized || status == IMDPot.RoundStatus.Cancelled);
        }
    }

    function invariant_prizesSumToSeventyPercentAndSlotsAreFilledByTickets() public view {
        for (uint256 id = 1; id < pot.currentRoundId(); ++id) {
            IMDPot.Round memory round = pot.getRound(id);
            if (round.status != IMDPot.RoundStatus.Finalized) continue;
            uint256 prizes = round.prizes[0] + round.prizes[1] + round.prizes[2];
            assertEq(prizes, (round.pool * 70) / 100);
            assertEq(round.burned, (round.pool * 10) / 100);
            assertEq(round.treasuryFee, (round.pool * 5) / 100);
            assertEq(prizes + round.burned + round.treasuryFee + round.locked, round.pool);
            // One drawn ticket per slot: as many slots are filled as there are tickets (up to three), an empty
            // slot carries no prize, and a player never fills more slots than tickets they hold.
            uint256 filled;
            for (uint256 i; i < 3; ++i) {
                if (round.winners[i] != address(0)) {
                    filled++;
                } else {
                    assertEq(round.prizes[i], 0);
                }
            }
            assertEq(filled, round.totalTickets < 3 ? round.totalTickets : 3);
            for (uint256 i; i < 3; ++i) {
                if (round.winners[i] == address(0)) continue;
                uint256 slots;
                for (uint256 j; j < 3; ++j) {
                    if (round.winners[j] == round.winners[i]) slots++;
                }
                assertLe(slots, pot.ticketsOf(id, round.winners[i]));
            }
        }
    }
}
