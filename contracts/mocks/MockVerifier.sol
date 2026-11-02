// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGroth16Verifier} from "../interfaces/IGroth16Verifier.sol";

/**
 * @title MockVerifier
 * @notice Stand-in for the snarkjs Groth16Verifier, used in unit tests and
 *         local demos before the circuit and trusted setup are ready.
 * @dev Returns a configurable result. NEVER deploy this on a shared network.
 */
contract MockVerifier is IGroth16Verifier {
    bool public result = true;

    /// @notice Sets the value returned by verifyProof (used to simulate a bad proof).
    function setResult(bool newResult) external {
        result = newResult;
    }

    /// @inheritdoc IGroth16Verifier
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}
