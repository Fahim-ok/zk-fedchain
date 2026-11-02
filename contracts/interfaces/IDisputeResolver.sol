// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FedTypes} from "../libraries/FedTypes.sol";

/**
 * @title IDisputeResolver
 * @notice Optimistic verification of aggregation. The aggregate posted by
 *         the aggregator is accepted unless a staked member challenges it
 *         within the challenge window.
 *
 * @dev Running Multi-Krum or trimmed mean inside the EVM (or inside a ZK
 *      circuit) every round is too expensive, so aggregation is checked
 *      off-chain: each voter downloads the revealed updates from IPFS,
 *      re-runs the deterministic aggregation (offchain/zkfed/challenger.py)
 *      and votes. In this draft disputes are settled by a simple majority of
 *      staked members; an interactive verification game in the style of
 *      TrueBit is future work.
 *
 *      Bonds: the challenger locks `challengeBond` ETH. If the challenger
 *      wins, the bond is refunded and the aggregator's bond is paid to the
 *      challenger; otherwise the challenger's bond goes to the aggregator.
 */
interface IDisputeResolver {
    event ChallengeOpened(
        uint256 indexed disputeId, uint256 indexed roundId, address indexed challenger, bytes32 claimedModelHash
    );
    event VoteCast(uint256 indexed disputeId, address indexed voter, bool supportChallenger);
    event DisputeResolved(uint256 indexed disputeId, uint256 indexed roundId, bool challengerWon);

    /**
     * @notice Challenges the aggregate of a round during its challenge window.
     * @dev msg.value must equal challengeBond. The challenger must be an
     *      eligible member and cannot be the round's aggregator.
     * @param claimedModelHash Model hash the challenger obtained by re-running aggregation.
     * @param evidenceCID IPFS CID of the challenger's evidence (recomputed model, logs).
     * @return disputeId Identifier of the new dispute.
     */
    function openChallenge(uint256 roundId, bytes32 claimedModelHash, string calldata evidenceCID)
        external
        payable
        returns (uint256 disputeId);

    /**
     * @notice Votes on an open dispute. One vote per eligible member; the
     *         challenger and the aggregator may not vote.
     * @param supportChallenger True if the voter's own re-execution matches the challenger.
     */
    function castVote(uint256 disputeId, bool supportChallenger) external;

    /**
     * @notice Settles a dispute after its voting deadline and reports the
     *         outcome to the RoundManager. Anyone may call it.
     * @dev The challenger wins only with a strict majority and at least
     *      `quorum` votes; otherwise the aggregate is upheld.
     */
    function resolve(uint256 disputeId) external;

    // Views
    function getDispute(uint256 disputeId) external view returns (FedTypes.Dispute memory);

    function disputeOfRound(uint256 roundId) external view returns (uint256);

    function hasVoted(uint256 disputeId, address voter) external view returns (bool);

    function challengeBond() external view returns (uint256);
}
