# SPDX-License-Identifier: GPL-2.0-or-later
"""Create two objects that share one mesh data-block."""

import bpy


mesh = bpy.data.meshes.new("BookSharedMesh")
objects = []
for name in ("BookSharedA", "BookSharedB"):
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    objects.append(obj)

print(objects[0].data is objects[1].data)
print(mesh.users)
