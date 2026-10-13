# SPDX-License-Identifier: GPL-2.0-or-later

import bpy

from . import inspect
from . import report as report_module


class MSI_OT_inspect(bpy.types.Operator):
    """Inspect mesh objects for common geometry problems."""

    bl_idname = "mesh_inspector.inspect"
    bl_label = "Inspect Meshes"
    bl_description = "Check mesh objects for common geometry problems"
    bl_options = {"REGISTER"}

    use_selection_only: bpy.props.BoolProperty(
        name="Selection Only",
        default=True,
        description="Inspect selected objects instead of every mesh in the scene",
    )
    clear_previous: bpy.props.BoolProperty(
        name="Clear Previous Results",
        default=True,
        description="Discard the results of the previous run before inspecting",
    )

    @classmethod
    def poll(cls, context):
        if context.mode != "OBJECT" or context.scene is None:
            return False
        return any(obj.type == "MESH" for obj in context.scene.objects)

    @staticmethod
    def _iter_targets(context, use_selection):
        candidates = context.selected_objects if use_selection else context.scene.objects
        for obj in candidates:
            if obj.type == "MESH" and obj.data is not None:
                yield obj

    def execute(self, context):
        result = context.scene.msi_result
        if self.clear_previous:
            result.findings.clear()
            result.object_summaries.clear()
            result.active_index = 0
            result.checked_objects = 0

        thresholds = context.preferences.addons[__package__].preferences.thresholds
        targets = list(self._iter_targets(context, self.use_selection_only))
        if not targets:
            self.report({"WARNING"}, "没有找到要检查的网格物体")
            return {"CANCELLED"}

        total_issues = 0
        for obj in targets:
            limits = obj.msi_thresholds if obj.msi_thresholds.override else thresholds
            object_findings = inspect.inspect_mesh(obj, limits)

            for finding in object_findings:
                item = result.findings.add()
                item.object_name = obj.name
                item.check = finding.check
                item.severity = finding.severity
                item.count = finding.count
                item.detail = finding.detail

            result.add_summary(
                obj.name,
                object_findings,
                face_count=len(obj.data.polygons),
                vert_count=len(obj.data.vertices),
            )
            result.checked_objects += 1
            total_issues += sum(finding.count for finding in object_findings)

        if total_issues == 0:
            self.report({"INFO"}, f"检查完成：{len(targets)} 个物体，未发现问题")
        else:
            self.report(
                {"WARNING"},
                f"检查完成：{len(targets)} 个物体，发现 {total_issues} 处问题",
            )
        return {"FINISHED"}


class MSI_OT_select_flagged(bpy.types.Operator):
    """Select objects that had inspection findings."""

    bl_idname = "mesh_inspector.select_flagged"
    bl_label = "Select Flagged Objects"
    bl_options = {"REGISTER", "UNDO"}

    deselect_others: bpy.props.BoolProperty(
        name="Deselect Others",
        description="Deselect everything else before selecting flagged objects",
        default=True,
    )

    @classmethod
    def poll(cls, context):
        result = getattr(context.scene, "msi_result", None)
        return bool(result is not None and result.object_summaries)

    def invoke(self, context, event):
        if context.scene.msi_result.checked_objects == 0:
            self.report({"ERROR"}, "还没有检查结果，请先执行一次检查")
            return {"CANCELLED"}
        return self.execute(context)

    def execute(self, context):
        result = context.scene.msi_result
        if self.deselect_others:
            for obj in context.view_layer.objects:
                obj.select_set(False)

        selected = 0
        first = None
        for summary in result.object_summaries:
            if summary.issue_total == 0:
                continue
            obj = context.scene.objects.get(summary.object_name)
            if obj is None:
                continue
            obj.select_set(True)
            if first is None:
                first = obj
            selected += 1

        if selected == 0:
            self.report({"INFO"}, "没有需要选中的物体")
            return {"CANCELLED"}

        context.view_layer.objects.active = first
        self.report({"INFO"}, f"已选中 {selected} 个有问题的物体")
        return {"FINISHED"}


class MSI_OT_export_report(bpy.types.Operator):
    """Export the latest inspection result as UTF-8 text."""

    bl_idname = "mesh_inspector.export_report"
    bl_label = "Export Inspection Report"
    bl_options = {"REGISTER"}

    filepath: bpy.props.StringProperty(
        name="Report File",
        subtype="FILE_PATH",
        description="Where to write the report",
    )
    use_timestamp_dir: bpy.props.BoolProperty(
        name="Use Timestamp Sub-folder",
        default=False,
        description="Write into a sub-folder named after the current run",
    )

    @classmethod
    def poll(cls, context):
        result = getattr(context.scene, "msi_result", None)
        return bool(result is not None and result.findings)

    def invoke(self, context, event):
        if not self.filepath:
            self.filepath = report_module.default_report_name(context.scene)
        context.window_manager.fileselect_add(self)
        return {"RUNNING_MODAL"}

    def execute(self, context):
        text = report_module.build_report(context.scene)
        try:
            written = report_module.write_report(
                self.filepath,
                text,
                use_timestamp_dir=self.use_timestamp_dir,
            )
        except OSError as exc:
            self.report({"ERROR"}, f"写入失败：{exc}")
            return {"CANCELLED"}

        self.report({"INFO"}, f"报告已写入 {written}")
        return {"FINISHED"}
