# SPDX-License-Identifier: GPL-2.0-or-later
"""Check Blender's operator registry without creating a proxy object."""

from _bpy import ops as _ops


registered = set(_ops.dir())
print("my_addon.hello 已注册:", "MY_ADDON_OT_hello" in registered)
