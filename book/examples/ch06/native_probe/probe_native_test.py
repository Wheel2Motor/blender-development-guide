# SPDX-License-Identifier: GPL-2.0-or-later
"""Build-independent runtime checks for the Chapter 6 native probe library."""

from pathlib import Path

import numpy as np

from probe_native import bounds, load_library, scale_verts


example_dir = Path(__file__).resolve().parent
library = load_library(example_dir)

coords = np.array(
    [
        [-1.0, 2.0, 3.0],
        [4.0, -5.0, 6.0],
        [0.5, 0.25, -0.75],
    ],
    dtype=np.float32,
)
expected = coords * 2.0
scaled = scale_verts(library, coords, 2.0)
np.testing.assert_allclose(scaled, expected)

actual_min, actual_max = bounds(library, scaled)
np.testing.assert_allclose(actual_min, scaled.min(axis=0))
np.testing.assert_allclose(actual_max, scaled.max(axis=0))

null_result = library.probe_scale_verts(None, 1, 1.0)
assert null_result == -1
print("PROBE ALL OK")
