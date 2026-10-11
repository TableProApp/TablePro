from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from scripts.xlsx_roundtrip import verify_xlsx_ods_xlsx

EXPECTED = '{"NULL","","東京","a,b","a\\"b","<tag>&","=1+1","slash\\\\path",NULL}'
print(verify_xlsx_ods_xlsx(Path(__file__).parent, EXPECTED, "custom enum-array text"))
