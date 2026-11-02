"""Groth16 proof generation for the norm-bound circuit (calls snarkjs).

The circuit outputs the Poseidon commitment, so the client does not need its
own Poseidon implementation: snarkjs returns the commitment as public
signal [0] together with the proof.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np

from .config import NodeConfig
from .quantize import field_encode, pad_to_dim


def build_circuit_input(q_update: np.ndarray, salt: int, round_id: int, client: str, norm_bound_sq: int, dim: int) -> dict:
    """Creates the JSON input expected by circuits/norm_bound.circom."""
    return {
        "normBoundSq": str(norm_bound_sq),
        "roundId": str(round_id),
        "client": str(int(client, 16)),
        "delta": field_encode(pad_to_dim(q_update, dim)),
        "salt": str(salt),
    }


def prove(cfg: NodeConfig, circuit_input: dict) -> tuple[int, dict, list[str]]:
    """Runs `snarkjs groth16 fullprove` and converts the result to contract calldata.

    Returns (commitment, proof, public_signals) where proof has keys a, b, c in
    the layout expected by FedTypes.Proof.
    """
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "input.json").write_text(json.dumps(circuit_input))
        subprocess.run(
            ["npx", "snarkjs", "groth16", "fullprove", str(tmp / "input.json"), str(cfg.circuit_wasm),
             str(cfg.circuit_zkey), str(tmp / "proof.json"), str(tmp / "public.json")],
            check=True,
        )
        calldata = subprocess.run(
            ["npx", "snarkjs", "zkey", "export", "soliditycalldata", str(tmp / "public.json"), str(tmp / "proof.json")],
            check=True, capture_output=True, text=True,
        ).stdout
    a, b, c, public = json.loads(f"[{calldata}]")
    proof = {"a": [int(x, 16) for x in a], "b": [[int(x, 16) for x in row] for row in b], "c": [int(x, 16) for x in c]}
    commitment = int(public[0], 16)
    return commitment, proof, public
