import json
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
snapshots = [(float(t), int(n)) for t, n in re.findall(r"time=([^\n]+)\nmem_heap_B=(\d+)", source.read_text())]
assert snapshots and all(b[0] >= a[0] for a, b in zip(snapshots, snapshots[1:]))
windows = []
for start in [35, 70, 105, 140, 175]:
    values = [size for time, size in snapshots if start <= time < start + 5]
    assert values, f"missing observation window {start}"
    windows.append({"start_seconds": start, "end_seconds": start + 5, "minimum_live_heap_bytes": min(values)})
result = {"snapshots": len(snapshots), "final_seconds": snapshots[-1][0], "final_live_heap_bytes": snapshots[-1][1], "peak_live_heap_bytes": max(n for _, n in snapshots), "low_water_windows": windows}
print(json.dumps(result, indent=2))
