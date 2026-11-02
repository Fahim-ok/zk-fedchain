# contracts/verifier

`Groth16Verifier.sol` is **generated**, not written by hand. Create it with

```bash
npm run circuit:build
```

which runs `snarkjs zkey export solidityverifier` on the norm-bound circuit
(`circuits/norm_bound.circom`). The generated contract exposes

```solidity
function verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB,
                     uint[2] calldata _pC, uint[4] calldata _pubSignals)
    public view returns (bool);
```

which matches `contracts/interfaces/IGroth16Verifier.sol`, so `RoundManager`
can use it directly. Until it exists, local deployments and tests use
`contracts/mocks/MockVerifier.sol`.

The file is re-generated whenever the circuit or its trusted setup changes,
so it is listed in `.gitignore`.
