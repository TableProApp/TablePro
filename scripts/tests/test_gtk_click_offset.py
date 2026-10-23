import ctypes
import importlib.util
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gtk_input", ROOT / "apps/linux/app/tests/gtk_input.py")
gtk_input = importlib.util.module_from_spec(SPEC)
with patch.dict(sys.modules, {"pyatspi": Mock()}):
    SPEC.loader.exec_module(gtk_input)


class GtkClickOffsetTests(unittest.TestCase):
    def offset(self, override=None):
        environment = {} if override is None else {"TABLEPRO_GTK_Y_OFFSET": override}
        with patch.dict(os.environ, environment, clear=True):
            return gtk_input.window_y_offset()

    def test_the_default_calibration_applies_without_an_override(self):
        self.assertEqual(self.offset(), 19)

    def test_explicit_calibration_takes_precedence_including_zero(self):
        self.assertEqual(self.offset("0"), 0)
        self.assertEqual(self.offset("7"), 7)



class GtkKeyboardWindowTests(unittest.TestCase):
    def test_a_tooltip_above_the_app_window_does_not_take_the_keys(self):
        self.assertEqual(gtk_input.keyboard_window([(5, 2, 0), (91, 2, 1)]), 5)

    def test_the_topmost_viewable_toplevel_is_chosen(self):
        self.assertEqual(gtk_input.keyboard_window([(5, 2, 0), (7, 2, 0), (9, 0, 0)]), 7)

    def test_no_viewable_toplevel_gives_none(self):
        self.assertIsNone(gtk_input.keyboard_window([(91, 2, 1), (9, 0, 0)]))


class GtkPointerWindowTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("gtk_ux", ROOT / "apps/linux/app/tests/gtk_ux.py")
        self.ui = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"gtk_input": gtk_input, "keyboard_paths": Mock()}):
            spec.loader.exec_module(self.ui)
        self.ui.ATSPI_WINDOW_Y_OFFSET = 19
        self.windows = (ctypes.c_ulong * 2)(5, 91)
        self.x11 = Mock()
        self.xtst = Mock()
        self.x11.XOpenDisplay.return_value = 1
        self.x11.XDefaultRootWindow.return_value = 1
        self.x11.XQueryTree.side_effect = self.query_tree
        self.x11.XGetWindowAttributes.side_effect = self.attributes

    def query_tree(self, display, root, root_return, parent, children, count):
        ctypes.cast(children, ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)))[0] = self.windows
        count._obj.value = 2
        return 1

    def attributes(self, display, window, attributes):
        attrs = attributes._obj
        attrs.map_state = 2
        attrs.width, attrs.height = 900, 700
        attrs.override_redirect = int(window == 91)
        attrs.x, attrs.y = (400, 300) if window == 91 else (100, 50)
        return 1

    def libraries(self, name):
        return self.xtst if name == "libXtst.so.6" else self.x11

    def test_resize_targets_the_application_below_a_large_popup(self):
        with patch.object(self.ui.ctypes, "CDLL", side_effect=self.libraries):
            self.ui.x11_resize_window(1000, 800)
        self.x11.XResizeWindow.assert_called_once_with(1, 5, 1000, 800)

    def test_click_uses_the_application_origin_below_a_large_popup(self):
        with patch.object(self.ui.ctypes, "CDLL", side_effect=self.libraries), \
             patch.object(gtk_input, "uses_atspi_input", return_value=False), \
             patch.object(self.ui.time, "sleep"):
            self.ui.x11_click(10, 20)
        self.xtst.XTestFakeMotionEvent.assert_called_once_with(1, -1, 110, 89, 0)
        self.xtst.XTestFakeButtonEvent.assert_any_call(1, 3, 1, 0)
        self.xtst.XTestFakeButtonEvent.assert_any_call(1, 3, 0, 0)


if __name__ == "__main__":
    unittest.main()
