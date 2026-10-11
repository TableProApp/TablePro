from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from scripts.xlsx_roundtrip import _ods_cell, _xlsx_cell

EXPECTED = r'[0:1][-4:1]={{"NULL",""," leading","trailing ","東京","a,b"},{"a\"b","<tag>&","=1+1","slash\\path",NULL,"sibling"}}'
for name, reader in (
    ("source.xlsx", _xlsx_cell),
    ("calc-roundtrip.ods", _ods_cell),
    ("calc-roundtrip.xlsx", _xlsx_cell),
):
    actual = reader(Path(__file__).parent / name)
    assert actual == EXPECTED, f"{name}: {actual!r} != {EXPECTED!r}"
assert '"NULL"' in EXPECTED and ",NULL," in EXPECTED and '"=1+1"' in EXPECTED
print("LibreOffice Calc preserved enum[] shape, bounds, NULL distinctions, and string-cell text across XLSX/ODS/XLSX")
