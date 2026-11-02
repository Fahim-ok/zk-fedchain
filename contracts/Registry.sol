// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";

/**
 * @title Registry
 * @notice Consortium allow-list with ETH stake and a reputation score per member.
 *
 * @dev Roles
 *      - DEFAULT_ADMIN_ROLE: consortium governance (adds/removes members, sets
 *        parameters). In a real deployment this would be a multisig owned
 *        by the member organizations.
 *      - PROTOCOL_ROLE: granted to RoundManager and DisputeResolver so they
 *        can lock stake during a round, slash it and change reputation.
 *
 *      Members cannot withdraw stake while it is locked by an open round, so
 *      a client cannot escape a penalty by withdrawing mid-round.
 */
contract Registry is IRegistry, AccessControl, ReentrancyGuard {
    bytes32 public constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");

    /// @dev Per-member bookkeeping.
    struct Member {
        bool active;
        uint256 stake; // wei
        int256 reputation; // +1 per accepted update, -1 per filtered update, larger drops for misbehaviour
        uint64 lockedUntil; // stake cannot be withdrawn before this time
    }

    /// @notice Minimum stake (wei) a member needs to take part in a round.
    uint256 public minStake;

    /// @notice Receives slashed ETH when no beneficiary is given.
    address public treasury;

    mapping(address => Member) private _members;
    address[] private _memberList;
    mapping(address => uint256) private _indexPlusOne; // position in _memberList, 0 = absent

    error NotMember(address account);
    error AlreadyMember(address account);
    error ZeroAddress();
    error StakeIsLocked(uint64 until);
    error InsufficientStake(uint256 requested, uint256 available);
    error TransferFailed();

    /**
     * @param minStake_ Minimum stake (wei) for a member to be eligible for a round.
     * @param treasury_ Receiver of slashed ETH that has no specific beneficiary.
     * @param admin Initial governance address.
     */
    constructor(uint256 minStake_, address treasury_, address admin) {
        if (treasury_ == address(0) || admin == address(0)) revert ZeroAddress();
        minStake = minStake_;
        treasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    /// @inheritdoc IRegistry
    function addMember(address member) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (member == address(0)) revert ZeroAddress();
        if (_members[member].active) revert AlreadyMember(member);
        _members[member].active = true;
        _memberList.push(member);
        _indexPlusOne[member] = _memberList.length;
        emit MemberAdded(member);
    }

    /// @inheritdoc IRegistry
    function removeMember(address member) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_members[member].active) revert NotMember(member);
        _members[member].active = false;

        // swap-and-pop so memberAt() stays dense
        uint256 idx = _indexPlusOne[member] - 1;
        address last = _memberList[_memberList.length - 1];
        _memberList[idx] = last;
        _indexPlusOne[last] = idx + 1;
        _memberList.pop();
        delete _indexPlusOne[member];

        emit MemberRemoved(member);
    }

    /// @notice Updates the minimum stake required for eligibility.
    function setMinStake(uint256 newMinStake) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minStake = newMinStake;
    }

    /// @notice Updates the treasury that receives unassigned slashed ETH.
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    // ------------------------------------------------------------------
    // Members
    // ------------------------------------------------------------------

    /// @inheritdoc IRegistry
    function depositStake() external payable {
        Member storage m = _members[msg.sender];
        if (!m.active) revert NotMember(msg.sender);
        m.stake += msg.value;
        emit StakeDeposited(msg.sender, msg.value, m.stake);
    }

    /// @inheritdoc IRegistry
    /// @dev Removed members may still withdraw what is left of their stake.
    function withdrawStake(uint256 amount) external nonReentrant {
        Member storage m = _members[msg.sender];
        if (m.lockedUntil > block.timestamp) revert StakeIsLocked(m.lockedUntil);
        if (amount > m.stake) revert InsufficientStake(amount, m.stake);
        m.stake -= amount;
        _send(msg.sender, amount);
        emit StakeWithdrawn(msg.sender, amount, m.stake);
    }

    // ------------------------------------------------------------------
    // Protocol hooks
    // ------------------------------------------------------------------

    /// @inheritdoc IRegistry
    function slash(address member, uint256 amount, bytes32 reason, address beneficiary)
        external
        onlyRole(PROTOCOL_ROLE)
        nonReentrant
        returns (uint256 slashed)
    {
        Member storage m = _members[member];
        slashed = amount < m.stake ? amount : m.stake;
        m.stake -= slashed;
        address to = beneficiary == address(0) ? treasury : beneficiary;
        if (slashed > 0) _send(to, slashed);
        emit Slashed(member, slashed, reason, to);
    }

    /// @inheritdoc IRegistry
    function adjustReputation(address member, int256 delta) external onlyRole(PROTOCOL_ROLE) {
        Member storage m = _members[member];
        m.reputation += delta;
        emit ReputationChanged(member, delta, m.reputation);
    }

    /// @inheritdoc IRegistry
    /// @dev Locks only ever extend; a shorter lock never shortens an existing one.
    function lockStake(address member, uint64 until) external onlyRole(PROTOCOL_ROLE) {
        Member storage m = _members[member];
        if (until > m.lockedUntil) {
            m.lockedUntil = until;
            emit StakeLocked(member, until);
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IRegistry
    function isEligible(address member) external view returns (bool) {
        Member storage m = _members[member];
        return m.active && m.stake >= minStake;
    }

    /// @inheritdoc IRegistry
    function isMember(address member) external view returns (bool) {
        return _members[member].active;
    }

    /// @inheritdoc IRegistry
    function stakeOf(address member) external view returns (uint256) {
        return _members[member].stake;
    }

    /// @inheritdoc IRegistry
    function reputationOf(address member) external view returns (int256) {
        return _members[member].reputation;
    }

    /// @inheritdoc IRegistry
    function lockedUntil(address member) external view returns (uint64) {
        return _members[member].lockedUntil;
    }

    /// @inheritdoc IRegistry
    function memberCount() external view returns (uint256) {
        return _memberList.length;
    }

    /// @inheritdoc IRegistry
    function memberAt(uint256 index) external view returns (address) {
        return _memberList[index];
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _send(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
