// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVRFCoordinatorV2Plus, IVRFConsumerV2Plus, VRFV2PlusClient} from "./interfaces/IVRFCoordinatorV2Plus.sol";
import {WeightedTree} from "./libraries/WeightedTree.sol";

/// @title IMDPot
/// @author IMDPot contributors
/// @notice A 15-minute jackpot game played exclusively with the $IMD token.
///
/// Rules
/// -----
/// * Tickets cost exactly 0.1 IMD each and are bought in whole numbers (`buyTickets`).
/// * A round's 15-minute timer starts with the first ticket of that round. A round nobody enters never starts.
/// * After the timer ends, anyone may call `finalizeRound()`. That requests Chainlink VRF randomness.
///   When the coordinator delivers the random word, the contract atomically:
///     1. draws three winning tickets without replacement, every ticket carrying an equal chance (a redeemed
///        loyalty multiplier only adds extra chances to a player's own tickets). A player holding several
///        tickets can take more than one podium place; splitting a stake over many addresses changes nothing;
///     2. makes 70% of the pool claimable by the winners (40% / 20% / 10%);
///     3. sends 10% of the pool to the dead address (burn);
///     4. sends 5% of the pool to the treasury wallet;
///     5. locks the remaining 15% in this contract forever (there is no function that can move it);
///     6. credits non-transferable loyalty points to every participant, one point per ticket, pro rata.
/// * Prizes are pull-based (`claim`) so a reverting recipient can never block a round.
/// * If randomness does not arrive, anyone may add a request after `VRF_RETRY_DELAY` (up to
///   `MAX_RANDOMNESS_REQUESTS` per round). Every request of the round stays valid: the first word delivered
///   for any of them settles the round, so a pending fulfillment can never be voided by a re-roll.
/// * Only once `CANCEL_DELAY` has passed since both the round end and the latest randomness request may anyone
///   cancel the round so every player can `refund`. While the round is still `Active` (nobody finalised it),
///   `cancelRound` first tries to request randomness and only cancels if the request is impossible.
///
/// Trust assumptions
/// -----------------
/// The owner can: set the IMD token once, configure Chainlink VRF while the current round has no tickets
/// (and raise the callback gas limit or confirmations at any time), pause new entries and finalisation, and
/// rescue foreign tokens (never IMD). The owner can never withdraw IMD, change fees, move the locked 15% or
/// renounce ownership. Because the owner chooses the VRF coordinator address, players must verify it is the
/// Chainlink coordinator published for this chain: an owner-controlled coordinator could pick the random word
/// for rounds entered after such a change (`VrfConfigSet` is emitted and the change is only possible with no
/// tickets in the round). Pausing blocks finalisation; a paused round can be cancelled for refunds after
/// `CANCEL_DELAY`, so a pause can forgo one round's fees but can never trap funds.
contract IMDPot is Ownable2Step, Pausable, ReentrancyGuard, IVRFConsumerV2Plus {
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
        uint64 randomnessRequestedAt;
        /// @dev Randomness requests issued for this round (initial request plus retries).
        uint32 requestCount;
        uint256 pool;
        uint256 totalTickets;
        uint256 participantCount;
        uint256 vrfRequestId;
        uint256 randomWord;
        address[3] winners;
        uint256[3] prizes;
        uint256 burned;
        uint256 treasuryFee;
        uint256 locked;
    }

    /// @notice Chainlink VRF v2.5 request parameters.
    struct VrfConfig {
        address coordinator;
        uint256 subscriptionId;
        bytes32 keyHash;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        bool nativePayment;
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
    /// @notice Delay after the latest VRF request before anyone may add another request for the round.
    uint256 public constant VRF_RETRY_DELAY = 1 hours;
    /// @notice Maximum randomness requests per round (the initial request plus retries). Bounds the owner's VRF
    ///         spend and guarantees that `cancelRound` eventually becomes possible if fulfillment never comes.
    uint32 public constant MAX_RANDOMNESS_REQUESTS = 4;
    /// @notice Delay that must have passed since both the round's scheduled end and its latest randomness request
    ///         before anyone may cancel it for refunds.
    uint256 public constant CANCEL_DELAY = 24 hours;
    /// @notice Rounds a player must have completed before redeeming points for a multiplier.
    uint256 public constant ROUNDS_FOR_MULTIPLIER = 10;
    /// @notice Points burned per multiplier redemption.
    uint256 public constant MULTIPLIER_COST_POINTS = 100;
    /// @notice Bonus chance (in bps of ticket weight) granted per redemption. 2_500 = +25%.
    uint256 public constant MULTIPLIER_STEP_BPS = 2_500;
    /// @notice Maximum accumulated bonus. 10_000 = +100% (each ticket counts twice).
    uint256 public constant MAX_MULTIPLIER_BONUS_BPS = 10_000;
    /// @notice Lower bound accepted for the VRF callback gas limit. Settlement with 2048 one-ticket participants
    ///         measures about 615k gas and grows by roughly 20k per doubling of participants, so 750k covers any
    ///         round Ethereum mainnet can physically fill in 15 minutes; the owner can raise the limit at any time.
    uint32 public constant MIN_CALLBACK_GAS_LIMIT = 750_000;
    /// @notice Upper bound accepted for the VRF callback gas limit (Chainlink's mainnet ceiling).
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;
    /// @notice Upper bound accepted for VRF request confirmations.
    uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;
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
    /// @notice Current VRF configuration.
    VrfConfig public vrfConfig;

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
    /// @notice Round a VRF request id belongs to, 0 for unknown ids. Every request of a round stays valid until
    ///         the round is settled or cancelled.
    mapping(uint256 requestId => uint256 roundId) public requestRound;

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
    event VrfConfigSet(
        address indexed coordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    );
    event VrfRequestParamsSet(uint32 callbackGasLimit, uint16 requestConfirmations);
    event RoundStarted(uint256 indexed roundId, uint64 startTime, uint64 endTime);
    event TicketsPurchased(
        uint256 indexed roundId, address indexed player, uint256 tickets, uint256 amount, uint256 boostBps
    );
    event RandomnessRequested(uint256 indexed roundId, uint256 indexed requestId, address indexed caller);
    event StaleRandomnessIgnored(uint256 indexed requestId);
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
    error VrfNotConfigured();
    error InvalidVrfConfig();
    error RoundNotIdle();
    error InvalidTicketCount();
    error RoundClosed();
    error RoundDrawing();
    error RoundNotActive();
    error RoundNotEnded();
    error RoundNotDrawing();
    error RetryTooEarly();
    error RetryLimitReached();
    error DuplicateRequestId(uint256 requestId);
    error CancelTooEarly();
    error OwnershipCannotBeRenounced();
    error RoundNotCancelled();
    error NothingToClaim();
    error NothingToRefund();
    error NothingToFlush();
    error TransferAmountMismatch();
    error OnlyCoordinatorCanFulfill(address have, address want);
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

    /// @notice Sets the Chainlink VRF v2.5 parameters. Only allowed while the current round has no tickets,
    ///         so nobody can enter a round under one randomness source and be drawn under another.
    /// @param coordinator The Chainlink VRF v2.5 coordinator published for this chain. Players should verify it
    ///        against Chainlink's documentation: the owner is trusted not to point this at another contract.
    /// @param subscriptionId The owner's funded VRF subscription with this contract added as consumer.
    /// @param keyHash The gas-lane key hash published for the coordinator.
    /// @param callbackGasLimit Gas forwarded to the fulfillment. Settlement grows logarithmically with the number
    ///        of participants: about 560k gas at 200 one-ticket players and about 615k at 2048; 1_000_000 is
    ///        recommended. Can be raised later at any time with `setVrfRequestParams`.
    /// @param requestConfirmations Block confirmations the coordinator waits before fulfilling.
    /// @param nativePayment True to pay the request in native ETH, false to pay in LINK.
    function setVrfConfig(
        address coordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    ) external onlyOwner {
        if (_rounds[currentRoundId].status != RoundStatus.Open) revert RoundNotIdle();
        if (coordinator == address(0)) revert ZeroAddress();
        if (coordinator.code.length == 0) revert NotAContract(coordinator);
        if (subscriptionId == 0 || keyHash == bytes32(0)) revert InvalidVrfConfig();
        _validateRequestParams(callbackGasLimit, requestConfirmations);
        vrfConfig = VrfConfig({
            coordinator: coordinator,
            subscriptionId: subscriptionId,
            keyHash: keyHash,
            callbackGasLimit: callbackGasLimit,
            requestConfirmations: requestConfirmations,
            nativePayment: nativePayment
        });
        emit VrfConfigSet(coordinator, subscriptionId, keyHash, callbackGasLimit, requestConfirmations, nativePayment);
    }

    /// @notice Updates the callback gas limit and confirmation count used by the next randomness request. Allowed
    ///         at any time, including while a round is `Active` or `Drawing`, so a round whose fulfillment ran
    ///         out of gas or whose confirmations the coordinator rejects can be rescued by the next
    ///         `retryRandomness`. Neither value can influence which word the coordinator delivers; the
    ///         coordinator, subscription and key hash stay locked until the round has no tickets.
    /// @param callbackGasLimit New gas forwarded to the fulfillment, MIN_..MAX_CALLBACK_GAS_LIMIT.
    /// @param requestConfirmations New confirmations, 1..MAX_REQUEST_CONFIRMATIONS.
    function setVrfRequestParams(uint32 callbackGasLimit, uint16 requestConfirmations) external onlyOwner {
        if (vrfConfig.coordinator == address(0)) revert VrfNotConfigured();
        _validateRequestParams(callbackGasLimit, requestConfirmations);
        vrfConfig.callbackGasLimit = callbackGasLimit;
        vrfConfig.requestConfirmations = requestConfirmations;
        emit VrfRequestParamsSet(callbackGasLimit, requestConfirmations);
    }

    /// @notice Disabled. The owner is the only account that can unpause the game or follow a coordinator
    ///         migration, so ownership can be transferred (two-step) but never renounced.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Stops new ticket purchases and randomness requests. Claims, refunds and cancellations keep working.
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
        if (vrfConfig.coordinator == address(0)) revert VrfNotConfigured();
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

    /// @notice Ends the current round once its 15 minutes are over by requesting Chainlink VRF randomness.
    ///         Settlement (winners, burn, treasury, lock, points) happens atomically when the coordinator
    ///         delivers the random word to `rawFulfillRandomWords`.
    function finalizeRound() external nonReentrant whenNotPaused {
        uint256 roundId = currentRoundId;
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.Active) revert RoundNotActive();
        if (block.timestamp < round.endTime) revert RoundNotEnded();
        round.status = RoundStatus.Drawing;
        _requestRandomness(roundId, round);
    }

    /// @notice Adds a randomness request for a round whose fulfillment has not arrived for `VRF_RETRY_DELAY`.
    ///         Earlier requests stay valid: whichever request is fulfilled first settles the round, so nobody can
    ///         void a word that is already in flight. At most `MAX_RANDOMNESS_REQUESTS` requests per round.
    function retryRandomness() external nonReentrant whenNotPaused {
        uint256 roundId = currentRoundId;
        Round storage round = _rounds[roundId];
        if (round.status != RoundStatus.Drawing) revert RoundNotDrawing();
        if (block.timestamp < uint256(round.randomnessRequestedAt) + VRF_RETRY_DELAY) revert RetryTooEarly();
        if (round.requestCount >= MAX_RANDOMNESS_REQUESTS) revert RetryLimitReached();
        _requestRandomness(roundId, round);
    }

    /// @notice Cancels a round that could not be settled, making every participant's tickets refundable and
    ///         opening the next round. Works while paused. Requires `CANCEL_DELAY` since the round's scheduled end
    ///         and, for a round in `Drawing`, also since its latest randomness request, so a request whose word
    ///         might already be known can never be aborted. For a round still `Active` (never finalised) and not
    ///         paused, a randomness request is attempted first: if the coordinator accepts it the round moves to
    ///         `Drawing` instead of being cancelled, so skipping `finalizeRound` cannot be used to dodge the draw.
    function cancelRound() external nonReentrant {
        uint256 roundId = currentRoundId;
        Round storage round = _rounds[roundId];
        RoundStatus status = round.status;
        if (status != RoundStatus.Active && status != RoundStatus.Drawing) revert RoundNotActive();
        if (block.timestamp < uint256(round.endTime) + CANCEL_DELAY) revert CancelTooEarly();
        if (status == RoundStatus.Drawing) {
            if (block.timestamp < uint256(round.randomnessRequestedAt) + CANCEL_DELAY) revert CancelTooEarly();
        } else if (!paused()) {
            round.status = RoundStatus.Drawing;
            if (_tryRequestRandomness(roundId, round)) return;
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
    // Chainlink VRF callback
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVRFConsumerV2Plus
    /// @dev Only the configured coordinator may call. Any request issued for the round that is still `Drawing`
    ///      settles it; a fulfillment for an unknown request, or for a round already settled or cancelled, is
    ///      ignored without reverting.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external nonReentrant {
        address coordinator = vrfConfig.coordinator;
        if (msg.sender != coordinator) revert OnlyCoordinatorCanFulfill(msg.sender, coordinator);
        uint256 roundId = requestRound[requestId];
        Round storage round = _rounds[roundId];
        if (roundId == 0 || round.status != RoundStatus.Drawing || randomWords.length == 0) {
            emit StaleRandomnessIgnored(requestId);
            return;
        }
        _settle(roundId, round, randomWords[0]);
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

    /// @notice Whether the VRF configuration has been set.
    function isConfigured() external view returns (bool) {
        return address(token) != address(0) && vrfConfig.coordinator != address(0);
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

    /// @dev Bounds check shared by `setVrfConfig` and `setVrfRequestParams`.
    function _validateRequestParams(uint32 callbackGasLimit, uint16 requestConfirmations) internal pure {
        if (
            callbackGasLimit < MIN_CALLBACK_GAS_LIMIT || callbackGasLimit > MAX_CALLBACK_GAS_LIMIT
                || requestConfirmations == 0 || requestConfirmations > MAX_REQUEST_CONFIRMATIONS
        ) revert InvalidVrfConfig();
    }

    /// @dev Builds the VRF v2.5 request for one random word from the current configuration.
    function _buildRequest(VrfConfig memory cfg) internal pure returns (VRFV2PlusClient.RandomWordsRequest memory) {
        return VRFV2PlusClient.RandomWordsRequest({
            keyHash: cfg.keyHash,
            subId: cfg.subscriptionId,
            requestConfirmations: cfg.requestConfirmations,
            callbackGasLimit: cfg.callbackGasLimit,
            numWords: 1,
            extraArgs: VRFV2PlusClient.argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: cfg.nativePayment}))
        });
    }

    /// @dev Requests one random word and records the request on the round; reverts if the coordinator does.
    function _requestRandomness(uint256 roundId, Round storage round) internal {
        VrfConfig memory cfg = vrfConfig;
        if (cfg.coordinator == address(0)) revert VrfNotConfigured();
        uint256 requestId = IVRFCoordinatorV2Plus(cfg.coordinator).requestRandomWords(_buildRequest(cfg));
        _recordRequest(roundId, round, requestId);
    }

    /// @dev Like `_requestRandomness` but returns false instead of reverting when the coordinator rejects the
    ///      request (used by `cancelRound` to prove settlement is impossible before refunding).
    function _tryRequestRandomness(uint256 roundId, Round storage round) internal returns (bool) {
        VrfConfig memory cfg = vrfConfig;
        if (cfg.coordinator == address(0)) return false;
        try IVRFCoordinatorV2Plus(cfg.coordinator).requestRandomWords(_buildRequest(cfg)) returns (uint256 requestId) {
            _recordRequest(roundId, round, requestId);
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Binds a request id to the round. Every request of a round stays valid until the round is settled.
    function _recordRequest(uint256 roundId, Round storage round, uint256 requestId) internal {
        if (requestRound[requestId] != 0) revert DuplicateRequestId(requestId);
        requestRound[requestId] = roundId;
        round.vrfRequestId = requestId;
        round.randomnessRequestedAt = uint64(block.timestamp);
        round.requestCount += 1;
        emit RandomnessRequested(roundId, requestId, msg.sender);
    }

    /// @dev Settles a round with the delivered random word: picks winners, splits the pool, opens the next round,
    ///      then pushes the burn and treasury transfers (deferred if they fail so the callback never reverts).
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
