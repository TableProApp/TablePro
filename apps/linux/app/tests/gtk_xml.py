import sqlite3
import time
import xml.etree.ElementTree as ET

TEXT = "a\rb\r\nc\n\t&#13; <tag> & \"quotes\" 東京 😀"


def assert_xml(root):
    assert root.tag == "rows" and len(root) == 3, ET.tostring(root)
    assert [row.findtext("id") for row in root] == ["1", "2", "3"]
    assert root[0].find("note").attrib == {}
    assert root[0].findtext("note") == TEXT, repr(root[0].findtext("note"))
    assert root[1].find("note").attrib == {} and root[1].findtext("note") == ""
    assert root[2].find("note").attrib == {"null": "true"} and root[2].findtext("note") == ""


def rows(database):
    with sqlite3.connect(database) as connection:
        return connection.execute("SELECT id, note FROM safety_items ORDER BY id").fetchall()


def save_xml(ui, base, name):
    ui.invoke_named_action_within("safety_items", "Open safety_items")
    ui.wait_for_node(name="Rows 1 – 3 of 3")
    ui.choose_export_format("XML", ["End", "Up", "Up"])
    export = base / "home" / name
    ui.set_visible_editable_within("Export Results", ui.FILE_CHOOSER_ROLES, str(export))
    ui.invoke(ui.wait_for_node(name="Save", role=ui.pyatspi.ROLE_PUSH_BUTTON))
    return export


def seed(database):
    with sqlite3.connect(database) as connection:
        connection.executemany("INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, TEXT), (2, ""), (3, None)])


def scenarios(ui):
    def xml_export_preserves_line_endings_and_null_distinctions(database, base):
        seed(database)
        before = rows(database)
        export = save_xml(ui, base, "exact.xml")
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and not export.exists():
            time.sleep(ui.POLL_SECONDS)
        assert export.exists(), "XML was not saved"
        assert_xml(ET.parse(export).getroot())
        assert rows(database) == before, "export changed source data"

    def xml_export_refuses_illegal_text_without_publishing(database, base):
        seed(database)
        with sqlite3.connect(database) as connection:
            connection.execute("UPDATE safety_items SET note=? WHERE id=2", ("before\0after",))
        before = rows(database)
        export = save_xml(ui, base, "refused.xml")
        ui.wait_for_node(name="Couldn't export")
        error = "XML 1.0 cannot preserve U+0000 at row 2, column 2. Export as JSON to keep the original text"
        ui.wait_for_node(name=f"Writing {export} failed: {error}")
        assert not export.exists(), "lossy XML was published"
        assert not list((base / "home").glob(".tablepro-export-*")), "failure left a temporary export"
        assert rows(database) == before, "failed export changed source data"

    result = [xml_export_preserves_line_endings_and_null_distinctions,
              xml_export_refuses_illegal_text_without_publishing]
    for scenario in result:
        scenario.environment = "local"
    return result
