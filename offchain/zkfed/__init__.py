"""Off-chain components of ZK-FedChain.

Modules
-------
config      Settings shared by every node (RPC URL, deployment file, IPFS API).
chain       Thin web3.py wrapper around the deployed contracts.
ipfs        Upload/download of update and model files through the IPFS HTTP API.
quantize    Fixed-point encoding of LoRA updates (matches the circuit).
prover      Builds the circuit input and calls snarkjs to produce a Groth16 proof.
client      FL client: local LoRA fine-tuning, commit, prove, submit, reveal.
aggregator  Fetches revealed updates, checks commitments, runs robust aggregation.
challenger  Re-runs aggregation, opens disputes and votes.

Draft status: interfaces and docstrings are in place; functions that need the
trained model or the compiled circuit raise NotImplementedError for now.
"""

__version__ = "0.1.0"
