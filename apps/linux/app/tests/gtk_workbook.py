from decimal import Decimal
import sqlite3
import time
import xml.etree.ElementTree as ET
import zipfile

NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def read_workbook(path):
    with zipfile.ZipFile(path) as archive:
        shared = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        strings = ["".join(node.itertext()) for node in shared.findall("s:si", NS)]
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
    assert not sheet.findall(".//s:f", NS), "exported data became a spreadsheet formula"
    cells = {}
    for cell in sheet.findall(".//s:c", NS):
        value = cell.find("s:v", NS)
        kind = cell.get("t", "n")
        text = value.text if value is not None else ""
        cells[cell.attrib["r"]] = (kind, strings[int(text)] if kind == "s" else text)
    return cells


def assert_workbook(cells):
    headers = ["id", "note", "wide", "day", "clock", "stamp", "measure"]
    for column, header in zip("ABCDEFG", headers):
        assert cells[f"{column}1"] == ("s", header), cells
    assert all(cells[f"A{row}"][0] == "n" for row in range(2, 102)), "row identifiers lost their numeric type"
    assert [Decimal(cells[f"A{row}"][1]) for row in range(2, 102)] == list(range(1, 101))
    assert "A102" not in cells, "export included a row outside the current page"
    for cell, expected in {
        "B2": '=1+1 & "東京"', "C2": "9223372036854775807", "D2": "0000-01-01",
        "E2": "12:34:56.123456789", "F2": "2026-09-27 12:34:56.123456789",
        "C3": "-9223372036854775808", "G2": "inf",
        "D5": "+10000-01-01", "F5": "+10000-01-01 00:00:00",
    }.items():
        assert cells[cell] == ("s", expected), (cell, cells.get(cell), expected)
    for cell, expected in {"D3": "1", "E3": "0.5", "F3": "1.5", "G3": "1.25"}.items():
        assert cells[cell][0] == "n" and Decimal(cells[cell][1]) == Decimal(expected), (cell, cells[cell])
    for column in "BCDEFG":
        assert f"{column}4" not in cells, (column, "NULL did not remain blank")


def seed_workbook(database):
    with sqlite3.connect(database) as connection:
        for column in ["wide INTEGER", "day DATE", "clock TIME", "stamp DATETIME", "measure REAL"]:
            connection.execute(f"ALTER TABLE safety_items ADD COLUMN {column}")
        connection.executemany("INSERT INTO safety_items(id) VALUES (?)", [(i,) for i in range(150, 0, -1)])
        connection.execute(
            "UPDATE safety_items SET note=?, wide=?, day=?, clock=?, stamp=? WHERE id=1",
            ('=1+1 & "東京"', 9223372036854775807, "0000-01-01", "12:34:56.123456789", "2026-09-27 12:34:56.123456789"),
        )
        connection.execute(
            "UPDATE safety_items SET wide=?, day=?, clock=?, stamp=? WHERE id=2",
            (-9223372036854775808, "1900-01-01", "12:00:00", "1900-01-01 12:00:00"),
        )
        connection.executemany("UPDATE safety_items SET measure=? WHERE id=?", [(float("inf"), 1), (1.25, 2)])
        connection.execute(
            "UPDATE safety_items SET day=?, stamp=? WHERE id=4",
            ("+10000-01-01", "+10000-01-01 00:00:00"),
        )


def choose_workbook(ui):
    ui.choose_export_format("Excel workbook", ["End"])


def database_rows(database):
    with sqlite3.connect(database) as connection:
        return connection.execute("SELECT * FROM safety_items ORDER BY id").fetchall()


def scenarios(ui):
    def current_page_workbook_preserves_typed_values(database, base):
        seed_workbook(database)
        before = database_rows(database)
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="Rows 1 – 100 of 150")
        choose_workbook(ui)
        export = base / "home" / "typed-page.xlsx"
        ui.set_visible_editable_within("Export Results", ui.FILE_CHOOSER_ROLES, str(export))
        ui.invoke(ui.wait_for_node(name="Save", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and not export.exists():
            time.sleep(ui.POLL_SECONDS)
        assert export.exists(), "workbook was not saved"
        assert_workbook(read_workbook(export))
        assert database_rows(database) == before, "export changed the source values"

    def cancelled_workbook_export_preserves_existing_file(database, base):
        seed_workbook(database)
        before = database_rows(database)
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="Rows 1 – 100 of 150")
        export = base / "home" / "keep.xlsx"
        export.write_bytes(b"existing file must survive")
        choose_workbook(ui)
        ui.set_visible_editable_within("Export Results", ui.FILE_CHOOSER_ROLES, str(export))
        ui.invoke(ui.wait_for_node(name="Cancel", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Export Results", role=ui.FILE_CHOOSER_ROLES, present=False)
        time.sleep(ui.SETTLE_SECONDS)
        assert export.read_bytes() == b"existing file must survive"
        assert sorted(path.name for path in (base / "home").glob("*.xlsx")) == ["keep.xlsx"]
        assert not list((base / "home").glob(".tablepro-export-*")), "cancel left a temporary export"
        assert database_rows(database) == before, "cancel changed the source values"

    def workbook_empty_text_shows_error_without_creating_file(database, base):
        seed_workbook(database)
        with sqlite3.connect(database) as connection:
            connection.execute("UPDATE safety_items SET note='' WHERE id=4")
        before = database_rows(database)
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="Rows 1 – 100 of 150")
        choose_workbook(ui)
        export = base / "home" / "refused.xlsx"
        ui.set_visible_editable_within("Export Results", ui.FILE_CHOOSER_ROLES, str(export))
        ui.invoke(ui.wait_for_node(name="Save", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Couldn't export")
        error = "Workbook export cannot preserve empty text at row 4, column 2. Export as CSV or JSON to keep empty text distinct from NULL"
        ui.wait_for_node(name=f"Writing {export} failed: {error}")
        assert not export.exists(), "lossy workbook was published"
        assert not list((base / "home").glob(".tablepro-export-*")), "failure left a temporary export"
        assert database_rows(database) == before, "failed export changed the source values"

    result = [current_page_workbook_preserves_typed_values, cancelled_workbook_export_preserves_existing_file,
              workbook_empty_text_shows_error_without_creating_file]
    for scenario in result:
        scenario.environment = "local"
    return result
