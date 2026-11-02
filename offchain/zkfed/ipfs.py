"""Minimal client for the IPFS (Kubo) HTTP API.

Update and model files are stored on a private IPFS cluster run by the
members; only their CIDs are written on-chain.
"""

from __future__ import annotations

import requests


class IPFSClient:
    def __init__(self, api_url: str = "http://127.0.0.1:5001"):
        self.api = api_url.rstrip("/") + "/api/v0"

    def add_bytes(self, data: bytes, name: str = "blob") -> str:
        """Uploads bytes, pins them, and returns the CID."""
        resp = requests.post(f"{self.api}/add", params={"pin": "true"}, files={"file": (name, data)}, timeout=60)
        resp.raise_for_status()
        return resp.json()["Hash"]

    def cat(self, cid: str) -> bytes:
        """Downloads the content addressed by `cid`."""
        resp = requests.post(f"{self.api}/cat", params={"arg": cid.removeprefix("ipfs://")}, timeout=60)
        resp.raise_for_status()
        return resp.content
