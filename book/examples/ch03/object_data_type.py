# SPDX-License-Identifier: GPL-2.0-or-later
"""Inspect the payload type of the active Blender object safely."""

import bpy


obj = bpy.context.active_object
if obj is None or obj.data is None:
    print("没有可显示的数据")
elif obj.type == "MESH":
    print(f"{obj.name} 的网格：{len(obj.data.vertices)} 个顶点")
else:
    print(f"{obj.name} 的载荷类型是 {type(obj.data).__name__}")
