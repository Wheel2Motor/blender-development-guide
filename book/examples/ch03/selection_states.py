# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare three ways to read selection and active-object state."""

import bpy


print([obj.name for obj in bpy.context.selected_objects])

view_layer = bpy.context.view_layer
print([obj.name for obj in view_layer.objects if obj.select_get()])

print(view_layer.objects.active)
print(bpy.context.active_object)
