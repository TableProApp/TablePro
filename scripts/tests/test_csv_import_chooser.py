import importlib.util
from contextlib import closing, contextmanager
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[2]


class FileChosen(Exception):
    pass


class CsvImportChooserTests(unittest.TestCase):
    def test_import_activates_each_native_chooser_location_before_open(self):
        for chooser_role in ("dialog", "file chooser"):
            with self.subTest(role=chooser_role), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                database = root / "test.sqlite"
                with closing(sqlite3.connect(database)) as connection:
                    connection.execute("CREATE TABLE safety_items(id INTEGER PRIMARY KEY, note TEXT)")
                    connection.execute("CREATE TABLE other_items(id INTEGER PRIMARY KEY, note TEXT)")
                ui = MagicMock()
                ui.pyatspi = SimpleNamespace(
                    ROLE_DIALOG="dialog", ROLE_FILE_CHOOSER="file chooser", ROLE_LIST_ITEM="list item",
                    ROLE_LABEL="label", ROLE_PAGE_TAB="page tab", ROLE_PUSH_BUTTON="button",
                    STATE_SENSITIVE="sensitive", WINDOW_COORDS=0,
                )
                ui.WAIT_SECONDS = 1
                ui.FILE_CHOOSER_ROLES = ("file chooser", "dialog")
                node = MagicMock()
                node.queryComponent.return_value.getExtents.return_value = SimpleNamespace(x=0, y=0, width=20, height=20)
                node.queryAction.return_value.nActions = 1
                node.queryAction.return_value.getName.return_value = "sidebar-row.import-csv"

                location = object()
                open_button = MagicMock()
                open_button.getState.return_value.contains.return_value = True
                location_activated = False

                def invoke(target):
                    nonlocal location_activated
                    if target is location:
                        location_activated = True
                    if target is open_button:
                        self.assertTrue(location_activated)
                        raise FileChosen()

                ui.invoke.side_effect = invoke
                ui.wait_within.return_value = open_button

                def wait(name=None, role=None, **_kwargs):
                    if name == "Import CSV":
                        roles = role if isinstance(role, tuple) else (role,)
                        if chooser_role not in roles:
                            raise AssertionError("the native chooser was not recognized")
                    return open_button if name == "Open" else node

                def enter_file(title, roles, path, **_kwargs):
                    self.assertEqual(title, "Import CSV")
                    self.assertIn(chooser_role, roles)
                    self.assertTrue(Path(path).is_file())
                    return location

                ui.wait_for_node.side_effect = wait
                ui.set_visible_editable_within.side_effect = enter_file
                spec = importlib.util.spec_from_file_location("csv_refresh", ROOT / "apps/linux/app/tests/gtk_csv_refresh.py")
                module = importlib.util.module_from_spec(spec)
                with patch.dict(sys.modules, {"gtk_ux": SimpleNamespace(x11_click=lambda *_args, **_kwargs: None)}):
                    spec.loader.exec_module(module)
                connect = sqlite3.connect

                @contextmanager
                def connection_context(path):
                    with closing(connect(path)) as connection, connection:
                        yield connection

                scenario = module.scenarios(ui)[0]
                with (
                    patch.object(module.sqlite3, "connect", connection_context),
                    patch.object(module.time, "sleep"),
                    self.assertRaises(FileChosen),
                ):
                    scenario(database, root)


if __name__ == "__main__":
    unittest.main()
