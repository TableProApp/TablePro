import concurrent.futures, glob, json, os, re, shutil, subprocess, sys, time

OUT = os.path.abspath(sys.argv[1])
ROOT = os.path.abspath(sys.argv[2])
BACKUP = os.path.abspath(sys.argv[3])
LIMIT = int(sys.argv[4]) if len(sys.argv) > 4 else 1500
OUTPUT_OPTIONS = {"-emit-module-doc-path", "-emit-module-source-info-path", "-emit-objc-header-path",
                  "-serialize-diagnostics-path", "-emit-dependencies-path", "-emit-abi-descriptor-path", "-o",
                  "-emit-api-descriptor-path", "-emit-const-values-path", "-emit-module-summary-path"}

records = json.load(open(os.path.join(OUT, "procs.json")))
emit = [r for r in records if r["module"] == "TableProTests" and r["mode"] == "-emit-module" and r.get("argv")]
if not emit:
    sys.exit("no TableProTests emit-module command line was captured")
argv = [l.rstrip("\n") for l in open(emit[0]["argv"])]
print("emit-module lived %ds in the build" % (emit[0]["last"] - emit[0]["first"]), flush=True)

def original_of(path):
    if not path.startswith(ROOT + "/"):
        return path
    backup = BACKUP + path[len(ROOT):]
    if os.path.exists(backup) and open(backup).read() != open(path).read():
        return backup
    return path

def command(label, swap):
    work = os.path.join("/tmp/emit-ab", label)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    args, skip = [], False
    for a in argv:
        if skip:
            skip = False
            continue
        if a in OUTPUT_OPTIONS:
            skip = True
            continue
        if a == "-cache-compile-job":
            continue
        args.append(original_of(a) if swap else a)
    swapped = sum(1 for a, b in zip([x for x in argv if x.endswith(".swift")], [original_of(x) for x in argv if x.endswith(".swift")]) if a != b)
    return args + ["-o", os.path.join(work, "TableProTests.swiftmodule"), "-stats-output-dir", work], work, swapped

def run(label, swap):
    args, work, swapped = command(label, swap)
    start = time.time()
    with open(os.path.join(work, "stderr.txt"), "wb") as err:
        try:
            code = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=err, timeout=LIMIT).returncode
            status = "ok" if code == 0 else "exit %d" % code
        except subprocess.TimeoutExpired:
            status = "TIMEOUT"
    seconds = time.time() - start
    timers = []
    for path in glob.glob(os.path.join(work, "*.json")):
        data = json.load(open(path))
        timers = sorted(((v, k[5:-5]) for k, v in data.items() if k.startswith("time.swift.") and k.endswith(".wall") and v >= 1), reverse=True)[:8]
    detail = ""
    if status != "ok":
        text = open(os.path.join(work, "stderr.txt"), errors="replace").read()
        detail = " | ".join(dict.fromkeys(re.findall(r"error: [^\"\\]{0,200}", text)))[:800] or text[-800:]
    return "%7.1fs %-8s %-12s swapped=%d %s %s" % (seconds, status, label, swapped if swap else 0,
                                                  " ".join("%s=%.0fs" % (k, v) for v, k in timers), detail)

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    for line in pool.map(lambda pair: run(*pair), [("fixed", False), ("original", True)]):
        print(line, flush=True)
