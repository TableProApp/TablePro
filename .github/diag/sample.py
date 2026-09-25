import hashlib, json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replay

OUT = os.path.abspath(sys.argv[1])
DONE = os.path.join(OUT, "build.done")
for sub in ("argv", "files", "stacks"):
    os.makedirs(os.path.join(OUT, sub), exist_ok=True)

SNAPSHOT_OPTIONS = {"-filelist", "-primary-filelist", "-supplementary-output-file-map", "-output-filelist",
                    "-explicit-swift-module-map-file"}
TEMP_ROOTS = tuple(p for p in {"/var/folders", "/private/var/folders", os.environ.get("TMPDIR", "/nonexistent")} if p)
MODES = ("-c", "-emit-module", "-scan-dependencies", "-compile-module-from-interface", "-emit-pcm", "-typecheck",
         "-merge-modules", "-emit-sil", "-dump-pcm")

procs = {}
records = []
timeline = open(os.path.join(OUT, "timeline.txt"), "a", buffering=1)
memory = open(os.path.join(OUT, "memory.txt"), "a", buffering=1)
stack_log = open(os.path.join(OUT, "stacks.txt"), "a", buffering=1)

def clock():
    return time.strftime("%H:%M:%S")

def snapshot(path):
    data = open(path, "rb").read()
    digest = hashlib.sha1(data).hexdigest()[:12]
    target = os.path.join(OUT, "files", digest + "-" + os.path.basename(path))
    if not os.path.exists(target):
        with open(target, "wb") as handle:
            handle.write(data)
    return target

def expand_responses(argv):
    out = []
    for a in argv:
        if a.startswith("@") and os.path.isfile(a[1:]):
            out += [l.rstrip("\n").strip('"') for l in open(a[1:]) if l.strip()]
        else:
            out.append(a)
    return out

def capture(pid):
    argv = expand_responses(replay.argv_of(pid))
    rewritten = []
    for i, a in enumerate(argv):
        previous = argv[i - 1] if i else ""
        wants = previous in SNAPSHOT_OPTIONS or a.startswith(TEMP_ROOTS)
        if wants and os.path.isfile(a):
            try:
                rewritten.append(snapshot(a))
                continue
            except OSError:
                pass
        rewritten.append(a)
    return argv, rewritten

def describe(pid, command):
    record = {"pid": pid, "first": time.time(), "last": time.time(), "rss": 0, "module": "?", "mode": "?",
              "primaries": [], "argv": None}
    tokens = command.split()
    if "-module-name" in tokens:
        record["module"] = tokens[tokens.index("-module-name") + 1]
    for mode in MODES:
        if mode in tokens:
            record["mode"] = mode
            break
    try:
        argv, rewritten = capture(pid)
        path = os.path.join(OUT, "argv", "%d-%s.txt" % (pid, record["module"]))
        with open(path, "w") as handle:
            handle.write("\n".join(rewritten) + "\n")
        record["argv"] = path
        record["primaries"] = [os.path.basename(p) for p in replay.primaries(rewritten)]
        record["primary_paths"] = replay.primaries(rewritten)
    except Exception as error:
        record["capture_error"] = str(error)[:200]
    return record

def frontends():
    listing = subprocess.run(["ps", "-axww", "-o", "pid=,rss=,pcpu=,command="], capture_output=True, text=True).stdout
    found = []
    for line in listing.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        pid, rss, cpu, command = parts
        if "swift-frontend" in command.split(" ", 1)[0] and " -frontend " in command:
            found.append((int(pid), int(rss), float(cpu), command))
    return found

def top_processes():
    listing = subprocess.run(["ps", "-axo", "pid=,pcpu=,rss=,comm=", "-r"], capture_output=True, text=True).stdout
    rows = []
    for line in listing.splitlines()[:6]:
        parts = line.split(None, 3)
        if len(parts) == 4:
            rows.append("%s:%s%%:%dM" % (os.path.basename(parts[3]), parts[1], int(parts[2]) // 1024))
    return " ".join(rows)

def memory_line():
    vm = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    fields = {}
    header = vm.splitlines()[0] if vm else ""
    page = int(header.split("page size of ")[1].split()[0]) if "page size of " in header else 16384
    for line in vm.splitlines()[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            try:
                fields[key.strip()] = int(value.strip().rstrip("."))
            except ValueError:
                pass
    def mb(key):
        return fields.get(key, 0) * page // (1024 * 1024)
    sysctl = subprocess.run(["sysctl", "-n", "vm.swapusage", "kern.memorystatus_vm_pressure_level", "vm.loadavg"],
                            capture_output=True, text=True).stdout.replace("\n", " | ")
    return "%s free=%dM active=%dM inactive=%dM wired=%dM compressed=%dM swapins=%d swapouts=%d | %s" % (
        clock(), mb("Pages free"), mb("Pages active"), mb("Pages inactive"), mb("Pages wired down"),
        mb("Pages occupied by compressor"), fields.get("Swapins", 0), fields.get("Swapouts", 0), sysctl)

def take_stack(record, age):
    target = os.path.join(OUT, "stacks", "%d-%s-%ds.txt" % (record["pid"], record["module"], age))
    subprocess.Popen(["sudo", "-n", "sample", str(record["pid"]), "3", "-mayDie", "-file", target],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stack_log.write("%s stack %s pid %d age %ds -> %s\n" % (clock(), record["module"], record["pid"], age, target))

def save():
    with open(os.path.join(OUT, "procs.json.tmp"), "w") as handle:
        json.dump(records, handle)
    os.replace(os.path.join(OUT, "procs.json.tmp"), os.path.join(OUT, "procs.json"))

tick = 0
while not os.path.exists(DONE):
    now = time.time()
    alive = frontends()
    for pid, rss, cpu, command in alive:
        record = procs.get(pid)
        if record is None or now - record["last"] > 30:
            record = describe(pid, command)
            procs[pid] = record
            records.append(record)
        record["last"] = now
        record["rss"] = max(record["rss"], rss)
        age = int(now - record["first"])
        tier = age // 150
        if tier >= 1 and tier > record.get("stack_tier", 0):
            record["stack_tier"] = tier
            take_stack(record, age)
    if tick % 2 == 0:
        busy = ["%s/%s:%dp:%ds:%dM" % (procs[p]["module"], procs[p]["mode"], len(procs[p]["primaries"]),
                                       int(now - procs[p]["first"]), procs[p]["rss"] // 1024) for p, _, _, _ in alive]
        timeline.write("%s frontends=%d [%s] top: %s\n" % (clock(), len(alive), " ".join(busy), top_processes()))
    if tick % 6 == 0:
        memory.write(memory_line() + "\n")
        save()
    tick += 1
    time.sleep(5)
save()
