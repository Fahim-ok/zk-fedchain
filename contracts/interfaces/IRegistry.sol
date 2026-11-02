// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IRegistry
 * @notice Membership, stake and reputation for the consortium.
 *
 * @dev The Registry is the only contract that holds member stake (in ETH).
 *      Protocol contracts (RoundManager, DisputeResolver) get PROTOCOL_ROLE
 *      so they can lock, slash and adjust reputation. Penalties follow the
 *      strength of the evidence:
 *        - cryptographic evidence (failed proof, unrevealed commitment,
 *          overturned aggregate) -> stake is slashed;
 *        - statistical evidence (update dropped by robust aggregation)
 *          -> only reputation is lowered, since honest non-IID clients can
 *          also be filtered out.
 */
interface IRegistry {
    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event MemberAdded(address indexed member);
    event MemberRemoved(address indexed member);
    event StakeDeposited(address indexed member, uint256 amount, uint256 newStake);
    event StakeWithdrawn(address indexed member, uint256 amount, uint256 newStake);
    event StakeLocked(address indexed member, uint64 until);
    event Slashed(address indexed member, uint256 amount, bytes32 indexed reason, address beneficiary);
    event ReputationChanged(address indexed member, int256 delta, int256 newScore);

    // ------------------------------------------------------------------
    // Admin (consortium governance; a multisig in a real deployment)
    // ------------------------------------------------------------------

    /// @notice Adds an organization to the member allow-list.
    function addMember(address member) external;

    /// @notice Removes a member (e.g., after a member vote). Its remaining stake stays withdrawable.
    function removeMember(address member) external;

    // ------------------------------------------------------------------
    // Members
    // ------------------------------------------------------------------

    /// @notice Deposits ETH as stake. Only allow-listed members may deposit.
    function depositStake() external payable;

    /// @notice Withdraws stake that is not locked by an open round.
    /// @param amount Amount of wei to withdraw.
    function withdrawStake(uint256 amount) external;

    // ------------------------------------------------------------------
    // Protocol hooks (PROTOCOL_ROLE only)
    // ------------------------------------------------------------------

    /**
     * @notice Burns part of a member's stake as a penalty.
     * @param member Member being penalized.
     * @param amount Requested penalty in wei; capped at the member's stake.
     * @param reason Short reason code (e.g., "INVALID_PROOF").
     * @param beneficiary Receiver of the slashed ETH; address(0) sends it to the treasury.
     * @return slashed Amount actually taken.
     */
    function slash(address member, uint256 amount, bytes32 reason, address beneficiary)
        external
        returns (uint256 slashed);

    /// @notice Adds a signed delta to a member's reputation score.
    function adjustReputation(address member, int256 delta) external;

    /// @notice Prevents a member from withdrawing stake before `until` (unix time).
    function lockStake(address member, uint64 until) external;

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice True if the address is an active member with at least `minStake` staked.
    function isEligible(address member) external view returns (bool);

    function isMember(address member) external view returns (bool);

    function stakeOf(address member) external view returns (uint256);

    function reputationOf(address member) external view returns (int256);

    function lockedUntil(address member) external view returns (uint64);

    function memberCount() external view returns (uint256);

    function memberAt(uint256 index) external view returns (address);

    function minStake() external view returns (uint256);
}
