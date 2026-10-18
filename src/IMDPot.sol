// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {WeightedTree} from "./libraries/WeightedTree.sol";

/// @title IMDPot
/// @notice A 15-minute, IMD-only jackpot using a committed future blockhash.
/// @dev First finalizeRound() after endTime commits block.number + DRAW_DELAY_BLOCKS.
///      A second permissionless call AFTER that block settles the round, within 256 blocks.
///      Tickets close before commitment. The target cannot be changed or re-rolled.
///      Committed draws settle even while paused; expired draws permit full refunds.
///      Block producers can influence hashes and censor settlement. This inexpensive method
///      is NOT cryptographically unbiased randomness. See docs/SECURITY.md.
///      Fees, weighted ticket selection, claims, loyalty and permanent locks retain their rules.
contract IMDPot is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using WeightedTree for WeightedTree.Tree;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice Lifecycle of a round.
    /// @dev `Open` is the default (zero) state: the round exists but has no tickets and no timer.
    enum RoundStatus {
        Open,
        Active,
        Drawing,
        Finalized,
        Cancelled
    }

    /// @notice Everything recorded about a round.
    struct Round {
        RoundStatus status;
        uint64 startTime;
        uint64 endTime;
        uint256 pool;
        uint256 totalTickets;
        uint256 participantCount;
        /// @notice Immutable target selected before its hash exists.
        uint256 drawBlock;
        /// @notice Saved at settlement so the draw can be audited after BLOCKHASH expires.
        bytes32 drawBlockHash;
        uint256 randomWord;
        address[3] winners;
        uint256[3] prizes;
        uint256 burned;
        uint256 treasuryFee;
        uint256 locked;
    }

    /// @notice Loyalty state of a player.
    struct Player {
        /// @dev Points already credited.
        uint256 points;
        /// @dev Rounds in which the player participated and which were finalised.
        uint256 roundsPlayed;
        /// @dev Multiplier bonus (in bps) waiting to be applied to the player's next round.
        uint256 pendingBoostBps;
        /// @dev Last round the player entered whose outcome has not yet been synced into `points`.
        uint256 unsyncedRound;
    }

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Length of a round once its timer has started.
    uint256 public constant ROUND_DURATION = 15 minutes;
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Share of the pool claimable by the first-place winner.
    uint256 public constant FIRST_PRIZE_BPS = 4_000;
    /// @notice Share of the pool claimable by the second-place winner.
    uint256 public constant SECOND_PRIZE_BPS = 2_000;
    /// @notice Share of the pool claimable by the third-place winner.
    uint256 public constant THIRD_PRIZE_BPS = 1_000;
    /// @notice Share of the pool burned to the dead address.
    uint256 public constant BURN_BPS = 1_000;
    /// @notice Share of the pool sent to the treasury (the 5% house fee).
    uint256 public constant TREASURY_BPS = 500;
    /// @notice Share of the pool locked forever in this contract (absorbs rounding dust).
    uint256 public constant LOCK_BPS = 1_500;
    /// @notice Number of podium slots.
    uint256 public constant WINNER_SLOTS = 3;
    /// @notice Maximum tickets a single purchase may contain (input sanity bound).
    uint256 public constant MAX_TICKETS_PER_PURCHASE = 1_000_000;
    /// @notice Number of blocks ahead committed by the first finalizeRound() call.
    uint256 public constant DRAW_DELAY_BLOCKS = 3;
    /// @notice EVM BLOCKHASH lookback, excluding the current block.
    uint256 public constant BLOCKHASH_WINDOW = 256;
    /// @notice Recovery delay for an active round paused before any draw was committed.
    uint256 public constant CANCEL_DELAY = 24 hours;
    /// @notice Rounds a player must have completed before redeeming points for a multiplier.
    uint256 public constant ROUNDS_FOR_MULTIPLIER = 10;
    /// @notice Points burned per multiplier redemption.
    uint256 public constant MULTIPLIER_COST_POINTS = 100;
    /// @notice Bonus chance (in bps of ticket weight) granted per redemption. 2_500 = +25%.
    uint256 public constant MULTIPLIER_STEP_BPS = 2_500;
    /// @notice Maximum accumulated bonus. 10_000 = +100% (each ticket counts twice).
    uint256 public constant MAX_MULTIPLIER_BONUS_BPS = 10_000;
    /// @notice The burn destination.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice The treasury wallet that receives the 5% house fee.
    address public constant TREASURY = 0x0b176115c1Bd31a782133100d3aaA6BE2b16F118;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice The $IMD token. Set once by the owner; zero until configured.
    IERC20 public token;
    /// @notice Price of one ticket in token units (0.1 IMD, derived from the token's decimals).
    uint256 public ticketPrice;

    /// @notice Identifier of the round currently accepting tickets or being drawn.
    uint256 public currentRoundId = 1;
    /// @notice Round records by identifier.
    mapping(uint256 roundId => Round) internal _rounds;
    /// @dev Weighted selection tree per round.
    mapping(uint256 roundId => WeightedTree.Tree) internal _trees;
    /// @dev Participant addresses per round, 1-based through `participantIndex`.
    mapping(uint256 roundId => address[]) internal _participants;
    /// @notice 1-based index of a player in a round, 0 if not a participant.
    mapping(uint256 roundId => mapping(address player => uint256)) public participantIndex;
    /// @notice Tickets a player holds in a round (zeroed on refund).
    mapping(uint256 roundId => mapping(address player => uint256)) public ticketsOf;
    /// @notice Multiplier bonus (bps) applied to a player's tickets in a round.
    mapping(uint256 roundId => mapping(address player => uint256)) public roundBoostBps;
    /// @notice Prize tokens a player may withdraw with `claim`.
    mapping(address player => uint256) public claimable;
    /// @notice Loyalty state per player.
    mapping(address player => Player) internal _players;

    /// @notice Sum of all unclaimed prizes.
    uint256 public totalClaimable;
    /// @notice Sum of all refunds still owed for cancelled rounds.
    uint256 public totalRefundable;
    /// @notice Tokens locked forever in this contract (15% of every finalised pool plus dust).
    uint256 public totalLocked;
    /// @notice Burn amounts whose push transfer failed and that anyone may `flushPendingFees`.
    uint256 public pendingBurn;
    /// @notice Treasury amounts whose push transfer failed and that anyone may `flushPendingFees`.
    uint256 public pendingTreasury;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event TokenSet(address indexed token, uint256 ticketPrice);
    event RoundStarted(uint256 indexed roundId, uint64 startTime, uint64 endTime);
    event TicketsPurchased(
        uint256 indexed roundId, address indexed player, uint256 tickets, uint256 amount, uint256 boostBps
    );
    event DrawCommitted(uint256 indexed roundId, uint256 indexed drawBlock, address indexed caller);
    event RoundFinalized(
        uint256 indexed roundId,
        uint256 randomWord,
        address[3] winners,
        uint256[3] prizes,
        uint256 burned,
        uint256 treasuryFee,
        uint256 locked
    );
    event RoundCancelled(uint256 indexed roundId, uint256 pool, address indexed caller);
    event PrizeClaimed(address indexed player, uint256 amount);
    event Refunded(uint256 indexed roundId, address indexed player, uint256 amount);
    event FeeTransferred(address indexed to, uint256 amount);
    event FeeTransferDeferred(address indexed to, uint256 amount);
    event PointsCredited(address indexed player, uint256 indexed roundId, uint256 points, uint256 roundsPlayed);
    event MultiplierRedeemed(address indexed player, uint256 pointsSpent, uint256 pendingBoostBps);
    event MultiplierRestored(address indexed player, uint256 indexed roundId, uint256 pendingBoostBps);
    event PointsRefunded(address indexed player, uint256 indexed roundId, uint256 points);
    event ForeignTokenRescued(address indexed foreignToken, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error TokenNotConfigured();
    error TokenAlreadySet();
    error InvalidTokenDecimals();
    error NotAContract(address account);
    error InvalidTicketCount();
    error RoundClosed();
    error RoundDrawing();
    error RoundNotActive();
    error RoundNotEnded();
    error DrawNotReady(uint256 drawBlock);
    error DrawExpired(uint256 drawBlock);
    error DrawHashUnavailable(uint256 drawBlock);
    error CancelTooEarly();
    error OwnershipCannotBeRenounced();
    error RoundNotCancelled();
    error NothingToClaim();
    error NothingToRefund();
    error NothingToFlush();
    error TransferAmountMismatch();
    error InsufficientRoundsPlayed(uint256 have, uint256 need);
    error InsufficientPoints(uint256 have, uint256 need);
    error MultiplierAtMax();
    error CannotRescueGameToken();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param owner_ The account that administers the game. Never the deployer.
    /// @dev Makes no external call and requires no deployed contract so it can run on an empty chain.
    constructor(address owner_) Ownable(owner_) {}

    // ---------------------------------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the $IMD token. Can only be called once.
    /// @param token_ The $IMD ERC-20 contract on this chain.
    function setToken(address token_) external onlyOwner {
        if (token_ == address(0)) revert ZeroAddress();
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (token_.code.length == 0) revert NotAContract(token_);
        uint8 decimals = IERC20Metadata(token_).decimals();
        if (decimals == 0 || decimals > 36) revert InvalidTokenDecimals();
        token = IERC20(token_);
        ticketPrice = (10 ** uint256(decimals)) / 10;
        emit TokenSet(token_, ticketPrice);
    }

    /// @notice Ownership can be transferred (two-step) but not renounced, so pausing remains reversible.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Stops new entries and commitments. Committed draws, claims and refunds keep working.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes the game.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Returns tokens other than $IMD that were sent here by mistake. $IMD can never be rescued.
    /// @param foreignToken The token to return.
    /// @param to The recipient.
    function rescueForeignToken(address foreignToken, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (foreignToken == address(token) || foreignToken == address(0)) revert CannotRescueGameToken();
        uint256 amount = IERC20(foreignToken).balanceOf(address(this));
        emit ForeignTokenRescued(foreignToken, to, amount);
        IERC20(foreignToken).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Player actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Buys `count` tickets at `ticketPrice` each for the current round. Starts the round timer if the
    ///         round has not started. Requires a prior `approve` of `count * ticketPrice`.
    /// @param count Number of tickets, 1..MAX_TICKETS_PER_PURCHASE.
    function buyTickets(uint256 count) external nonReentrant whenNotPaused {
        if (address(token) == address(0)) revert TokenNotConfigured();
        if (count == 0 || count > MAX_TICKETS_PER_PURCHASE) revert InvalidTicketCount();

        uint256 roundId = currentRoundId;
        Round storage round = _rounds[roundId];
        if (round.status == RoundStatus.Drawing) revert RoundDrawing();
        if (round.status == RoundStatus.Active && block.timestamp >= round.endTime) revert RoundClosed();

        _syncPlayer(msg.sender);

        uint256 amount = count * ticketPrice;
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - balanceBefore != amount) revert TransferAmountMismatch();

        if (round.status == RoundStatus.Open) {
            round.status = RoundStatus.Active;
            round.startTime = uint64(block.timestamp);
            round.endTime = uint64(block.timestamp + ROUND_DURATION);
            emit RoundStarted(roundId, round.startTime, round.endTime);
        }

        round.pool += amount;
        round.totalTickets += count;
        ticketsOf[roundId][msg.sender] += count;

        Player storage player = _players[msg.sender];
        uint256 index = participantIndex[roundId][msg.sender];
        uint256 boost;
        if (index == 0) {
            boost = player.pendingBoostBps;
            player.pendingBoostBps = 0;
            roundBoostBps[roundId][msg.sender] = boost;
            player.unsyncedRound = roundId;
            _participants[roundId].push(msg.sender);
            round.participantCount += 1;
            index = _trees[roundId].append(count * (BPS + boost));
            participantIndex[roundId][msg.sender] = index;
        } else {
            boost = roundBoostBps[roundId][msg.sender];
            _trees[roundId].add(index, count * (BPS + boost));
        }

        emit TicketsPurchased(roundId, msg.sender, count, amount, boost);
    }

    /// @notice Commits a future block on the first call; settles from its hash on a later call.
    /// @dev No callback, keeper subscription or oracle payment. The caller pays normal transaction gas.
    ///      Settlement must be included at drawBlock + 1 through drawBlock + 256 inclusive.
    ///      A paused game still settles an existing commitment, so the owner cannot veto known winners.
    function finalizeRound() external nonReentrant {
        uint256 roundId = currentRoundId;
        Round storage round = _rounds[roundId];
        if (round.status == RoundStatus.Active) {
            _requireNotPaused();
            if (block.timestamp < round.endTime) revert RoundNotEnded();
            round.status = RoundStatus.Drawing;
            round.drawBlock = block.number + DRAW_DELAY_BLOCKS;
            emit DrawCommitted(roundId, round.drawBlock, msg.sender);
            return;
        }
        if (round.status != RoundStatus.Drawing) revert RoundNotActive();
        uint256 target = round.drawBlock;
        if (block.number <= target) revert DrawNotReady(target);
        if (block.number > target + BLOCKHASH_WINDOW) revert DrawExpired(target);
        bytes32 entropy = blockhash(target);
        if (entropy == bytes32(0)) revert DrawHashUnavailable(target);
        round.drawBlockHash = entropy;
        // Bind the hash to this deployment, chain and round. Caller and settlement timing add no entropy.
        uint256 word = uint256(keccak256(abi.encode(entropy, block.chainid, address(this), roundId)));
        _settle(roundId, round, word);
    }

    /// @notice Cancels an expired commitment, or a never-committed paused round after 24 hours.
    /// @dev No re-roll: only a full refund. A readable committed hash can never be discarded by cancellation.
    ///      Permissionless and available while paused. A live, unpaused round must be finalized instead.
    function cancelRound() external nonReentrant {
        uint256 roundId = currentRoundId;
        Round storage round = _rounds[roundId];
        if (round.status == RoundStatus.Drawing) {
            if (block.number <= round.drawBlock + BLOCKHASH_WINDOW) revert CancelTooEarly();
        } else if (round.status == RoundStatus.Active) {
            if (!paused() || block.timestamp < uint256(round.endTime) + CANCEL_DELAY) revert CancelTooEarly();
        } else {
            revert RoundNotActive();
        }
        round.status = RoundStatus.Cancelled;
        totalRefundable += round.pool;
        currentRoundId = roundId + 1;
        emit RoundCancelled(roundId, round.pool, msg.sender);
    }

    /// @notice Withdraws all prizes the caller has won. Works while paused.
    function claim() external nonReentrant {
        _syncPlayer(msg.sender);
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        emit PrizeClaimed(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Refunds the caller's tickets from a cancelled round and restores any multiplier spent on it. Boost
    ///         that no longer fits under `MAX_MULTIPLIER_BONUS_BPS` (the player redeemed again while the round
    ///         was in flight) is converted back into the points it cost.
    /// @param roundId The cancelled round.
    function refund(uint256 roundId) external nonReentrant {
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.Cancelled) revert RoundNotCancelled();
        uint256 tickets = ticketsOf[roundId][msg.sender];
        if (tickets == 0) revert NothingToRefund();
        ticketsOf[roundId][msg.sender] = 0;
        uint256 amount = tickets * ticketPrice;
        totalRefundable -= amount;

        _syncPlayer(msg.sender);
        uint256 boost = roundBoostBps[roundId][msg.sender];
        if (boost != 0) {
            roundBoostBps[roundId][msg.sender] = 0;
            Player storage player = _players[msg.sender];
            uint256 restored = player.pendingBoostBps + boost;
            if (restored > MAX_MULTIPLIER_BONUS_BPS) {
                // Every redemption adds exactly MULTIPLIER_STEP_BPS, so the excess is a whole number of steps.
                uint256 pointsBack =
                    ((restored - MAX_MULTIPLIER_BONUS_BPS) / MULTIPLIER_STEP_BPS) * MULTIPLIER_COST_POINTS;
                restored = MAX_MULTIPLIER_BONUS_BPS;
                player.points += pointsBack;
                emit PointsRefunded(msg.sender, roundId, pointsBack);
            }
            player.pendingBoostBps = restored;
            emit MultiplierRestored(msg.sender, roundId, restored);
        }

        emit Refunded(roundId, msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Credits points from the player's last finalised round. Called automatically on every player
    ///         action; exposed so anyone can keep dashboards current.
    /// @param player The player to sync.
    function syncPoints(address player) external {
        _syncPlayer(player);
    }

    /// @notice Burns `MULTIPLIER_COST_POINTS` points for a `MULTIPLIER_STEP_BPS` bonus on the caller's next
    ///         round. Requires `ROUNDS_FOR_MULTIPLIER` finalised rounds. Bonuses stack up to
    ///         `MAX_MULTIPLIER_BONUS_BPS` and only add chances, never prize size.
    function redeemMultiplier() external nonReentrant {
        _syncPlayer(msg.sender);
        Player storage player = _players[msg.sender];
        if (player.roundsPlayed < ROUNDS_FOR_MULTIPLIER) {
            revert InsufficientRoundsPlayed(player.roundsPlayed, ROUNDS_FOR_MULTIPLIER);
        }
        if (player.points < MULTIPLIER_COST_POINTS) revert InsufficientPoints(player.points, MULTIPLIER_COST_POINTS);
        if (player.pendingBoostBps >= MAX_MULTIPLIER_BONUS_BPS) revert MultiplierAtMax();
        player.points -= MULTIPLIER_COST_POINTS;
        uint256 boosted = player.pendingBoostBps + MULTIPLIER_STEP_BPS;
        player.pendingBoostBps = boosted > MAX_MULTIPLIER_BONUS_BPS ? MAX_MULTIPLIER_BONUS_BPS : boosted;
        emit MultiplierRedeemed(msg.sender, MULTIPLIER_COST_POINTS, player.pendingBoostBps);
    }

    /// @notice Pushes burn or treasury amounts whose transfer failed during settlement. Each leg is independent: a
    ///         recipient the token still rejects keeps its amount pending without blocking the other.
    function flushPendingFees() external nonReentrant {
        uint256 burn = pendingBurn;
        uint256 fee = pendingTreasury;
        if (burn == 0 && fee == 0) revert NothingToFlush();
        if (burn != 0) {
            pendingBurn = 0;
            if (!_pushFee(DEAD_ADDRESS, burn)) pendingBurn = burn;
        }
        if (fee != 0) {
            pendingTreasury = 0;
            if (!_pushFee(TREASURY, fee)) pendingTreasury = fee;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Full record of a round.
    function getRound(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    /// @notice Participants of a round in entry order.
    function getParticipants(uint256 roundId) external view returns (address[] memory) {
        return _participants[roundId];
    }

    /// @notice Selection weight of a player in a round (tickets x (BPS + boost)); each drawn ticket removes one
    ///         ticket's weight (BPS + boost) once the round is settled.
    function weightOf(uint256 roundId, address player) external view returns (uint256) {
        uint256 index = participantIndex[roundId][player];
        return index == 0 ? 0 : _trees[roundId].weightOf(index);
    }

    /// @notice Total selection weight remaining in a round.
    function totalWeight(uint256 roundId) external view returns (uint256) {
        return _trees[roundId].total;
    }

    /// @notice Loyalty state of a player, including points from a finalised round not yet synced.
    /// @return points Spendable loyalty points.
    /// @return roundsPlayed Finalised rounds the player took part in.
    /// @return pendingBoostBps Multiplier bonus waiting for the player's next round.
    /// @return canRedeem Whether `redeemMultiplier` would currently succeed.
    function getPlayer(address player)
        external
        view
        returns (uint256 points, uint256 roundsPlayed, uint256 pendingBoostBps, bool canRedeem)
    {
        Player storage p = _players[player];
        points = p.points;
        roundsPlayed = p.roundsPlayed;
        pendingBoostBps = p.pendingBoostBps;
        uint256 unsynced = p.unsyncedRound;
        if (unsynced != 0 && _rounds[unsynced].status == RoundStatus.Finalized) {
            points += ticketsOf[unsynced][player];
            roundsPlayed += 1;
        }
        canRedeem = roundsPlayed >= ROUNDS_FOR_MULTIPLIER && points >= MULTIPLIER_COST_POINTS
            && pendingBoostBps < MAX_MULTIPLIER_BONUS_BPS;
    }

    /// @notice Seconds left in the current round, 0 if not started or already over.
    function timeRemaining() external view returns (uint256) {
        Round storage round = _rounds[currentRoundId];
        if (round.status != RoundStatus.Active || block.timestamp >= round.endTime) return 0;
        return round.endTime - block.timestamp;
    }

    /// @notice Token setup alone enables the game; blockhash drawing requires no configuration.
    function isConfigured() external view returns (bool) {
        return address(token) != address(0);
    }

    /// @notice Tokens this contract must hold to honour every obligation. The token balance is always >= this.
    function totalObligations() public view returns (uint256) {
        uint256 live;
        Round storage round = _rounds[currentRoundId];
        if (round.status == RoundStatus.Active || round.status == RoundStatus.Drawing) live = round.pool;
        return totalLocked + totalClaimable + totalRefundable + pendingBurn + pendingTreasury + live;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Settles a round with the committed blockhash-derived word: picks winners, splits the pool, opens the next round,
    ///      then pushes the burn and treasury transfers (deferred if they fail so a rejected fee cannot prevent settlement).
    function _settle(uint256 roundId, Round storage round, uint256 randomWord) internal {
        uint256 pool = round.pool;
        uint256 burn = (pool * BURN_BPS) / BPS;
        uint256 fee = (pool * TREASURY_BPS) / BPS;
        uint256[3] memory prizes =
            [(pool * FIRST_PRIZE_BPS) / BPS, (pool * SECOND_PRIZE_BPS) / BPS, (pool * THIRD_PRIZE_BPS) / BPS];
        uint256 locked = pool - burn - fee - prizes[0] - prizes[1] - prizes[2];

        address[3] memory winners = _selectWinners(roundId, randomWord);
        // Unfilled podium slots (fewer than three tickets in the round) roll up to first place.
        for (uint256 i = WINNER_SLOTS - 1; i > 0; --i) {
            if (winners[i] == address(0)) {
                prizes[0] += prizes[i];
                prizes[i] = 0;
            }
        }
        uint256 prizeTotal;
        for (uint256 i; i < WINNER_SLOTS; ++i) {
            if (winners[i] != address(0)) {
                claimable[winners[i]] += prizes[i];
                prizeTotal += prizes[i];
            }
        }

        round.status = RoundStatus.Finalized;
        round.randomWord = randomWord;
        round.winners = winners;
        round.prizes = prizes;
        round.burned = burn;
        round.treasuryFee = fee;
        round.locked = locked;
        totalClaimable += prizeTotal;
        totalLocked += locked;
        currentRoundId = roundId + 1;
        emit RoundFinalized(roundId, randomWord, winners, prizes, burn, fee, locked);

        if (burn != 0 && !_pushFee(DEAD_ADDRESS, burn)) pendingBurn += burn;
        if (fee != 0 && !_pushFee(TREASURY, fee)) pendingTreasury += fee;
    }

    /// @dev Draws up to three winning tickets, weight-proportional and without replacement at ticket level. The
    ///      k-th draw uses keccak256(randomWord, k) over the weight that remains after taking the earlier drawn
    ///      tickets out; the drawn player's other tickets keep their chances, so the same address can fill more
    ///      than one podium slot and splitting a stake across addresses gives no advantage.
    function _selectWinners(uint256 roundId, uint256 randomWord) internal returns (address[3] memory winners) {
        WeightedTree.Tree storage tree = _trees[roundId];
        address[] storage participants = _participants[roundId];
        for (uint256 k; k < WINNER_SLOTS; ++k) {
            uint256 remaining = tree.total;
            if (remaining == 0) break;
            uint256 position = uint256(keccak256(abi.encode(randomWord, k))) % remaining;
            uint256 index = tree.find(position);
            address winner = participants[index - 1];
            winners[k] = winner;
            tree.subtract(index, BPS + roundBoostBps[roundId][winner]);
        }
    }

    /// @dev Pushes a fee with the non-reverting transfer and reports the outcome through events.
    function _pushFee(address to, uint256 amount) internal returns (bool sent) {
        sent = _tryTransfer(to, amount);
        if (sent) {
            emit FeeTransferred(to, amount);
        } else {
            emit FeeTransferDeferred(to, amount);
        }
    }

    /// @dev Credits the player's points and round count for their last entered round once it is finalised.
    function _syncPlayer(address account) internal {
        Player storage player = _players[account];
        uint256 roundId = player.unsyncedRound;
        if (roundId == 0) return;
        RoundStatus status = _rounds[roundId].status;
        if (status == RoundStatus.Finalized) {
            uint256 earned = ticketsOf[roundId][account];
            player.points += earned;
            player.roundsPlayed += 1;
            player.unsyncedRound = 0;
            emit PointsCredited(account, roundId, earned, player.roundsPlayed);
        } else if (status == RoundStatus.Cancelled) {
            player.unsyncedRound = 0;
        }
    }

    /// @dev Transfers `amount` of the game token to `to`, returning false instead of reverting on failure.
    function _tryTransfer(address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (data.length == 0) return address(token).code.length > 0;
        return data.length >= 32 && abi.decode(data, (bool));
    }
}
