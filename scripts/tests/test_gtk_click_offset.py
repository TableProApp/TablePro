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


if __name__ == "__main__":
    unittest.main()
