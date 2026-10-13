# SPDX-License-Identifier: GPL-2.0-or-later
"""A minimal Blender render engine that produces a colored gradient.

Run this file in Blender's Text Editor, then select ``Gradient Example`` as the
scene render engine and render an image. The ``__main__`` guard registers the
engine when the file is executed as a script.
"""

bl_info = {
    "name": "Gradient Render Engine Example",
    "author": "Blender Development Guide",
    "version": (1, 0, 0),
    "blender": (5, 2, 0),
    "category": "Render",
}

import bpy
import numpy as np


class GradientRenderEngine(bpy.types.RenderEngine):
    bl_idname = "BOOK_GRADIENT"
    bl_label = "Gradient Example"
    bl_use_preview = False
    bl_use_postprocess = False

    def render(self, depsgraph):
        scene = depsgraph.scene
        scale = scene.render.resolution_percentage / 100.0
        width = max(1, int(scene.render.resolution_x * scale))
        height = max(1, int(scene.render.resolution_y * scale))

        rows_per_chunk = max(1, height // 20)
        for y in range(0, height, rows_per_chunk):
            chunk_height = min(rows_per_chunk, height - y)
            result = self.begin_result(0, y, width, chunk_height)
            render_pass = result.layers[0].passes["Combined"]

            pixels = np.empty((chunk_height, width, 4), dtype=np.float32)
            y_values = np.arange(y, y + chunk_height, dtype=np.float32)
            y_values /= max(1, height - 1)
            pixels[..., 0] = 0.1
            pixels[..., 1] = y_values[:, None]
            pixels[..., 2] = 0.6
            pixels[..., 3] = 1.0
            render_pass.rect = pixels.reshape(-1, 4).tolist()

            self.end_result(result)
            self.update_progress((y + chunk_height) / height)
            if self.test_break():
                return

    def view_update(self, context, depsgraph):
        pass


CLASSES = (GradientRenderEngine,)


def register():
    for cls in CLASSES:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(CLASSES):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
