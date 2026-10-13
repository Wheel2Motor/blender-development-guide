# SPDX-License-Identifier: GPL-2.0-or-later

import math
from collections import namedtuple

import bmesh
import numpy as np


Finding = namedtuple("Finding", "check severity count detail")

CHECK_DEGENERATE = "degenerate_faces"
CHECK_NON_MANIFOLD = "non_manifold_edges"
CHECK_LOOSE_EDGES = "loose_edges"
CHECK_MESH_VALIDATE = "mesh_validate"
CHECK_SCALE = "scale_deviation"


def positions_minmax(mesh):
    """Return the position attribute's axis-aligned bounds."""
    attribute = mesh.attributes.get("position")
    if attribute is None or len(attribute.data) == 0:
        return None
    flat = np.empty(len(attribute.data) * 3, dtype=np.float32)
    attribute.data.foreach_get("vector", flat)
    positions = flat.reshape(len(attribute.data), 3)
    return tuple(positions.min(axis=0)), tuple(positions.max(axis=0))


def degenerate_face_count(mesh, area_limit):
    """Return the number and total area of faces below ``area_limit``."""
    if len(mesh.polygons) == 0:
        return 0, 0.0
    areas = np.empty(len(mesh.polygons), dtype=np.float32)
    mesh.polygons.foreach_get("area", areas)
    below_limit = areas < area_limit
    return int(np.count_nonzero(below_limit)), float(areas[below_limit].sum())


def topology_counts(mesh):
    """Return counts for non-manifold and loose edges."""
    bmesh_data = bmesh.new()
    try:
        bmesh_data.from_mesh(mesh)
        non_manifold = 0
        loose = 0
        for edge in bmesh_data.edges:
            if edge.is_wire:
                loose += 1
            elif not edge.is_manifold:
                non_manifold += 1
        return non_manifold, loose
    finally:
        bmesh_data.free()


def scale_deviation(vector):
    """Return zero for uniform scale and a ratio for non-uniform scale."""
    axes = [abs(value) for value in vector]
    largest = max(axes)
    if largest <= 0.0:
        return math.inf
    return (largest - min(axes)) / largest


def inspect_mesh(obj, limits):
    """Inspect one Blender mesh object and return ``Finding`` records."""
    import bpy

    mesh = obj.data
    findings = []

    count, total_area = degenerate_face_count(mesh, limits.degenerate_area)
    if count:
        findings.append(
            Finding(
                CHECK_DEGENERATE,
                "ERROR",
                count,
                f"{count} faces below area {limits.degenerate_area:g} "
                f"(total {total_area:.6g})",
            )
        )

    non_manifold, loose = topology_counts(mesh)
    if non_manifold > limits.max_non_manifold_edges:
        findings.append(
            Finding(
                CHECK_NON_MANIFOLD,
                "WARNING",
                non_manifold,
                f"{non_manifold} non-manifold edges "
                f"(limit {limits.max_non_manifold_edges})",
            )
        )
    if loose and limits.report_loose_edges:
        findings.append(
            Finding(
                CHECK_LOOSE_EDGES,
                "WARNING",
                loose,
                f"{loose} loose edges not attached to any face",
            )
        )

    probe = mesh.copy()
    try:
        if probe.validate(verbose=False):
            findings.append(
                Finding(
                    CHECK_MESH_VALIDATE,
                    "ERROR",
                    1,
                    "Blender reported invalid geometry in a copy of this mesh",
                )
            )
    finally:
        bpy.data.meshes.remove(probe)

    deviation = scale_deviation(obj.scale)
    if deviation > limits.max_scale_deviation:
        findings.append(
            Finding(
                CHECK_SCALE,
                "INFO",
                1,
                f"non-uniform object scale {tuple(round(v, 6) for v in obj.scale)}",
            )
        )

    return findings
