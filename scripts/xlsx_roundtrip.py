from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET

NS = {
    "x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
}


def _xlsx_cell(path):
    with ZipFile(path) as archive:
        sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        shared = (
            ET.fromstring(archive.read("xl/sharedStrings.xml"))
            if "xl/sharedStrings.xml" in archive.namelist()
            else None
        )
        assert sheet.find(".//x:f", NS) is None, ET.tostring(sheet)
        cell = sheet.find('.//x:c[@r="A2"]', NS)
        assert cell is not None and cell.get("t") in ("s", "inlineStr"), ET.tostring(sheet)
        if cell.get("t") == "inlineStr":
            return cell.findtext("x:is/x:t", namespaces=NS)
        index = int(cell.findtext("x:v", namespaces=NS))
        return "".join(shared.find(f"x:si[{index + 1}]", NS).itertext())


def _ods_cell(path):
    with ZipFile(path) as archive:
        root = ET.fromstring(archive.read("content.xml"))
        assert root.find('.//*[@table:formula]', NS) is None, ET.tostring(root)
        rows = root.findall(".//table:table-row", NS)
        cell = rows[1].find("table:table-cell", NS)
        assert cell is not None and cell.get(f'{{{NS["office"]}}}value-type') == "string"
        return "".join(cell.itertext())


def verify_xlsx_ods_xlsx(directory, expected, description):
    return verify_spreadsheet_roundtrip(
        directory, expected, description, "Gnumeric",
        "gnumeric-roundtrip.ods", "gnumeric-roundtrip.xlsx",
    )


def verify_spreadsheet_roundtrip(directory, expected, description, application, ods_filename, xlsx_filename):
    directory = Path(directory)
    for name, reader in (
        ("source.xlsx", _xlsx_cell),
        (ods_filename, _ods_cell),
        (xlsx_filename, _xlsx_cell),
    ):
        actual = reader(directory / name)
        assert actual == expected, f"{name}: {actual!r} != {expected!r}"
    assert '"=1+1"' in expected and ",NULL}" in expected
    return f"{application} preserved {description}, formula-shaped text, NULL distinctions, and string cells across XLSX/ODS/XLSX"
