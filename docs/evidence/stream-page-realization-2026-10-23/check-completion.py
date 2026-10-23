import json
from pathlib import Path
import sys

record = json.loads(Path(sys.argv[1]).read_text())
assert record["rows_requested"] == 2000000
assert record["cycles"], "no query cycle was recorded"
for cycle in record["cycles"]:
    assert cycle["terminal_status"] == "complete", f"cycle {cycle['cycle']} did not complete"
print(f"{len(record['cycles'])} two-million-row query cycles completed")
