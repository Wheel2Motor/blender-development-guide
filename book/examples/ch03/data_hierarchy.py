# SPDX-License-Identifier: GPL-2.0-or-later
"""Print one safe path from the current scene to mesh elements."""

import bpy


scene = bpy.context.scene
view_layer = bpy.context.view_layer
collection = scene.collection
obj = next(
    (item for item in scene.objects if item.type == "MESH" and item.data is not None),
    None,
)

print("Scene:", scene.name)
print("View layer:", view_layer.name)
print("Root collection:", collection.name)
if obj is None:
    print("当前场景没有网格物体")
else:
    mesh = obj.data
    print("Object:", obj.name, "Mesh:", mesh.name)
    print(len(mesh.vertices), len(mesh.polygons), len(mesh.materials))
