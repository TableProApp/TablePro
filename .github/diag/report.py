import collections, json, os, re, sys, time

OUT = os.path.abspath(sys.argv[1])
THRESHOLD = int(sys.argv[2]) if len(sys.argv) > 2 else 120
REPLAY_THRESHOLD = int(sys.argv[3]) if len(sys.argv) > 3 else 150
records = json.load(open(os.path.join(OUT, "procs.json")))

def hms(t):
    return time.strftime("%H:%M:%S", time.gmtime(t))

for r in records:
    r["duration"] = r["last"] - r["first"]

print("== frontends per module (count, summed lifetime, first start, last end, longest)")
by_module = collections.defaultdict(list)
for r in records:
    by_module[(r["module"], r["mode"])].append(r)
rows = []
for (module, mode), items in by_module.items():
    rows.append((sum(i["duration"] for i in items), module, mode, len(items), min(i["first"] for i in items),
                 max(i["last"] for i in items), max(i["duration"] for i in items)))
for total, module, mode, count, first, last, longest in sorted(rows, reverse=True)[:30]:
    print("%-34s %-16s n=%-4d sum=%6ds  %s -> %s  longest=%5ds" % (module, mode, count, total, hms(first), hms(last), longest))

print("\n== frontends alive longer than %d s (UTC, 5 s sampling)" % THRESHOLD)
long_ones = sorted((r for r in records if r["duration"] > THRESHOLD), key=lambda r: -r["duration"])
for r in long_ones:
    print("%5ds %s -> %s pid=%-6d %-22s %-14s prim=%-3d peakRSS=%5dM argv=%s" % (
        r["duration"], hms(r["first"]), hms(r["last"]), r["pid"], r["module"], r["mode"], len(r["primaries"]),
        r["rss"] // 1024, "yes" if r.get("argv") else r.get("capture_error", "no")))
    if r["primaries"]:
        print("        " + " ".join(r["primaries"])[:900])

with open(os.path.join(OUT, "long-batches.json"), "w") as handle:
    json.dump([r for r in long_ones if r["mode"] == "-c" and r.get("argv") and r["duration"] > REPLAY_THRESHOLD], handle)

print("\n== memory (min free, max compressed, swapouts delta, pressure levels)")
lines = open(os.path.join(OUT, "memory.txt")).read().splitlines()
free = [int(m) for m in re.findall(r"free=(\d+)M", "\n".join(lines))]
compressed = [int(m) for m in re.findall(r"compressed=(\d+)M", "\n".join(lines))]
swapouts = [int(m) for m in re.findall(r"swapouts=(\d+)", "\n".join(lines))]
levels = collections.Counter(re.findall(r"\| (\d) \|", "\n".join(lines)))
swap_used = re.findall(r"used = ([\d.]+)M", "\n".join(lines))
if free:
    print("samples=%d minFree=%dM maxCompressed=%dM swapouts %d -> %d maxSwapUsed=%sM pressureLevels=%s" % (
        len(lines), min(free), max(compressed), swapouts[0], swapouts[-1], max(swap_used, key=float) if swap_used else "?",
        dict(levels)))
