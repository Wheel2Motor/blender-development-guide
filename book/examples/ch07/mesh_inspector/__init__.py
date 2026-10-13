# SPDX-License-Identifier: GPL-2.0-or-later
"""Mesh Inspector, the complete multi-file add-on from Chapter 7."""

bl_info = {
    "name": "Mesh Inspector",
    "author": "Blender Development Guide",
    "version": (1, 0, 0),
    "blender": (5, 2, 0),
    "location": "3D Viewport > Sidebar > Mesh Inspector",
    "description": "Inspect mesh geometry for common problems",
    "warning": "",
    "doc_url": "",
    "support": "COMMUNITY",
    "category": "Mesh",
}

if "bpy" in locals():
    import importlib

    from . import inspect, operators, prefs, properties, report, ui

    for module in (properties, prefs, inspect, report, operators, ui):
        importlib.reload(module)

import bpy

from . import inspect, operators, prefs, properties, report, ui


CLASSES = (
    properties.MSI_Finding,
    properties.MSI_ObjectSummary,
    properties.MSI_Result,
    prefs.MSI_Thresholds,
    prefs.MSI_Preferences,
    operators.MSI_OT_inspect,
    operators.MSI_OT_select_flagged,
    operators.MSI_OT_export_report,
    ui.MSI_UL_findings,
    ui.MSI_PT_main,
    ui.MSI_PT_settings,
)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)

    bpy.types.Scene.msi_result = bpy.props.PointerProperty(type=properties.MSI_Result)
    bpy.types.Object.msi_thresholds = bpy.props.PointerProperty(type=prefs.MSI_Thresholds)


def unregister():
    del bpy.types.Object.msi_thresholds
    del bpy.types.Scene.msi_result

    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
