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
    def offset(self, distribution, override=None):
        environment = {} if override is None else {"TABLEPRO_GTK_Y_OFFSET": override}
        with patch.dict(os.environ, environment, clear=True):
            with patch.object(gtk_input.platform, "freedesktop_os_release", return_value=distribution):
                return gtk_input.window_y_offset()

    def test_ubuntu_24_matches_the_existing_distro_floor_calibration(self):
        self.assertEqual(self.offset({"ID": "ubuntu", "VERSION_ID": "24.04"}), 5)

    def test_other_stacks_keep_the_existing_default(self):
        for distribution in ({"ID": "arch"}, {"ID": "debian", "VERSION_ID": "13"}, {}):
            with self.subTest(distribution=distribution):
                self.assertEqual(self.offset(distribution), 19)

    def test_explicit_calibration_takes_precedence_including_zero(self):
        self.assertEqual(self.offset({"ID": "ubuntu", "VERSION_ID": "24.04"}, "0"), 0)
        self.assertEqual(self.offset({"ID": "arch"}, "7"), 7)

    def test_missing_distribution_metadata_keeps_the_existing_default(self):
        with patch.dict(os.environ, {}, clear=True):
            with patch.object(gtk_input.platform, "freedesktop_os_release", side_effect=OSError):
                self.assertEqual(gtk_input.window_y_offset(), 19)

class GtkOldAdwTests(unittest.TestCase):
    def old_adw(self, distribution, override=None):
        environment = {} if override is None else {"TABLEPRO_GTK_OLD_ADW": override}
        with patch.dict(os.environ, environment, clear=True):
            with patch.object(gtk_input.platform, "freedesktop_os_release", return_value=distribution):
                return gtk_input.uses_old_adw()

    def test_ubuntu_24_host_runs_use_the_old_dialog_handling_like_the_distro_floor(self):
        self.assertTrue(self.old_adw({"ID": "ubuntu", "VERSION_ID": "24.04"}))

    def test_other_stacks_wait_for_accessible_dialogs(self):
        for distribution in ({"ID": "arch"}, {"ID": "debian", "VERSION_ID": "13"}, {}):
            with self.subTest(distribution=distribution):
                self.assertFalse(self.old_adw(distribution))

    def test_an_explicit_setting_wins_either_way(self):
        self.assertFalse(self.old_adw({"ID": "ubuntu", "VERSION_ID": "24.04"}, "0"))
        self.assertTrue(self.old_adw({"ID": "arch"}, "1"))


if __name__ == "__main__":
    unittest.main()
