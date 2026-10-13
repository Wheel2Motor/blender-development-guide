# SPDX-License-Identifier: GPL-2.0-or-later
"""Print Blender's general and Python-specific debug flags."""

import bpy


print("debug:", bpy.app.debug)
print("debug_python:", bpy.app.debug_python)
