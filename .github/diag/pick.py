import json, os, statistics, sys

OUT = sys.argv[1]
results = json.load(open(os.path.join(OUT, "replay-results-TablePro.json")))
batches = {b["pid"]: b for b in json.load(open(os.path.join(OUT, "long-batches.json")))}
fine = [r["seconds"] for r in results if r["status"] == "ok"]
median = statistics.median(fine) if fine else 30
threshold = max(120, 4 * median)
slow = [r for r in results if r["status"] == "TIMEOUT" or (r["status"] == "ok" and r["seconds"] > threshold)]
slow.sort(key=lambda r: (r["status"] != "TIMEOUT", -r["seconds"]))
fast = sorted((r for r in results if r["status"] == "ok"), key=lambda r: r["seconds"])
for r in slow[:2]:
    argv = batches[r["batch_pid"]]["argv"]
    probe = next((f["file"] for f in fast if f["file"] != r["file"] and f["batch_pid"] == r["batch_pid"]),
                 next((f["file"] for f in fast if f["file"] != r["file"]), r["file"]))
    print("\t".join([r["file"], argv, probe, str(int(r["seconds"])), r["status"]]))
sys.stderr.write("median %.1fs threshold %.0fs slow %d\n" % (median, threshold, len(slow)))
