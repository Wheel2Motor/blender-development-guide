# SPDX-License-Identifier: GPL-2.0-or-later
"""Print the RNA identifier, properties, and functions of a temporary mesh."""

import bpy


mesh = bpy.data.meshes.new("BookRNAProbe")
try:
    print(mesh.bl_rna.identifier)
    print(len(mesh.bl_rna.properties))
    print([item.identifier for item in mesh.bl_rna.functions])
finally:
    bpy.data.meshes.remove(mesh)
