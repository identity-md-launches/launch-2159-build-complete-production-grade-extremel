// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDPot} from "../src/IMDPot.sol";
import {DeployIMDPot} from "../script/DeployIMDPot.s.sol";
import {MockIMDToken} from "./mocks/MockIMDToken.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

/// @notice Shared fixture: deployed and configured IMDPot with funded players.
abstract contract IMDPotBase is Test {
    address internal constant OWNER = 0x34284C5C4c54d5f8e7E14E2D1a3DcD48899928EA;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant TREASURY = 0x0b176115c1Bd31a782133100d3aaA6BE2b16F118;
    bytes32 internal constant KEY_HASH = keccak256("key-hash");
    uint256 internal constant SUB_ID = 777;
    uint32 internal constant CALLBACK_GAS = 750_000;
    uint16 internal constant CONFIRMATIONS = 3;

    IMDPot internal pot;
    MockIMDToken internal token;
    MockVRFCoordinator internal coordinator;
    uint256 internal ticketPrice;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        token = new MockIMDToken(18);
        coordinator = new MockVRFCoordinator();
        pot = new DeployIMDPot().deploy(OWNER);
        vm.startPrank(OWNER);
        pot.setToken(address(token));
        pot.setVrfConfig(address(coordinator), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, false);
        vm.stopPrank();
        ticketPrice = pot.ticketPrice();
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(dave);
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

    function _endRound() internal {
        IMDPot.Round memory round = pot.getRound(pot.currentRoundId());
        vm.warp(round.endTime);
    }

    /// @dev Ends the current round, requests randomness and returns the request id.
    function _finalize() internal returns (uint256 requestId) {
        _endRound();
        vm.prank(keeper);
        pot.finalizeRound();
        requestId = pot.getRound(pot.currentRoundId()).vrfRequestId;
    }

    /// @dev Full round settlement with `word` as the random word.
    function _finalizeAndFulfill(uint256 word) internal returns (uint256 roundId) {
        roundId = pot.currentRoundId();
        uint256 requestId = _finalize();
        coordinator.fulfill(requestId, word);
    }

    /// @dev Plays `n` complete rounds where `player` buys `tickets` each time (plus bob so there are two players).
    function _playRounds(address player, uint256 tickets, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _buy(player, tickets);
            _buy(bob, 1);
            _finalizeAndFulfill(uint256(keccak256(abi.encode("round", i))));
        }
    }

    function _assertSolvent() internal view {
        assertGe(token.balanceOf(address(pot)), pot.totalObligations(), "insolvent");
    }
}
