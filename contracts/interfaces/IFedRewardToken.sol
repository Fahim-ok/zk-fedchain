// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IFedRewardToken
 * @notice Minimal interface the RoundManager needs from the ERC-20 reward token.
 * @dev The full ERC-20 surface comes from OpenZeppelin in FedRewardToken.sol.
 */
interface IFedRewardToken {
    /// @notice Mints `amount` reward tokens to `to`. Restricted to MINTER_ROLE (the RoundManager).
    function mint(address to, uint256 amount) external;
}
