"""Shared configuration for client, aggregator and challenger nodes."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass
class NodeConfig:
    """Settings for one off-chain node.

    Values default to environment variables so the same code runs against a
    local Hardhat node, Sepolia, or a private Besu network.
    """

    network: str = os.getenv("FED_NETWORK", "localhost")
    rpc_url: str = os.getenv("FED_RPC_URL", "http://127.0.0.1:8545")
    private_key: str = os.getenv("FED_PRIVATE_KEY", "")
    ipfs_api_url: str = os.getenv("IPFS_API_URL", "http://127.0.0.1:5001")

    # Paths produced by `npx hardhat compile`, `scripts/deploy.js` and the circuit build.
    artifacts_dir: Path = REPO_ROOT / "artifacts" / "contracts"
    deployments_dir: Path = REPO_ROOT / "deployments"
    circuit_wasm: Path = REPO_ROOT / "circuits" / "build" / "norm_bound_js" / "norm_bound.wasm"
    circuit_zkey: Path = REPO_ROOT / "circuits" / "build" / "norm_bound.zkey"

    # Model / training (initial prototype in the proposal)
    base_model: str = "distilbert-base-uncased"
    dataset: str = "glue/sst2"
    lora_rank: int = 4
    lora_target_modules: list[str] = field(default_factory=lambda: ["q_lin", "v_lin"])
    local_epochs: int = 1

    # Fixed-point encoding; must match the circuit (16-bit signed coordinates)
    quant_scale: float = 2**12
    circuit_dim: int = 1024  # D in circuits/norm_bound.circom

    @property
    def deployment_file(self) -> Path:
        return self.deployments_dir / f"{self.network}.json"
