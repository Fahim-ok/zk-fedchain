"""Challenger / voter node (any staked member).

During the Challenge phase a member re-runs the deterministic aggregation
on the revealed updates and compares the resulting model hash with the one
the aggregator posted. On a mismatch it opens a dispute; while a dispute is
open, every other member uses the same check to decide its vote.
"""

from __future__ import annotations

import numpy as np
from web3 import Web3

from .aggregator import Aggregator, multi_krum


class Challenger(Aggregator):
    """Reuses the aggregator's fetching and aggregation code so results are identical."""

    def recompute_model_hash(self, round_id: int) -> bytes:
        records = self.fetch_revealed_updates(round_id)
        updates = np.stack([r[2] for r in records]).astype(np.float64)
        agg, _ = multi_krum(updates, self.num_byzantine)
        return Web3.keccak(np.rint(agg).astype(np.int16).tobytes())

    def check_round(self, round_id: int) -> bool:
        """True if the posted aggregate matches this node's own re-execution."""
        posted = self.chain.get_round(round_id)["modelHash"]
        return self.recompute_model_hash(round_id) == posted

    def challenge_if_wrong(self, round_id: int, evidence_cid: str = "") -> int | None:
        """Opens a dispute when the posted aggregate is wrong; returns the dispute id."""
        if self.check_round(round_id):
            return None
        bond = self.chain.dispute_resolver.functions.challengeBond().call()
        self.chain.open_challenge(round_id, self.recompute_model_hash(round_id), evidence_cid, bond)
        return self.chain.dispute_resolver.functions.disputeOfRound(round_id).call()

    def vote(self, dispute_id: int) -> None:
        """Votes for the challenger if this node's re-execution disagrees with the aggregator."""
        dispute = self.chain.dispute_resolver.functions.getDispute(dispute_id).call()
        round_id = dispute[0]
        self.chain.cast_vote(dispute_id, support_challenger=not self.check_round(round_id))
