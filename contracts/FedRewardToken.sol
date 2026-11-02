// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IFedRewardToken} from "./interfaces/IFedRewardToken.sol";

/**
 * @title FedRewardToken (FCR)
 * @notice ERC-20 token paid to clients whose updates are accepted into the
 *         global model and to aggregators whose aggregates are not overturned.
 * @dev Only the RoundManager holds MINTER_ROLE, so tokens are created only
 *      when a round is finalized. The token has no monetary meaning in the
 *      course prototype; it records each member's contribution on-chain.
 */
contract FedRewardToken is ERC20, AccessControl, IFedRewardToken {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @param admin Address allowed to grant MINTER_ROLE (granted to the RoundManager at deployment).
    constructor(address admin) ERC20("FedChain Reward", "FCR") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IFedRewardToken
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
