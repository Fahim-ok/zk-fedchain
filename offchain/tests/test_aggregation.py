"""Unit tests for the deterministic aggregation rules (no chain or IPFS needed).

Run from the repository root:  python -m pytest offchain/tests
"""

import numpy as np

from offchain.zkfed.aggregator import multi_krum, to_bitmap, trimmed_mean
from offchain.zkfed.quantize import INT16_MAX, quantize, squared_norm


def test_multi_krum_drops_scaled_update():
    rng = np.random.default_rng(0)
    honest = rng.normal(0, 1, size=(5, 32))
    attacker = honest.mean(axis=0, keepdims=True) * 50  # model-replacement style scaling
    updates = np.vstack([honest, attacker])
    _, selected = multi_krum(updates, num_byzantine=1)
    assert 5 not in selected
    assert selected == sorted(selected)


def test_trimmed_mean_ignores_extremes():
    updates = np.array([[1.0], [1.1], [0.9], [100.0], [-100.0]])
    assert abs(trimmed_mean(updates, 0.2)[0] - 1.0) < 1e-9


def test_bitmap_and_quantize():
    assert to_bitmap([0, 2, 3]) == 0b1101
    q = quantize(np.array([0.5, -0.25, 100.0]), scale=2**12)
    assert q.tolist() == [2048, -1024, INT16_MAX]
    assert squared_norm(q) == 2048**2 + 1024**2 + INT16_MAX**2
