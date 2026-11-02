// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FedTypes} from "../libraries/FedTypes.sol";

/**
 * @title IRoundManager
 * @notice Replaces the trusted federated-learning server. It owns the state
 *         of every training round, verifies each client's zero-knowledge
 *         proof, records the lineage of global models, and settles rewards
 *         and penalties.
 *
 * @dev Round flow (see docs/protocol.md):
 *        1. startRound      - opens Commit, picks a staked aggregator
 *        2. submitUpdate    - client sends (commitment, Groth16 proof)
 *        3. revealUpdate    - client sends (IPFS CID, salt)
 *        4. postAggregate   - aggregator sends (model hash, model CID, accepted set) + bond
 *        5. finalizeRound   - after the challenge window, pays rewards
 *      advancePhase moves the round forward when a deadline passes, and the
 *      DisputeResolver uses markDisputed / resolveDispute during a challenge.
 */
interface IRoundManager {
    // ------------------------------------------------------------------
    // Events (consumed by the off-chain client, aggregator and challengers)
    // ------------------------------------------------------------------

    event RoundStarted(
        uint256 indexed roundId, address indexed aggregator, bytes32 prevModelHash, uint64 commitDeadline
    );
    event UpdateSubmitted(uint256 indexed roundId, address indexed client, uint256 commitment, uint16 index);
    event ProofRejected(uint256 indexed roundId, address indexed client);
    event UpdateRevealed(uint256 indexed roundId, address indexed client, string updateCID, uint256 salt);
    event AggregatePosted(
        uint256 indexed roundId, address indexed aggregator, bytes32 modelHash, string modelCID, uint256 acceptedBitmap
    );
    event PhaseAdvanced(uint256 indexed roundId, FedTypes.Phase phase);
    event RoundDisputed(uint256 indexed roundId);
    event AggregateOverturned(uint256 indexed roundId, address indexed challenger);
    event RoundFinalized(uint256 indexed roundId, bytes32 modelHash, uint256 rewardedClients);

    // ------------------------------------------------------------------
    // Round lifecycle
    // ------------------------------------------------------------------

    /**
     * @notice Opens a new round once the previous one is finalized.
     * @dev Permissionless, so no single party controls the training schedule.
     *      The new round starts from the latest accepted global model.
     * @return roundId Identifier of the new round.
     */
    function startRound() external returns (uint256 roundId);

    /**
     * @notice Commit phase: submits a commitment to a local update with a
     *         Groth16 proof that the update's squared norm is <= normBoundSq.
     * @dev The contract supplies normBoundSq, roundId and msg.sender as public
     *      signals, so a proof cannot be replayed in another round or copied
     *      by another client. A failed proof is slashed instead of reverted,
     *      so the penalty is recorded on-chain.
     * @param roundId Current round.
     * @param commitment Poseidon commitment output by the circuit.
     * @param proof Groth16 proof produced by snarkjs.
     */
    function submitUpdate(uint256 roundId, uint256 commitment, FedTypes.Proof calldata proof) external;

    /**
     * @notice Reveal phase: publishes where the committed update is stored.
     * @dev Revealing only after all commitments are fixed stops free-riders
     *      from copying another client's update.
     * @param updateCID IPFS CID of the quantized update file.
     * @param salt Salt used in the commitment, so anyone can re-check it.
     */
    function revealUpdate(uint256 roundId, string calldata updateCID, uint256 salt) external;

    /**
     * @notice Aggregate phase: the selected aggregator posts the new global model.
     * @dev msg.value must equal the configured aggregator bond. The bond is
     *      returned at finalization or paid to a successful challenger.
     * @param modelHash keccak256 of the aggregated adapter file.
     * @param modelCID IPFS CID of the aggregated adapter file.
     * @param acceptedBitmap Bit i set if submission i passed robust aggregation.
     */
    function postAggregate(uint256 roundId, bytes32 modelHash, string calldata modelCID, uint256 acceptedBitmap)
        external
        payable;

    /**
     * @notice Moves a round to its next phase after the current deadline.
     * @dev Anyone may call it. Leaving Reveal slashes clients that never
     *      revealed; leaving Aggregate without a posted model slashes the
     *      aggregator and closes the round without a model update.
     */
    function advancePhase(uint256 roundId) external;

    /**
     * @notice Closes an undisputed round after its challenge window.
     * @dev Mints rewards to accepted clients, lowers the reputation of
     *      revealed-but-filtered clients, returns the aggregator's bond and
     *      records the new global model.
     */
    function finalizeRound(uint256 roundId) external;

    // ------------------------------------------------------------------
    // Dispute hooks (DISPUTE_RESOLVER_ROLE only)
    // ------------------------------------------------------------------

    /// @notice Freezes a round in the Disputed phase when a challenge is opened.
    function markDisputed(uint256 roundId) external;

    /**
     * @notice Applies the outcome of a dispute.
     * @param aggregateUpheld True if the aggregate stands; the round is then finalized normally.
     * @param challenger Receives the aggregator's bond if the aggregate is overturned.
     */
    function resolveDispute(uint256 roundId, bool aggregateUpheld, address challenger) external;

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function currentRoundId() external view returns (uint256);

    function getRound(uint256 roundId) external view returns (FedTypes.Round memory);

    function getSubmission(uint256 roundId, address client) external view returns (FedTypes.Submission memory);

    function submittersOf(uint256 roundId) external view returns (address[] memory);

    function getConfig() external view returns (FedTypes.RoundConfig memory);

    /// @notice Latest accepted global model (hash, IPFS CID, round that produced it).
    function latestModel() external view returns (bytes32 modelHash, string memory modelCID, uint256 roundId);
}
