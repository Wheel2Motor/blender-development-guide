# SPDX-License-Identifier: GPL-2.0-or-later
"""Print whether a Blender add-on is configured and currently loaded."""

import addon_utils


MODULE_NAME = "io_scene_gltf2"
loaded_default, loaded_state = addon_utils.check(MODULE_NAME)
print("偏好设置中启用:", loaded_default)
print("当前已加载:", loaded_state)
