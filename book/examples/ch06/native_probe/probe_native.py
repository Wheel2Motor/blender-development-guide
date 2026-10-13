# SPDX-License-Identifier: GPL-2.0-or-later
"""Typed ctypes bindings for the Chapter 6 native probe library."""

import ctypes
import os
import sys

import numpy as np


if sys.platform == "win32":
    LIBRARY_NAME = "probe_native.dll"
elif sys.platform == "darwin":
    LIBRARY_NAME = "libprobe_native.dylib"
else:
    LIBRARY_NAME = "libprobe_native.so"


def load_library(example_dir):
    library_path = os.path.join(os.fspath(example_dir), LIBRARY_NAME)
    if not os.path.isfile(library_path):
        raise OSError(f"找不到原生库：{library_path}")

    library = ctypes.CDLL(library_path)
    library.probe_abi_version.restype = ctypes.c_uint32
    library.probe_abi_version.argtypes = []
    library.probe_scale_verts.restype = ctypes.c_int
    library.probe_scale_verts.argtypes = [
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_size_t,
        ctypes.c_float,
    ]
    library.probe_bounds.restype = ctypes.c_int
    library.probe_bounds.argtypes = [
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float),
    ]
    library.probe_busy_work.restype = ctypes.c_double
    library.probe_busy_work.argtypes = [ctypes.c_uint64]

    if library.probe_abi_version() != 1:
        raise OSError("原生库 ABI 版本不匹配，请重新编译")
    return library


def scale_verts(library, coords, factor):
    coords = np.ascontiguousarray(coords, dtype=np.float32)
    if coords.ndim != 2 or coords.shape[1] != 3:
        raise ValueError("coords 必须是形状为 (n, 3) 的数组")

    pointer = coords.ctypes.data_as(ctypes.POINTER(ctypes.c_float))
    result = library.probe_scale_verts(pointer, coords.shape[0], factor)
    if result != 0:
        raise RuntimeError(f"probe_scale_verts 返回错误码 {result}")
    return coords


def bounds(library, coords):
    coords = np.ascontiguousarray(coords, dtype=np.float32)
    if coords.ndim != 2 or coords.shape[1] != 3:
        raise ValueError("coords 必须是形状为 (n, 3) 的数组")

    out_min = np.empty(3, dtype=np.float32)
    out_max = np.empty(3, dtype=np.float32)
    result = library.probe_bounds(
        coords.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
        coords.shape[0],
        out_min.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
        out_max.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
    )
    if result != 0:
        raise RuntimeError(f"probe_bounds 返回错误码 {result}")
    return out_min, out_max
