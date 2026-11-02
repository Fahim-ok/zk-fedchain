"""Aggregator node (selected per round by the RoundManager).

Responsibilities in one round:
  1. read the revealed submissions (CID + salt) from the contract,
  2. download each update from IPFS and re-check it against its commitment,
  3. run a deterministic robust aggregation rule on the verified updates,
  4. upload the new global adapter to IPFS and call postAggregate with a bond.

The aggregation must be deterministic (fixed ordering by submission index,
no randomness), because challengers re-run exactly the same computation.
"""

from __future__ import annotations

import numpy as np
from web3 import Web3

from .chain import FedChain
from .config import NodeConfig
from .ipfs import IPFSClient


# ----------------------------------------------------------------------
# Robust aggregation rules (pure functions, shared with the challenger)
# ----------------------------------------------------------------------

def multi_krum(updates: np.ndarray, num_byzantine: int, num_selected: int | None = None) -> tuple[np.ndarray, list[int]]:
    """Multi-Krum (Blanchard et al., 2017).

    Each update is scored by the sum of squared distances to its n - f - 2
    nearest neighbours; the `num_selected` lowest-scoring updates are averaged.

    Args:
        updates: array of shape (n, d), rows ordered by submission index.
        num_byzantine: assumed number of malicious clients f.
        num_selected: m, number of updates to keep (default n - f).

    Returns:
        (aggregate, selected indices in ascending order)
    """
    n = updates.shape[0]
    f = num_byzantine
    m = num_selected if num_selected is not None else n - f
    k = n - f - 2
    if k < 1 or m < 1:
        raise ValueError("Multi-Krum needs n > f + 2")

    dists = np.sum((updates[:, None, :] - updates[None, :, :]) ** 2, axis=-1)
    scores = np.array([np.sort(np.delete(dists[i], i))[:k].sum() for i in range(n)])
    selected = sorted(np.argsort(scores, kind="stable")[:m].tolist())
    return updates[selected].mean(axis=0), selected


def trimmed_mean(updates: np.ndarray, trim_ratio: float = 0.1) -> np.ndarray:
    """Coordinate-wise trimmed mean (Yin et al., 2018)."""
    n = updates.shape[0]
    t = int(np.floor(trim_ratio * n))
    s = np.sort(updates, axis=0)
    return s[t : n - t].mean(axis=0)


def to_bitmap(indices: list[int]) -> int:
    """Encodes accepted submission indices as the uint256 bitmap used on-chain."""
    bitmap = 0
    for i in indices:
        bitmap |= 1 << i
    return bitmap


# ----------------------------------------------------------------------
# Node logic
# ----------------------------------------------------------------------

class Aggregator:
    def __init__(self, cfg: NodeConfig, num_byzantine: int = 1):
        self.cfg = cfg
        self.chain = FedChain(cfg)
        self.ipfs = IPFSClient(cfg.ipfs_api_url)
        self.num_byzantine = num_byzantine

    def fetch_revealed_updates(self, round_id: int) -> list[tuple[int, str, np.ndarray]]:
        """Returns (submission index, client, quantized update) for every revealed submission."""
        out = []
        for client in self.chain.submitters(round_id):
            sub = self.chain.submission(round_id, client)
            if not sub["revealed"]:
                continue
            raw = self.ipfs.cat(sub["updateCID"])
            update = np.frombuffer(raw, dtype=np.int16).astype(np.int64)
            if not self.commitment_matches(update, sub["salt"], round_id, client, sub["commitment"]):
                continue  # file does not match what was proven; excluded from aggregation
            out.append((sub["index"], client, update))
        return sorted(out, key=lambda t: t[0])

    def commitment_matches(self, update: np.ndarray, salt: int, round_id: int, client: str, commitment: int) -> bool:
        """Recomputes Poseidon(chain(packed update), salt, roundId, client) and compares.

        TODO: call circomlibjs' Poseidon through a small Node helper (or a
        Python Poseidon port) using the same packing as the circuit.
        """
        raise NotImplementedError("Poseidon re-check is planned for milestone 3")

    def run_round(self, round_id: int) -> None:
        """Aggregates one round and posts the result on-chain."""
        records = self.fetch_revealed_updates(round_id)
        indices = [r[0] for r in records]
        updates = np.stack([r[2] for r in records]).astype(np.float64)

        agg, selected_rows = multi_krum(updates, self.num_byzantine)
        accepted = [indices[i] for i in selected_rows]

        model_bytes = np.rint(agg).astype(np.int16).tobytes()
        model_cid = self.ipfs.add_bytes(model_bytes, name=f"global-r{round_id}.bin")
        model_hash = Web3.keccak(model_bytes)

        bond = self.chain.round_manager.functions.getConfig().call()[7]  # aggregatorBond
        self.chain.post_aggregate(round_id, model_hash, model_cid, to_bitmap(accepted), bond)
