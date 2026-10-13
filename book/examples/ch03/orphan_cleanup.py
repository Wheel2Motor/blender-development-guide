# SPDX-License-Identifier: GPL-2.0-or-later
"""Create an orphan mesh, then purge all orphan data-blocks.

Warning: ``orphans_purge`` removes every eligible orphan in the current file,
not only the mesh created by this example. Save important work before running.
"""

import bpy


mesh = bpy.data.meshes.new("BookDefinitelyOrphan")
print("清理前的网格数:", len(bpy.data.meshes), "新建:", mesh.name)
removed = bpy.data.orphans_purge(
    do_local_ids=True,
    do_linked_ids=True,
    do_recursive=True,
)
print("已删除 ID 数:", removed)
