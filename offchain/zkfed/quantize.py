"""Fixed-point encoding of LoRA updates.

The circuit works over integers, so a floating-point update is scaled,
rounded and clipped to signed 16-bit values before proving. The same
encoding is used by the aggregator when it re-checks commitments, so the
functions here must stay in sync with circuits/norm_bound.circom.
"""

from __future__ import annotations

import numpy as np

INT16_MIN, INT16_MAX = -(2**15), 2**15 - 1
# BN254 scalar field modulus used by circom/snarkjs
BN254_P =21888242871839275222246405745257275088548364400416034343698204186575808495617


def quantize(update: np.ndarray, scale: float) -> np.ndarray:
    """Scales a float update and rounds it to int16, clipping out-of-range values."""
    q = np.rint(np.asarray(update, dtype=np.float64) * scale)
    return np.clip(q, INT16_MIN, INT16_MAX).astype(np.int64)


def dequantize(q: np.ndarray, scale: float) -> np.ndarray:
    """Inverse of :func:`quantize` (up to rounding)."""
    return np.asarray(q, dtype=np.float64) / scale


def squared_norm(q: np.ndarray) -> int:
    """Integer squared L2 norm, the quantity bounded inside the circuit."""
    q = np.asarray(q, dtype=np.int64)
    return int(np.dot(q, q))


def pad_to_dim(q: np.ndarray, dim: int) -> np.ndarray:
    """Zero-pads (or rejects) an update so it has exactly `dim` coordinates."""
    q = np.asarray(q, dtype=np.int64).ravel()
    if q.size > dim:
        raise ValueError(f"update has {q.size} coordinates, circuit supports {dim}")
    return np.pad(q, (0, dim - q.size))


def field_encode(q: np.ndarray) -> list[str]:
    """Encodes signed integers as BN254 field elements (negatives become p - |x|).

    snarkjs expects decimal strings in the circuit input JSON.
    """
    return [str(int(x) % BN254_P) for x in np.asarray(q, dtype=np.int64)]
