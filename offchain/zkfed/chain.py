"""web3.py wrapper around the deployed ZK-FedChain contracts.

ABIs are read from the Hardhat artifacts and addresses from
deployments/<network>.json, both produced by the JavaScript tool-chain, so
the Python nodes never hard-code contract details.
"""

from __future__ import annotations

import json
from typing import Any

from web3 import Web3

from .config import NodeConfig

# Must match FedTypes.Phase in contracts/libraries/FedTypes.sol
PHASES = ["None", "Commit", "Reveal", "Aggregate", "Challenge", "Disputed", "Finalized"]


class FedChain:
    """Connection to RoundManager, Registry and DisputeResolver for one account."""

    def __init__(self, cfg: NodeConfig):
        self.cfg = cfg
        self.w3 = Web3(Web3.HTTPProvider(cfg.rpc_url))
        self.account = self.w3.eth.account.from_key(cfg.private_key) if cfg.private_key else None

        deployment = json.loads(cfg.deployment_file.read_text())
        self.round_manager = self._contract("RoundManager", deployment["RoundManager"])
        self.registry = self._contract("Registry", deployment["Registry"])
        self.dispute_resolver = self._contract("DisputeResolver", deployment["DisputeResolver"])

    # ------------------------------------------------------------------
    # Reads
    # ------------------------------------------------------------------

    def current_round(self) -> int:
        return self.round_manager.functions.currentRoundId().call()

    def get_round(self, round_id: int) -> dict[str, Any]:
        """Returns FedTypes.Round as a dict with the phase name resolved."""
        r = self.round_manager.functions.getRound(round_id).call()
        keys = [
            "phase", "commitDeadline", "revealDeadline", "aggregateDeadline", "challengeDeadline",
            "aggregator", "aggregatorBond", "prevModelHash", "modelHash", "modelCID",
            "acceptedBitmap", "numSubmissions",
        ]
        out = dict(zip(keys, r))
        out["phaseName"] = PHASES[out["phase"]]
        return out

    def latest_model(self) -> tuple[bytes, str, int]:
        """(model hash, IPFS CID, round that produced it)."""
        return tuple(self.round_manager.functions.latestModel().call())

    def submitters(self, round_id: int) -> list[str]:
        return self.round_manager.functions.submittersOf(round_id).call()

    def submission(self, round_id: int, client: str) -> dict[str, Any]:
        keys = ["commitment", "salt", "updateCID", "index", "revealed", "exists"]
        return dict(zip(keys, self.round_manager.functions.getSubmission(round_id, client).call()))

    def norm_bound_sq(self) -> int:
        return self.round_manager.functions.getConfig().call()[4]

    # ------------------------------------------------------------------
    # Writes (one method per contract entry point used by the nodes)
    # ------------------------------------------------------------------

    def start_round(self):
        return self._send(self.round_manager.functions.startRound())

    def submit_update(self, round_id: int, commitment: int, proof: dict):
        """proof = {"a": [..2], "b": [[..2],[..2]], "c": [..2]} in snarkjs calldata order."""
        return self._send(
            self.round_manager.functions.submitUpdate(round_id, commitment, (proof["a"], proof["b"], proof["c"]))
        )

    def reveal_update(self, round_id: int, update_cid: str, salt: int):
        return self._send(self.round_manager.functions.revealUpdate(round_id, update_cid, salt))

    def post_aggregate(self, round_id: int, model_hash: bytes, model_cid: str, accepted_bitmap: int, bond_wei: int):
        fn = self.round_manager.functions.postAggregate(round_id, model_hash, model_cid, accepted_bitmap)
        return self._send(fn, value=bond_wei)

    def advance_phase(self, round_id: int):
        return self._send(self.round_manager.functions.advancePhase(round_id))

    def finalize_round(self, round_id: int):
        return self._send(self.round_manager.functions.finalizeRound(round_id))

    def open_challenge(self, round_id: int, claimed_hash: bytes, evidence_cid: str, bond_wei: int):
        fn = self.dispute_resolver.functions.openChallenge(round_id, claimed_hash, evidence_cid)
        return self._send(fn, value=bond_wei)

    def cast_vote(self, dispute_id: int, support_challenger: bool):
        return self._send(self.dispute_resolver.functions.castVote(dispute_id, support_challenger))

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _contract(self, name: str, address: str):
        artifact = self.cfg.artifacts_dir / f"{name}.sol" / f"{name}.json"
        abi = json.loads(artifact.read_text())["abi"]
        return self.w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)

    def _send(self, fn, value: int = 0):
        """Builds, signs and sends a transaction; returns the receipt."""
        if self.account is None:
            raise RuntimeError("FED_PRIVATE_KEY is not set; this node is read-only")
        tx = fn.build_transaction(
            {
                "from": self.account.address,
                "value": value,
                "nonce": self.w3.eth.get_transaction_count(self.account.address),
            }
        )
        signed = self.account.sign_transaction(tx)
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction  # web3 v7 / v6
        tx_hash = self.w3.eth.send_raw_transaction(raw)
        return self.w3.eth.wait_for_transaction_receipt(tx_hash)
