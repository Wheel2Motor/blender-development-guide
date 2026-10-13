# SPDX-License-Identifier: GPL-2.0-or-later
"""Smoke-test the ``minimal_addon`` example inside Blender.

Install ``examples/ch04/my_addon`` first, then run:

    blender --background --factory-startup --python-exit-code 1 \
      --python addon_smoke_test.py
"""

import sys
import unittest

import addon_utils
from _bpy import ops as _ops


class TestAddonLifecycle(unittest.TestCase):
    module_name = "my_addon"

    def tearDown(self):
        addon_utils.disable(self.module_name, default_set=False)

    def test_enable_disable_twice(self):
        for _ in range(2):
            addon_utils.enable(self.module_name, default_set=False)
            _, loaded = addon_utils.check(self.module_name)
            self.assertTrue(loaded, "add-on 未成功启用")

            addon_utils.disable(self.module_name, default_set=False)
            _, loaded = addon_utils.check(self.module_name)
            self.assertFalse(loaded, "add-on 未成功卸载")

    def test_operator_registered(self):
        addon_utils.enable(self.module_name, default_set=False)
        self.assertIn("MY_ADDON_OT_hello", set(_ops.dir()))


if __name__ == "__main__":
    sys.argv = [__file__]
    unittest.main()
