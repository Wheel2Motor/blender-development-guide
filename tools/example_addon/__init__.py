# SPDX-License-Identifier: GPL-2.0-or-later
"""《Blender 开发指南》截图用的示例插件。

这个插件的唯一目的是让截图里出现一个**真实的、我们自己写的**界面元素：
一个显示当前选中对象信息的侧栏面板，外加一个操作符与一份偏好设置。
它不是第 7 章那个完整项目，只是一个最小但完整的 addon 骨架。

安装方式（截图的 capture_screenshots.py 会自动处理）：
把本目录复制到 <用户脚本目录>/addons/ 下，或在脚本里直接 import 后调用 register()。
"""

bl_info = {
    "name": "Guide Panel Sample",
    "author": "Blender 开发指南",
    "version": (1, 0, 0),
    "blender": (5, 0, 0),
    "location": "View3D > Sidebar > Guide",
    "description": "《Blender 开发指南》截图用示例：一个侧栏面板 + 一个操作符 + 偏好设置",
    "category": "Development",
}

import bpy
from bpy.props import IntProperty, PointerProperty, StringProperty
from bpy.types import AddonPreferences, Operator, Panel, PropertyGroup


class GUIDE_OT_report_selection(Operator):
    """把当前选中对象的名字与顶点数写进 Info 编辑器"""

    bl_idname = "guide.report_selection"
    bl_label = "报告选中对象"
    bl_options = {"REGISTER", "UNDO"}

    @classmethod
    def poll(cls, context):
        return context.active_object is not None

    def execute(self, context):
        obj = context.active_object
        mesh = obj.data if obj.type == "MESH" else None
        verts = len(mesh.vertices) if mesh else 0
        self.report(
            {"INFO"},
            "对象 %s（类型 %s，顶点 %d）" % (obj.name, obj.type, verts),
        )
        return {"FINISHED"}


class GUIDE_PT_selection(Panel):
    """显示当前选中对象的基本信息"""

    bl_idname = "GUIDE_PT_selection"
    bl_label = "选中对象"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Guide"

    def draw(self, context):
        layout = self.layout
        obj = context.active_object
        if obj is None:
            layout.label(text="未选中对象", icon="INFO")
            return

        col = layout.column(align=True)
        col.label(text="名称：%s" % obj.name, icon="OBJECT_DATA")
        col.label(text="类型：%s" % obj.type)

        if obj.type == "MESH":
            box = layout.box()
            box.label(text="网格统计", icon="MESH_DATA")
            box.label(text="顶点 %d" % len(obj.data.vertices))
            box.label(text="边 %d" % len(obj.data.edges))
            box.label(text="面 %d" % len(obj.data.polygons))

        prefs = _get_prefs(context)
        if prefs and prefs.show_extra:
            layout.separator()
            layout.label(text="备注：%s" % prefs.note)


class GUIDE_AddonPreferences(AddonPreferences):
    bl_idname = __name__

    show_extra = bpy.props.BoolProperty(
        name="显示备注",
        description="在面板底部多显示一行备注",
        default=True,
    )
    note = StringProperty(
        name="备注文字",
        default="这一行由 AddonPreferences 提供",
    )
    max_verts = IntProperty(
        name="顶点预警阈值",
        default=100000,
        min=0,
    )

    def draw(self, context):
        layout = self.layout
        layout.prop(self, "show_extra")
        layout.prop(self, "note")
        layout.prop(self, "max_verts")


def _get_prefs(context):
    addon = context.preferences.addons.get(__name__)
    return addon.preferences if addon else None


_classes = (
    GUIDE_OT_report_selection,
    GUIDE_PT_selection,
    GUIDE_AddonPreferences,
)


def register():
    for cls in _classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
