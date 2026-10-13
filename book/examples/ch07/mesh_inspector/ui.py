# SPDX-License-Identifier: GPL-2.0-or-later

import bpy

from . import operators


class MSI_PT_main(bpy.types.Panel):
    """Run the inspector and browse its findings."""

    bl_label = "Mesh Inspector"
    bl_idname = "MSI_PT_main"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "Mesh Inspector"

    @classmethod
    def poll(cls, context):
        return context.mode == "OBJECT"

    def draw(self, context):
        layout = self.layout
        result = context.scene.msi_result

        column = layout.column(align=True)
        operation = column.operator(
            operators.MSI_OT_inspect.bl_idname,
            text="Inspect",
            icon="CHECKMARK",
        )
        operation.use_selection_only = True
        operation.clear_previous = True

        row = column.row(align=True)
        row.operator(
            operators.MSI_OT_select_flagged.bl_idname,
            text="Select Flagged",
            icon="RESTRICT_SELECT_OFF",
        )
        export = row.operator(
            operators.MSI_OT_export_report.bl_idname,
            text="Export Report",
            icon="FILE_TICK",
        )
        export.use_timestamp_dir = False
        column.separator()

        if result.checked_objects == 0:
            column.label(text="还没有检查结果。", icon="INFO")
            return

        column.label(
            text=(
                f"已检查 {result.checked_objects} 个物体，"
                f"{len(result.findings)} 类问题"
            ),
            icon="MESH_DATA",
        )
        column.template_list(
            "MSI_UL_findings",
            "",
            result,
            "findings",
            result,
            "active_index",
            rows=5,
        )


class MSI_PT_settings(bpy.types.Panel):
    """Edit per-object threshold overrides."""

    bl_label = "Per-Object Thresholds"
    bl_idname = "MSI_PT_settings"
    bl_space_type = "PROPERTIES"
    bl_region_type = "WINDOW"
    bl_context = "object"
    bl_options = {"DEFAULT_CLOSED"}

    @classmethod
    def poll(cls, context):
        obj = context.object
        return bool(obj is not None and obj.type == "MESH")

    def draw(self, context):
        layout = self.layout
        layout.use_property_split = True
        thresholds = context.object.msi_thresholds
        layout.prop(thresholds, "override")
        column = layout.column()
        column.enabled = thresholds.override
        column.prop(thresholds, "degenerate_area")
        column.prop(thresholds, "max_non_manifold_edges")
        column.prop(thresholds, "report_loose_edges")
        column.prop(thresholds, "max_scale_deviation")


class MSI_UL_findings(bpy.types.UIList):
    """Display one row for each finding."""

    ICONS = {"INFO": "INFO", "WARNING": "ERROR", "ERROR": "CANCEL"}

    def draw_item(
        self,
        context,
        layout,
        data,
        item,
        icon,
        active_data,
        active_propname,
        index=0,
    ):
        row = layout.row(align=True)
        row.label(text=item.object_name, translate=False)
        row.label(text=item.check, translate=False)
        row.label(text=str(item.count))
        row.label(text="", icon=self.ICONS.get(item.severity, "INFO"))
