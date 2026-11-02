#!/usr/bin/env bash
# Builds the norm-bound circuit, runs a development trusted setup, and exports
# the Solidity verifier to contracts/verifier/Groth16Verifier.sol.
#
#   npm run circuit:build                    # uses `circom` from PATH
#   CIRCOM="npx circom2" npm run circuit:build   # WebAssembly build of circom
#
# The locally generated Powers of Tau is for development only. For a shared
# deployment, download a public ceremony file instead, e.g.
#   powersOfTau28_hez_final_16.ptau  (supports up to 2^16 constraints)
# and place it at circuits/build/pot_final.ptau before running this script.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=circuits/build
PTAU_POWER=${PTAU_POWER:-16}   # 2^16 = 65,536 constraints; the D=1024 draft uses ~57k
CIRCOM=${CIRCOM:-circom}
SNARKJS="npx snarkjs"

mkdir -p "$BUILD" contracts/verifier

echo "==> Compiling circuit"
$CIRCOM circuits/norm_bound.circom --r1cs --wasm --sym -o "$BUILD"

if [ ! -f "$BUILD/pot_final.ptau" ]; then
  echo "==> Phase 1: Powers of Tau (development only)"
  $SNARKJS powersoftau new bn128 "$PTAU_POWER" "$BUILD/pot_0000.ptau"
  $SNARKJS powersoftau contribute "$BUILD/pot_0000.ptau" "$BUILD/pot_0001.ptau" --name="dev" -e="$(date +%s%N)"
  $SNARKJS powersoftau prepare phase2 "$BUILD/pot_0001.ptau" "$BUILD/pot_final.ptau"
fi

echo "==> Phase 2: circuit-specific setup"
$SNARKJS groth16 setup "$BUILD/norm_bound.r1cs" "$BUILD/pot_final.ptau" "$BUILD/norm_bound_0000.zkey"
$SNARKJS zkey contribute "$BUILD/norm_bound_0000.zkey" "$BUILD/norm_bound.zkey" --name="group30" -e="$(date +%s%N)"
$SNARKJS zkey export verificationkey "$BUILD/norm_bound.zkey" "$BUILD/verification_key.json"

echo "==> Exporting Solidity verifier"
$SNARKJS zkey export solidityverifier "$BUILD/norm_bound.zkey" contracts/verifier/Groth16Verifier.sol
echo "Done: contracts/verifier/Groth16Verifier.sol (run 'npx hardhat compile' next)"
