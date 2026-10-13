# SPDX-License-Identifier: GPL-2.0-or-later

import bpy


class MSI_Thresholds(bpy.types.PropertyGroup):
    """Thresholds used globally or as a per-object override."""

    override: bpy.props.BoolProperty(name="Override Global Thresholds", default=False)
    degenerate_area: bpy.props.FloatProperty(
        name="Degenerate Face Area",
        default=1e-6,
        description="Faces below this area are reported as degenerate",
        min=0.0,
        soft_max=1e-3,
        precision=9,
    )
    max_non_manifold_edges: bpy.props.IntProperty(
        name="Max Non-Manifold Edges",
        default=0,
        description="Report an object above this number of non-manifold edges",
        min=0,
        soft_max=1000,
    )
    report_loose_edges: bpy.props.BoolProperty(
        name="Report Loose Edges",
        default=True,
        description="Report edges that are not connected to any face",
    )
    max_scale_deviation: bpy.props.FloatProperty(
        name="Max Scale Deviation",
        default=0.0001,
        description="Report non-uniform scale above this ratio",
        min=0.0,
        soft_max=0.1,
        precision=6,
    )


class MSI_Preferences(bpy.types.AddonPreferences):
    bl_idname = __package__

    thresholds: bpy.props.PointerProperty(type=MSI_Thresholds)

    def draw(self, context):
        layout = self.layout
        layout.use_property_split = True
        box = layout.box()
        box.label(text="Default Thresholds", icon="PREFERENCES")
        thresholds = self.thresholds
        box.prop(thresholds, "degenerate_area")
        box.prop(thresholds, "max_non_manifold_edges")
        box.prop(thresholds, "report_loose_edges")
        box.prop(thresholds, "max_scale_deviation")
