# SPDX-License-Identifier: GPL-2.0-or-later
"""The minimal installable Blender add-on from Chapter 4."""

bl_info = {
    "name": "My Add-on",
    "author": "You",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "View3D > Sidebar > My Tab",
    "description": "A minimal but complete add-on",
    "warning": "",
    "doc_url": "",
    "support": "COMMUNITY",
    "category": "Object",
}

import bpy


class MYADDON_OT_hello(bpy.types.Operator):
    """Say hello."""

    bl_idname = "my_addon.hello"
    bl_label = "Hello"
    bl_options = {"REGISTER"}

    def execute(self, context):
        self.report({"INFO"}, "hello from my_addon")
        return {"FINISHED"}


class MYADDON_PT_panel(bpy.types.Panel):
    bl_label = "My Add-on"
    bl_idname = "MYADDON_PT_panel"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "My Tab"

    def draw(self, context):
        self.layout.operator(MYADDON_OT_hello.bl_idname)


CLASSES = (MYADDON_OT_hello, MYADDON_PT_panel)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
