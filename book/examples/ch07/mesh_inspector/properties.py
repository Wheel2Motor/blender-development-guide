# SPDX-License-Identifier: GPL-2.0-or-later

import bpy


class MSI_Finding(bpy.types.PropertyGroup):
    """One mesh-inspection finding."""

    object_name: bpy.props.StringProperty(name="Object", default="")
    check: bpy.props.StringProperty(name="Check", default="")
    severity: bpy.props.EnumProperty(
        name="Severity",
        default="WARNING",
        description="How serious this finding is",
        items=(
            ("INFO", "Info", "Informational, not necessarily a problem"),
            ("WARNING", "Warning", "Likely to cause trouble down the line"),
            ("ERROR", "Error", "Almost certainly broken geometry"),
        ),
    )
    count: bpy.props.IntProperty(name="Count", default=0, min=0)
    detail: bpy.props.StringProperty(name="Detail", default="")


class MSI_ObjectSummary(bpy.types.PropertyGroup):
    """Summary for one inspected object."""

    object_name: bpy.props.StringProperty(default="")
    face_count: bpy.props.IntProperty(default=0, min=0)
    vert_count: bpy.props.IntProperty(default=0, min=0)
    issue_total: bpy.props.IntProperty(default=0, min=0)


class MSI_Result(bpy.types.PropertyGroup):
    """Results of one inspection run, stored on a Scene."""

    findings: bpy.props.CollectionProperty(type=MSI_Finding)
    object_summaries: bpy.props.CollectionProperty(type=MSI_ObjectSummary)
    active_index: bpy.props.IntProperty(default=0, min=0)
    checked_objects: bpy.props.IntProperty(default=0, min=0)

    def add_summary(self, object_name, findings, *, face_count=0, vert_count=0):
        summary = self.object_summaries.add()
        summary.object_name = object_name
        summary.face_count = face_count
        summary.vert_count = vert_count
        summary.issue_total = sum(item.count for item in findings)
        return summary
