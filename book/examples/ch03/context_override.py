# SPDX-License-Identifier: GPL-2.0-or-later
"""Find a 3D View and temporarily override Blender's current context."""

import bpy


target = next(
    (
        (window, area)
        for window in bpy.context.window_manager.windows
        for area in window.screen.areas
        if area.type == "VIEW_3D"
    ),
    None,
)

if target is None:
    print("没有 3D 视图；纯后台模式通常如此")
else:
    window, area = target
    region = next((item for item in area.regions if item.type == "WINDOW"), None)
    if region is None:
        print("3D 视图没有 WINDOW 区域")
    else:
        with bpy.context.temp_override(window=window, area=area, region=region):
            print(bpy.context.area.type, bpy.context.region.type)
