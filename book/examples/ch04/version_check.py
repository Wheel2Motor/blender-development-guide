# SPDX-License-Identifier: GPL-2.0-or-later
"""Branch on Blender's structured version tuple."""

import bpy


if bpy.app.version >= (5, 0, 0):
    print("使用 5.0 或更新的 API 分支")
else:
    print("需要兼容分支；当前版本:", bpy.app.version_string)
