import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

SOURCE = Path(__file__).resolve().parents[2] / "crates/app/tests/gtk_workbook.py"
spec = importlib.util.spec_from_file_location("workbook", SOURCE)
workbook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workbook)


def valid_cells():
    cells = {f"A{row}": ("n", str(row - 1)) for row in range(2, 102)}
    cells.update({f"{column}1": ("s", name) for column, name in zip("ABCDEFG", ["id", "note", "wide", "day", "clock", "stamp", "measure"])})
    cells.update({cell: ("s", value) for cell, value in {
        "B2": '=1+1 & "東京"', "C2": "9223372036854775807", "D2": "0000-01-01",
        "E2": "12:34:56.123456789", "F2": "2026-09-27 12:34:56.123456789", "C3": "-9223372036854775808", "G2": "inf",
        "D5": "+10000-01-01", "F5": "+10000-01-01 00:00:00",
    }.items()})
    cells.update({cell: ("n", value) for cell, value in {"D3": "1", "E3": "0.5", "F3": "1.5", "G3": "1.25"}.items()})
    return cells


class WorkbookOracleTests(unittest.TestCase):
    def test_scenarios_are_registered_in_the_default_ui_suite(self):
        scenarios = workbook.scenarios(object())
        self.assertEqual([item.__name__ for item in scenarios], [
            "current_page_workbook_preserves_typed_values", "cancelled_workbook_export_preserves_existing_file",
            "workbook_empty_text_shows_error_without_creating_file",
        ])
        self.assertTrue(all(item.environment == "local" for item in scenarios))
        self.assertIn("scenarios.extend(gtk_workbook.scenarios(sys.modules[__name__]))", SOURCE.with_name("gtk_safety.py").read_text())

    def test_parameter_scenarios_are_registered_in_the_default_ui_suite(self):
        source = SOURCE.with_name("gtk_parameters.py")
        spec = importlib.util.spec_from_file_location("parameters", source)
        parameters = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(parameters)
        scenarios = parameters.scenarios(object())
        self.assertEqual([item.__name__ for item in scenarios], [
            "repeated_parameters_preserve_wide_ids_and_sql_like_text",
            "cancelled_parameters_never_execute_and_retry_uses_new_values",
        ])
        self.assertTrue(all(item.environment == "local" for item in scenarios))
        self.assertIn("scenarios.extend(gtk_parameters.scenarios(sys.modules[__name__]))", SOURCE.with_name("gtk_safety.py").read_text())

    def test_exact_cells_pass(self):
        workbook.assert_workbook(valid_cells())

    def test_wrong_values_types_nulls_and_page_boundaries_fail(self):
        for cell, replacement in [
            ("C2", ("n", "9223372036854776000")), ("E2", ("s", "12:34:56")),
            ("F2", ("s", "2026-09-27 12:34:56.123456")), ("D3", ("s", "1900-01-01")),
            ("B4", ("s", "")), ("A102", ("n", "101")), ("A2", ("n", "2")), ("A2", ("s", "1")), ("G2", ("n", "0")),
        ]:
            cells = valid_cells()
            cells[cell] = replacement
            with self.subTest(cell=cell), self.assertRaises(AssertionError):
                workbook.assert_workbook(cells)

    def test_xml_reader_preserves_types_and_refuses_formulas(self):
        namespace = workbook.NS["s"]
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "fixture.xlsx"
            for formula in ["", "<f>1+1</f>"]:
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("xl/sharedStrings.xml", f'<sst xmlns="{namespace}"><si><t>=1+1 &amp; 東京</t></si></sst>')
                    archive.writestr("xl/worksheets/sheet1.xml", f'<worksheet xmlns="{namespace}"><sheetData><row><c r="A1" t="s">{formula}<v>0</v></c></row></sheetData></worksheet>')
                if formula:
                    with self.assertRaisesRegex(AssertionError, "formula"):
                        workbook.read_workbook(path)
                else:
                    self.assertEqual(workbook.read_workbook(path), {"A1": ("s", "=1+1 & 東京")})


if __name__ == "__main__":
    unittest.main()
