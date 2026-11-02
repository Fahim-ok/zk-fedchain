// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IGroth16Verifier
 * @notice Interface of the Groth16 verifier exported by snarkjs from the
 *         norm-bound circuit (circuits/norm_bound.circom).
 *
 * @dev The signature matches `snarkjs zkey export solidityverifier`, so the
 *      generated `Groth16Verifier` contract satisfies this interface without
 *      changes. Verification uses the BN254 pairing precompiles (EIP-1108).
 *
 *      Public signals, in the order produced by the circuit:
 *        [0] commitment  - Poseidon commitment to (update, salt, roundId, client)
 *        [1] normBoundSq - agreed bound B^2 on the squared L2 norm of the update
 *        [2] roundId     - binds the proof to one round (no replay across rounds)
 *        [3] client      - uint160 address of the submitter (no replay by others)
 *
 *      The RoundManager fills [1]-[3] from its own state; only the commitment
 *      and the proof come from the client.
 */
interface IGroth16Verifier {
    /**
     * @notice Checks a Groth16 proof against four public signals.
     * @param pA Proof element A (G1 point).
     * @param pB Proof element B (G2 point).
     * @param pC Proof element C (G1 point).
     * @param pubSignals Public signals in the order documented above.
     * @return True if the proof is valid for these public signals.
     */
    function verifyProof(
        uint256[2] calldata pA,
        uint256[2][2] calldata pB,
        uint256[2] calldata pC,
        uint256[4] calldata pubSignals
    ) external view returns (bool);
}
