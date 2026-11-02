// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRoundManager} from "./interfaces/IRoundManager.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {IGroth16Verifier} from "./interfaces/IGroth16Verifier.sol";
import {IFedRewardToken} from "./interfaces/IFedRewardToken.sol";
import {FedTypes} from "./libraries/FedTypes.sol";

/**
 * @title RoundManager
 * @notice On-chain coordinator of ZK-FedChain. It takes the place of the
 *         trusted FL server: it schedules rounds, accepts only updates that
 *         carry a valid norm-bound proof, keeps a tamper-evident history of
 *         global models, and settles rewards and penalties.
 *
 * @dev What lives on-chain: round phases and deadlines, Poseidon commitments,
 *      IPFS CIDs, model hashes and the accepted set. What stays off-chain:
 *      LoRA training, proof generation, update files (IPFS) and robust
 *      aggregation (Multi-Krum / trimmed mean).
 *
 *      Draft status (CSE 540 milestone): the round state machine, proof
 *      check and settlement are written; open items are marked TODO.
 */
contract RoundManager is IRoundManager, AccessControl, ReentrancyGuard {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    bytes32 public constant DISPUTE_RESOLVER_ROLE = keccak256("DISPUTE_RESOLVER_ROLE");

    /// @dev Reason codes passed to Registry.slash (indexed in the Slashed event).
    bytes32 public constant REASON_INVALID_PROOF = "INVALID_PROOF";
    bytes32 public constant REASON_NO_REVEAL = "NO_REVEAL";
    bytes32 public constant REASON_AGGREGATOR_TIMEOUT = "AGGREGATOR_TIMEOUT";
    bytes32 public constant REASON_BAD_AGGREGATE = "BAD_AGGREGATE";

    /// @dev Reputation changes. Statistical rejection costs reputation only, never stake.
    int256 public constant REP_ACCEPTED = 1;
    int256 public constant REP_FILTERED = -1;
    int256 public constant REP_BAD_AGGREGATOR = -10;

    /// @dev The accepted set is a uint256 bitmap, so a round holds at most 256 updates.
    uint16 public constant MAX_SUBMISSIONS = 256;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    IRegistry public immutable registry;
    IGroth16Verifier public immutable verifier;
    IFedRewardToken public immutable rewardToken;

    FedTypes.RoundConfig private _config;
    uint256 private _currentRoundId;

    bytes32 private _latestModelHash;
    string private _latestModelCID;
    uint256 private _latestModelRound;

    mapping(uint256 => FedTypes.Round) private _rounds;
    mapping(uint256 => mapping(address => FedTypes.Submission)) private _submissions;
    mapping(uint256 => address[]) private _submitters;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error WrongPhase(FedTypes.Phase expected, FedTypes.Phase actual);
    error PreviousRoundOpen(uint256 roundId);
    error DeadlinePassed();
    error PhaseNotOver();
    error NotEligible(address account);
    error NotAggregator(address account);
    error AggregatorCannotSubmit();
    error AlreadySubmitted();
    error RoundFull();
    error NoSubmission();
    error AlreadyRevealed();
    error EmptyField();
    error WrongBond(uint256 expected, uint256 sent);
    error InvalidAcceptedSet();
    error NoEligibleAggregator();
    error TransferFailed();

    // ------------------------------------------------------------------
    // Constructor and admin
    // ------------------------------------------------------------------

    /**
     * @param registry_ Membership and stake contract.
     * @param verifier_ Groth16 verifier generated from circuits/norm_bound.circom.
     * @param rewardToken_ ERC-20 reward token (this contract must hold MINTER_ROLE).
     * @param config_ Round durations, norm bound, rewards, bonds and penalties.
     * @param genesisModelHash keccak256 of the initial (pre-trained) adapter.
     * @param genesisModelCID IPFS CID of the initial adapter.
     * @param admin Governance address that may update the config between rounds.
     */
    constructor(
        IRegistry registry_,
        IGroth16Verifier verifier_,
        IFedRewardToken rewardToken_,
        FedTypes.RoundConfig memory config_,
        bytes32 genesisModelHash,
        string memory genesisModelCID,
        address admin
    ) {
        registry = registry_;
        verifier = verifier_;
        rewardToken = rewardToken_;
        _config = config_;
        _latestModelHash = genesisModelHash;
        _latestModelCID = genesisModelCID;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Updates protocol parameters. Only allowed when no round is open.
    function setConfig(FedTypes.RoundConfig calldata newConfig) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireNoOpenRound();
        _config = newConfig;
    }

    // ------------------------------------------------------------------
    // Round lifecycle
    // ------------------------------------------------------------------

    /// @inheritdoc IRoundManager
    function startRound() external returns (uint256 roundId) {
        _requireNoOpenRound();

        roundId = ++_currentRoundId;
        FedTypes.Round storage r = _rounds[roundId];
        r.phase = FedTypes.Phase.Commit;

        // Deadlines are fixed up front so every client sees the same schedule.
        uint64 t = uint64(block.timestamp);
        r.commitDeadline = t + _config.commitDuration;
        r.revealDeadline = r.commitDeadline + _config.revealDuration;
        r.aggregateDeadline = r.revealDeadline + _config.aggregateDuration;
        r.challengeDeadline = r.aggregateDeadline + _config.challengeDuration; // upper bound, tightened in postAggregate

        r.prevModelHash = _latestModelHash;
        r.aggregator = _selectAggregator(roundId);

        emit RoundStarted(roundId, r.aggregator, r.prevModelHash, r.commitDeadline);
    }

    /// @inheritdoc IRoundManager
    function submitUpdate(uint256 roundId, uint256 commitment, FedTypes.Proof calldata proof)
        external
        nonReentrant
    {
        FedTypes.Round storage r = _requirePhase(roundId, FedTypes.Phase.Commit);
        if (block.timestamp > r.commitDeadline) revert DeadlinePassed();
        if (!registry.isEligible(msg.sender)) revert NotEligible(msg.sender);
        if (msg.sender == r.aggregator) revert AggregatorCannotSubmit();
        if (_submissions[roundId][msg.sender].exists) revert AlreadySubmitted();
        if (r.numSubmissions >= MAX_SUBMISSIONS) revert RoundFull();

        // Public signals are taken from contract state, not from the caller:
        // this binds the proof to this round, this bound and this sender.
        uint256[4] memory pubSignals =
            [commitment, _config.normBoundSq, roundId, uint256(uint160(msg.sender))];

        if (!verifier.verifyProof(proof.a, proof.b, proof.c, pubSignals)) {
            // Cryptographic evidence of a bad update: slash instead of
            // reverting so the penalty is actually applied.
            registry.slash(msg.sender, _config.invalidProofPenalty, REASON_INVALID_PROOF, address(0));
            emit ProofRejected(roundId, msg.sender);
            return;
        }

        uint16 index = r.numSubmissions;
        r.numSubmissions = index + 1;
        _submissions[roundId][msg.sender] = FedTypes.Submission({
            commitment: commitment,
            salt: 0,
            updateCID: "",
            index: index,
            revealed: false,
            exists: true
        });
        _submitters[roundId].push(msg.sender);

        // Keep the client's stake in place until the round can no longer be disputed.
        // TODO: extend the lock while a dispute on this round is open.
        registry.lockStake(msg.sender, r.challengeDeadline);

        emit UpdateSubmitted(roundId, msg.sender, commitment, index);
    }

    /// @inheritdoc IRoundManager
    function revealUpdate(uint256 roundId, string calldata updateCID, uint256 salt) external {
        FedTypes.Round storage r = _requirePhase(roundId, FedTypes.Phase.Reveal);
        if (block.timestamp > r.revealDeadline) revert DeadlinePassed();

        FedTypes.Submission storage s = _submissions[roundId][msg.sender];
        if (!s.exists) revert NoSubmission();
        if (s.revealed) revert AlreadyRevealed();
        if (bytes(updateCID).length == 0) revert EmptyField();

        // The contract cannot hash the IPFS file itself; the aggregator and
        // any challenger recompute Poseidon(update, salt, roundId, client)
        // off-chain and compare it with the stored commitment.
        s.updateCID = updateCID;
        s.salt = salt;
        s.revealed = true;

        emit UpdateRevealed(roundId, msg.sender, updateCID, salt);
    }

    /// @inheritdoc IRoundManager
    function postAggregate(uint256 roundId, bytes32 modelHash, string calldata modelCID, uint256 acceptedBitmap)
        external
        payable
        nonReentrant
    {
        FedTypes.Round storage r = _requirePhase(roundId, FedTypes.Phase.Aggregate);
        if (msg.sender != r.aggregator) revert NotAggregator(msg.sender);
        if (block.timestamp > r.aggregateDeadline) revert DeadlinePassed();
        if (msg.value != _config.aggregatorBond) revert WrongBond(_config.aggregatorBond, msg.value);
        if (modelHash == bytes32(0) || bytes(modelCID).length == 0) revert EmptyField();
        _checkAcceptedSet(roundId, r.numSubmissions, acceptedBitmap);

        r.modelHash = modelHash;
        r.modelCID = modelCID;
        r.acceptedBitmap = acceptedBitmap;
        r.aggregatorBond = msg.value;

        // Open the challenge window as soon as the aggregate is posted.
        r.phase = FedTypes.Phase.Challenge;
        r.challengeDeadline = uint64(block.timestamp) + _config.challengeDuration;

        emit AggregatePosted(roundId, msg.sender, modelHash, modelCID, acceptedBitmap);
        emit PhaseAdvanced(roundId, FedTypes.Phase.Challenge);
    }

    /// @inheritdoc IRoundManager
    function advancePhase(uint256 roundId) external nonReentrant {
        FedTypes.Round storage r = _rounds[roundId];

        if (r.phase == FedTypes.Phase.Commit) {
            if (block.timestamp <= r.commitDeadline) revert PhaseNotOver();
            // No valid submissions: close the round without changing the model.
            r.phase = r.numSubmissions == 0 ? FedTypes.Phase.Finalized : FedTypes.Phase.Reveal;
        } else if (r.phase == FedTypes.Phase.Reveal) {
            if (block.timestamp <= r.revealDeadline) revert PhaseNotOver();
            _penalizeNonRevealers(roundId);
            r.phase = FedTypes.Phase.Aggregate;
        } else if (r.phase == FedTypes.Phase.Aggregate) {
            // Reaching here means the aggregator never posted a model.
            if (block.timestamp <= r.aggregateDeadline) revert PhaseNotOver();
            registry.slash(r.aggregator, _config.aggregatorTimeoutPenalty, REASON_AGGREGATOR_TIMEOUT, address(0));
            // TODO: re-select a backup aggregator instead of closing the round.
            r.phase = FedTypes.Phase.Finalized;
        } else {
            revert WrongPhase(FedTypes.Phase.Commit, r.phase);
        }

        emit PhaseAdvanced(roundId, r.phase);
    }

    /// @inheritdoc IRoundManager
    function finalizeRound(uint256 roundId) external nonReentrant {
        FedTypes.Round storage r = _requirePhase(roundId, FedTypes.Phase.Challenge);
        if (block.timestamp <= r.challengeDeadline) revert PhaseNotOver();
        _settleAcceptedAggregate(roundId, r);
    }

    // ------------------------------------------------------------------
    // Dispute hooks
    // ------------------------------------------------------------------

    /// @inheritdoc IRoundManager
    function markDisputed(uint256 roundId) external onlyRole(DISPUTE_RESOLVER_ROLE) {
        FedTypes.Round storage r = _requirePhase(roundId, FedTypes.Phase.Challenge);
        if (block.timestamp > r.challengeDeadline) revert DeadlinePassed();
        r.phase = FedTypes.Phase.Disputed;
        emit RoundDisputed(roundId);
    }

    /// @inheritdoc IRoundManager
    function resolveDispute(uint256 roundId, bool aggregateUpheld, address challenger)
        external
        onlyRole(DISPUTE_RESOLVER_ROLE)
        nonReentrant
    {
        FedTypes.Round storage r = _requirePhase(roundId, FedTypes.Phase.Disputed);

        if (aggregateUpheld) {
            _settleAcceptedAggregate(roundId, r);
            return;
        }

        // Aggregate overturned: the model is rejected, the aggregator loses
        // its bond (paid to the challenger) and part of its stake.
        uint256 bond = r.aggregatorBond;
        r.aggregatorBond = 0;
        r.phase = FedTypes.Phase.Finalized;

        registry.slash(r.aggregator, _config.badAggregatePenalty, REASON_BAD_AGGREGATE, challenger);
        registry.adjustReputation(r.aggregator, REP_BAD_AGGREGATOR);
        _send(challenger, bond);

        // TODO: honest clients of this round are not rewarded yet; a follow-up
        // round should re-aggregate their revealed updates.
        emit AggregateOverturned(roundId, challenger);
        emit PhaseAdvanced(roundId, FedTypes.Phase.Finalized);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IRoundManager
    function currentRoundId() external view returns (uint256) {
        return _currentRoundId;
    }

    /// @inheritdoc IRoundManager
    function getRound(uint256 roundId) external view returns (FedTypes.Round memory) {
        return _rounds[roundId];
    }

    /// @inheritdoc IRoundManager
    function getSubmission(uint256 roundId, address client) external view returns (FedTypes.Submission memory) {
        return _submissions[roundId][client];
    }

    /// @inheritdoc IRoundManager
    function submittersOf(uint256 roundId) external view returns (address[] memory) {
        return _submitters[roundId];
    }

    /// @inheritdoc IRoundManager
    function getConfig() external view returns (FedTypes.RoundConfig memory) {
        return _config;
    }

    /// @inheritdoc IRoundManager
    function latestModel() external view returns (bytes32 modelHash, string memory modelCID, uint256 roundId) {
        return (_latestModelHash, _latestModelCID, _latestModelRound);
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// @dev Pays rewards, updates reputation, refunds the aggregator and records the new model.
    function _settleAcceptedAggregate(uint256 roundId, FedTypes.Round storage r) private {
        r.phase = FedTypes.Phase.Finalized;

        uint256 rewarded;
        address[] storage clients = _submitters[roundId];
        for (uint256 i = 0; i < clients.length; i++) {
            FedTypes.Submission storage s = _submissions[roundId][clients[i]];
            if (_isAccepted(r.acceptedBitmap, s.index)) {
                rewardToken.mint(clients[i], _config.rewardPerUpdate);
                registry.adjustReputation(clients[i], REP_ACCEPTED);
                rewarded++;
            } else if (s.revealed) {
                // Filtered by robust aggregation: statistical evidence only.
                registry.adjustReputation(clients[i], REP_FILTERED);
            }
        }

        rewardToken.mint(r.aggregator, _config.aggregatorReward);
        uint256 bond = r.aggregatorBond;
        r.aggregatorBond = 0;
        _send(r.aggregator, bond);

        _latestModelHash = r.modelHash;
        _latestModelCID = r.modelCID;
        _latestModelRound = roundId;

        emit RoundFinalized(roundId, r.modelHash, rewarded);
        emit PhaseAdvanced(roundId, FedTypes.Phase.Finalized);
    }

    /// @dev Slashes every client that committed in this round but did not reveal.
    function _penalizeNonRevealers(uint256 roundId) private {
        address[] storage clients = _submitters[roundId];
        for (uint256 i = 0; i < clients.length; i++) {
            if (!_submissions[roundId][clients[i]].revealed) {
                registry.slash(clients[i], _config.noRevealPenalty, REASON_NO_REVEAL, address(0));
            }
        }
    }

    /// @dev The accepted set may only contain submissions that exist and were revealed.
    function _checkAcceptedSet(uint256 roundId, uint16 numSubmissions, uint256 bitmap) private view {
        if (numSubmissions < 256 && (bitmap >> numSubmissions) != 0) revert InvalidAcceptedSet();
        address[] storage clients = _submitters[roundId];
        for (uint256 i = 0; i < clients.length; i++) {
            FedTypes.Submission storage s = _submissions[roundId][clients[i]];
            if (_isAccepted(bitmap, s.index) && !s.revealed) revert InvalidAcceptedSet();
        }
    }

    /**
     * @dev Picks a staked member as aggregator, starting from a pseudo-random
     *      position. block.prevrandao can be biased by block proposers, which
     *      is acceptable for the course prototype.
     *      TODO: use a VRF or a commit-reveal beacon in a production version.
     */
    function _selectAggregator(uint256 roundId) private view returns (address) {
        uint256 n = registry.memberCount();
        if (n == 0) revert NoEligibleAggregator();
        uint256 start = uint256(keccak256(abi.encode(block.prevrandao, roundId))) % n;
        for (uint256 i = 0; i < n; i++) {
            address candidate = registry.memberAt((start + i) % n);
            if (registry.isEligible(candidate)) return candidate;
        }
        revert NoEligibleAggregator();
    }

    function _requirePhase(uint256 roundId, FedTypes.Phase expected)
        private
        view
        returns (FedTypes.Round storage r)
    {
        r = _rounds[roundId];
        if (r.phase != expected) revert WrongPhase(expected, r.phase);
    }

    function _requireNoOpenRound() private view {
        uint256 id = _currentRoundId;
        if (id != 0 && _rounds[id].phase != FedTypes.Phase.Finalized) revert PreviousRoundOpen(id);
    }

    function _isAccepted(uint256 bitmap, uint16 index) private pure returns (bool) {
        return (bitmap >> index) & 1 == 1;
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
