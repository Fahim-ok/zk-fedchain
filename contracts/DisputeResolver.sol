// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDisputeResolver} from "./interfaces/IDisputeResolver.sol";
import {IRoundManager} from "./interfaces/IRoundManager.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {FedTypes} from "./libraries/FedTypes.sol";

/**
 * @title DisputeResolver
 * @notice Lets any staked member challenge the aggregate posted in a round
 *         and settles the challenge by a vote of the other staked members.
 *
 * @dev Flow:
 *        1. openChallenge - challenger locks a bond during the challenge window;
 *                           the round is frozen in the Disputed phase.
 *        2. castVote      - each eligible member re-runs the deterministic
 *                           aggregation off-chain and votes.
 *        3. resolve       - after the voting deadline, the result is sent to
 *                           RoundManager.resolveDispute and bonds are settled.
 *
 *      This contract needs DISPUTE_RESOLVER_ROLE on the RoundManager and
 *      PROTOCOL_ROLE on the Registry (granted by scripts/deploy.js).
 */
contract DisputeResolver is IDisputeResolver, AccessControl, ReentrancyGuard {
    IRegistry public immutable registry;
    IRoundManager public immutable roundManager;

    /// @notice ETH a challenger must lock to open a dispute.
    uint256 public challengeBond;
    /// @notice Length of the voting period in seconds.
    uint64 public votingDuration;
    /// @notice Minimum number of votes for a challenger to win.
    uint32 public quorum;

    uint256 private _nextDisputeId;
    mapping(uint256 => FedTypes.Dispute) private _disputes;
    mapping(uint256 => mapping(address => bool)) private _voted;

    /// @notice Latest dispute opened against a round (0 if none).
    mapping(uint256 => uint256) public disputeOfRound;

    error NotEligible(address account);
    error WrongBond(uint256 expected, uint256 sent);
    error AggregatorCannotChallenge();
    error SameModelHash();
    error UnknownDispute(uint256 disputeId);
    error VotingClosed();
    error VotingOpen();
    error AlreadyVoted();
    error PartyCannotVote();
    error AlreadyResolved();
    error TransferFailed();

    /**
     * @param registry_ Membership and stake contract.
     * @param roundManager_ Round coordinator whose aggregates are challenged.
     * @param challengeBond_ ETH bond required to open a challenge.
     * @param votingDuration_ Voting period in seconds.
     * @param quorum_ Minimum votes needed to overturn an aggregate.
     * @param admin Governance address that may change the parameters.
     */
    constructor(
        IRegistry registry_,
        IRoundManager roundManager_,
        uint256 challengeBond_,
        uint64 votingDuration_,
        uint32 quorum_,
        address admin
    ) {
        registry = registry_;
        roundManager = roundManager_;
        challengeBond = challengeBond_;
        votingDuration = votingDuration_;
        quorum = quorum_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Updates dispute parameters (affects disputes opened afterwards).
    function setParams(uint256 challengeBond_, uint64 votingDuration_, uint32 quorum_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        challengeBond = challengeBond_;
        votingDuration = votingDuration_;
        quorum = quorum_;
    }

    /// @inheritdoc IDisputeResolver
    function openChallenge(uint256 roundId, bytes32 claimedModelHash, string calldata evidenceCID)
        external
        payable
        nonReentrant
        returns (uint256 disputeId)
    {
        if (!registry.isEligible(msg.sender)) revert NotEligible(msg.sender);
        if (msg.value != challengeBond) revert WrongBond(challengeBond, msg.value);

        FedTypes.Round memory r = roundManager.getRound(roundId);
        if (msg.sender == r.aggregator) revert AggregatorCannotChallenge();
        if (claimedModelHash == r.modelHash) revert SameModelHash();

        // Reverts unless the round is in its challenge window.
        roundManager.markDisputed(roundId);

        disputeId = ++_nextDisputeId;
        _disputes[disputeId] = FedTypes.Dispute({
            roundId: roundId,
            challenger: msg.sender,
            aggregator: r.aggregator,
            bond: msg.value,
            claimedModelHash: claimedModelHash,
            evidenceCID: evidenceCID,
            voteDeadline: uint64(block.timestamp) + votingDuration,
            votesForChallenger: 0,
            votesForAggregator: 0,
            resolved: false,
            challengerWon: false
        });
        disputeOfRound[roundId] = disputeId;

        emit ChallengeOpened(disputeId, roundId, msg.sender, claimedModelHash);
    }

    /// @inheritdoc IDisputeResolver
    /// @dev One member, one vote. TODO: consider stake- or reputation-weighted votes.
    function castVote(uint256 disputeId, bool supportChallenger) external {
        FedTypes.Dispute storage d = _getDispute(disputeId);
        if (d.resolved || block.timestamp > d.voteDeadline) revert VotingClosed();
        if (msg.sender == d.challenger || msg.sender == d.aggregator) revert PartyCannotVote();
        if (!registry.isEligible(msg.sender)) revert NotEligible(msg.sender);
        if (_voted[disputeId][msg.sender]) revert AlreadyVoted();

        _voted[disputeId][msg.sender] = true;
        if (supportChallenger) d.votesForChallenger++;
        else d.votesForAggregator++;

        emit VoteCast(disputeId, msg.sender, supportChallenger);
    }

    /// @inheritdoc IDisputeResolver
    function resolve(uint256 disputeId) external nonReentrant {
        FedTypes.Dispute storage d = _getDispute(disputeId);
        if (d.resolved) revert AlreadyResolved();
        if (block.timestamp <= d.voteDeadline) revert VotingOpen();

        uint256 total = uint256(d.votesForChallenger) + d.votesForAggregator;
        bool challengerWon = d.votesForChallenger > d.votesForAggregator && total >= quorum;

        d.resolved = true;
        d.challengerWon = challengerWon;

        // Settle the challenger's bond: refunded on a win, paid to the
        // falsely accused aggregator on a loss.
        uint256 bond = d.bond;
        d.bond = 0;
        _send(challengerWon ? d.challenger : d.aggregator, bond);

        // On a win the RoundManager also pays the aggregator's bond to the challenger.
        roundManager.resolveDispute(d.roundId, !challengerWon, d.challenger);

        emit DisputeResolved(disputeId, d.roundId, challengerWon);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IDisputeResolver
    function getDispute(uint256 disputeId) external view returns (FedTypes.Dispute memory) {
        return _disputes[disputeId];
    }

    /// @inheritdoc IDisputeResolver
    function hasVoted(uint256 disputeId, address voter) external view returns (bool) {
        return _voted[disputeId][voter];
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _getDispute(uint256 disputeId) private view returns (FedTypes.Dispute storage d) {
        d = _disputes[disputeId];
        if (d.challenger == address(0)) revert UnknownDispute(disputeId);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
