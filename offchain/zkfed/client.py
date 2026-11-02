"""FL client node.

One call to :meth:`FLClient.run_round` performs the client side of a round:
  1. download the latest global adapter (RoundManager.latestModel -> IPFS),
  2. fine-tune LoRA adapters on the local private dataset,
  3. quantize the update to signed 16-bit fixed point,
  4. prove with Groth16 that its squared norm is within the on-chain bound
     (the circuit also outputs the Poseidon commitment),
  5. submitUpdate(roundId, commitment, proof) during the Commit phase,
  6. after the commit deadline, upload the update to IPFS and
     revealUpdate(roundId, cid, salt) during the Reveal phase.
"""

from __future__ import annotations

import secrets

import numpy as np

from .chain import FedChain
from .config import NodeConfig
from .ipfs import IPFSClient
from .prover import build_circuit_input, prove
from .quantize import quantize, squared_norm


class FLClient:
    def __init__(self, cfg: NodeConfig, data_dir: str):
        self.cfg = cfg
        self.data_dir = data_dir
        self.chain = FedChain(cfg)
        self.ipfs = IPFSClient(cfg.ipfs_api_url)
        self._pending: dict[int, tuple[np.ndarray, int]] = {}  # round -> (quantized update, salt)

    # ---- training -----------------------------------------------------

    def train_local(self, global_adapter: bytes) -> np.ndarray:
        """Fine-tunes LoRA adapters (DistilBERT, rank 4) on local SST-2 data.

        Returns the flattened float update (new adapter - global adapter).
        TODO (milestone 3): load the base model with transformers, attach the
        adapter with peft, train for cfg.local_epochs, and diff the weights.
        """
        raise NotImplementedError

    # ---- protocol steps -----------------------------------------------

    def commit(self, round_id: int, update: np.ndarray) -> None:
        """Quantizes, proves and submits the update for `round_id`."""
        q = quantize(update, self.cfg.quant_scale)
        bound = self.chain.norm_bound_sq()
        if squared_norm(q) > bound:
            # Scale down instead of submitting a proof that cannot verify.
            q = np.rint(q * np.sqrt(bound / squared_norm(q))).astype(np.int64)

        salt = secrets.randbelow(2**248)
        circuit_input = build_circuit_input(q, salt, round_id, self.chain.account.address, bound, self.cfg.circuit_dim)
        commitment, proof, _ = prove(self.cfg, circuit_input)
        self.chain.submit_update(round_id, commitment, proof)
        self._pending[round_id] = (q, salt)

    def reveal(self, round_id: int) -> str:
        """Uploads the committed update to IPFS and reveals its CID and salt."""
        q, salt = self._pending.pop(round_id)
        cid = self.ipfs.add_bytes(q.astype(np.int16).tobytes(), name=f"update-r{round_id}.bin")
        self.chain.reveal_update(round_id, cid, salt)
        return cid

    def run_round(self, round_id: int) -> None:
        """Full client round. Waiting for phase changes is left to the caller/scheduler."""
        _, model_cid, _ = self.chain.latest_model()
        update = self.train_local(self.ipfs.cat(model_cid))
        self.commit(round_id, update)
        # ... wait until the round is in the Reveal phase ...
        self.reveal(round_id)
