import concurrent.futures, glob, json, os, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replay

OUT = os.path.abspath(sys.argv[1])
LIMIT = int(sys.argv[2])
BUDGET = int(sys.argv[3])
MODULES = set(sys.argv[4].split(",")) if len(sys.argv) > 4 else None
WORK = "/tmp/replay"
os.makedirs(WORK, exist_ok=True)

batches = json.load(open(os.path.join(OUT, "long-batches.json")))
if MODULES:
    batches = [b for b in batches if b["module"] in MODULES]
jobs = []
seen = set()
for batch in batches:
    argv = replay.load_argv(batch["argv"])
    for path in replay.primaries(argv):
        if path not in seen:
            seen.add(path)
            jobs.append((batch, argv, path))
print("replaying %d primaries from %d batches, limit %ds, budget %ds" % (len(jobs), len(batches), LIMIT, BUDGET), flush=True)

started = time.time()
lock = threading.Lock()
results = []

def stats_summary(directory):
    best = []
    for path in glob.glob(os.path.join(directory, "*.json")):
        try:
            data = json.load(open(path))
        except ValueError:
            continue
        for key, value in data.items():
            if key.startswith("time.") and key.endswith(".wall") and isinstance(value, (int, float)) and value >= 1:
                best.append((value, key[5:-5]))
    return " ".join("%s=%.0fs" % (k, v) for v, k in sorted(best, reverse=True)[:6])

def one(job):
    batch, argv, path = job
    if time.time() - started > BUDGET:
        return None
    name = os.path.basename(path)
    base = os.path.join(WORK, "%s-%s" % (batch["module"], name))
    stats = base + ".stats"
    os.makedirs(stats, exist_ok=True)
    extra = ["-warn-long-function-bodies=400", "-warn-long-expression-type-checking=400", "-stats-output-dir", stats]
    seconds, status = replay.run_frontend(replay.single(argv, path, base + ".o", extra), LIMIT, base + ".err")
    text = open(base + ".err", errors="replace").read()
    slow = replay.long_bodies(text)[:3]
    detail = replay.error_tail(base + ".err", 300) if status not in ("ok", "TIMEOUT") else ""
    result = {"seconds": round(seconds, 1), "status": status, "module": batch["module"], "file": path,
              "batch_pid": batch["pid"], "batch_seconds": round(batch["duration"]), "long": slow,
              "phases": stats_summary(stats), "detail": detail}
    with lock:
        results.append(result)
        print("%6.1fs %-8s %-14s %-60s %s %s %s" % (seconds, status, batch["module"], name, result["phases"],
                                                  " ".join("%dms:%s" % s for s in slow), detail), flush=True)
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    list(pool.map(one, jobs))

results.sort(key=lambda r: -r["seconds"])
with open(os.path.join(OUT, "replay-results.json"), "w") as handle:
    json.dump(results, handle, indent=1)
print("\n== replayed primaries, slowest first (%d of %d done)" % (len(results), len(jobs)))
for r in results[:40]:
    print("%6.1fs %-8s %-14s %s  [batch %d lived %ds] %s" % (r["seconds"], r["status"], r["module"],
                                                          r["file"], r["batch_pid"], r["batch_seconds"], r["phases"]))
