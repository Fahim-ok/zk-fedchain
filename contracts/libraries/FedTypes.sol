// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FedTypes
 * @notice Shared enums and structs used across the ZK-FedChain contracts.
 * @dev Kept in one library so that the interfaces, the contracts and the
 *      off-chain clients (through the generated ABI) agree on one layout.
 */
library FedTypes {
    /**
     * @notice Lifecycle of one federated training round.
     *
     *   None -> Commit -> Reveal -> Aggregate -> Challenge -> Finalized
     *                                               |
     *                                               +-> Disputed -> Finalized
     *
     * Commit    : clients send a Poseidon commitment of their update plus a
     *             Groth16 proof that the update norm is within the agreed bound.
     * Reveal    : clients publish the IPFS CID and salt of the committed update.
     * Aggregate : the selected aggregator posts the hash/CID of the new model.
     * Challenge : any staked member may dispute the posted aggregate.
     * Disputed  : a challenge is open and the DisputeResolver is collecting votes.
     * Finalized : rewards and penalties are settled; the round is closed.
     */
    enum Phase {
        None,
        Commit,
        Reveal,
        Aggregate,
        Challenge,
        Disputed,
        Finalized
    }

    /// @notice Groth16 proof in the (a, b, c) layout exported by snarkjs.
    struct Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    /**
     * @notice Protocol parameters fixed for the duration of a round.
     * @dev Durations are in seconds. ETH amounts are in wei; reward amounts
     *      are in FedRewardToken base units.
     */
    struct RoundConfig {
        uint64 commitDuration;
        uint64 revealDuration;
        uint64 aggregateDuration;
        uint64 challengeDuration;
        uint256 normBoundSq; // B^2, public input of the norm-bound circuit
        uint256 rewardPerUpdate; // tokens minted per accepted client update
        uint256 aggregatorReward; // tokens minted to an honest aggregator
        uint256 aggregatorBond; // ETH the aggregator must lock when posting
        uint256 invalidProofPenalty; // stake slashed for a failed proof
        uint256 noRevealPenalty; // stake slashed for committing but not revealing
        uint256 aggregatorTimeoutPenalty; // stake slashed if no aggregate is posted
        uint256 badAggregatePenalty; // stake slashed if a dispute overturns the aggregate
    }

    /// @notice On-chain state of one round. Model weights are never stored here.
    struct Round {
        Phase phase;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint64 aggregateDeadline;
        uint64 challengeDeadline;
        address aggregator; // member selected to aggregate this round
        uint256 aggregatorBond; // ETH locked by the aggregator in postAggregate
        bytes32 prevModelHash; // global model this round starts from
        bytes32 modelHash; // keccak256 of the new global adapter file
        string modelCID; // IPFS CID of the new global adapter file
        uint256 acceptedBitmap; // bit i set => submission with index i was aggregated
        uint16 numSubmissions;
    }

    /// @notice One client's contribution to a round.
    struct Submission {
        uint256 commitment; // Poseidon commitment (BN254 field element)
        uint256 salt; // revealed salt, lets anyone re-check the commitment
        string updateCID; // IPFS CID of the quantized LoRA update
        uint16 index; // bit position in Round.acceptedBitmap
        bool revealed;
        bool exists;
    }

    /// @notice A challenge against the aggregate posted in one round.
    struct Dispute {
        uint256 roundId;
        address challenger;
        address aggregator;
        uint256 bond; // ETH locked by the challenger
        bytes32 claimedModelHash; // model hash the challenger obtained by re-running aggregation
        string evidenceCID; // IPFS CID of the challenger's evidence
        uint64 voteDeadline;
        uint32 votesForChallenger;
        uint32 votesForAggregator;
        bool resolved;
        bool challengerWon;
    }
}
