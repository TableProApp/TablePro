import argparse, concurrent.futures, os, re, shutil, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replay, stubber

parser = argparse.ArgumentParser()
parser.add_argument("argv")
parser.add_argument("target")
parser.add_argument("--work", default="/tmp/bisect")
parser.add_argument("--nocache", action="store_true")
parser.add_argument("--probe", help="a fast primary of the same module, compiled from a copy to prove the swap works")
parser.add_argument("--control", type=int, default=0, help="also time the unmodified file from a copy, with this limit")
parser.add_argument("--min-limit", type=int, default=120)
parser.add_argument("--groups", type=int, default=6)
parser.add_argument("--workers", type=int, default=3)
parser.add_argument("--source", help="read the file's text from here instead of the module input")
args = parser.parse_args()

argv = replay.load_argv(args.argv)
if args.nocache:
    argv = replay.without_cache(argv)
def module_input(suffix):
    listing = replay.option(argv, "-filelist")
    inputs = replay.load_argv(listing) if listing else [a for a in argv if a.endswith(".swift")]
    matches = [i for i in inputs if i == suffix or i.endswith("/" + suffix.lstrip("/"))]
    if len(matches) != 1:
        sys.exit("cannot resolve %s among the module inputs: %s" % (suffix, matches[:5]))
    return matches[0]

target = module_input(args.target)
if args.probe:
    args.probe = module_input(args.probe)
source = open(args.source or target).read()
bodies = stubber.find_bodies(source)
print("target %s: %d stubbable bodies" % (target, len(bodies)), flush=True)
shutil.rmtree(args.work, ignore_errors=True)
os.makedirs(args.work)

def render(stubbed, overrides=None):
    overrides = overrides or {}
    out = source
    for index in sorted(set(stubbed) | set(overrides), key=lambda i: -bodies[i].start):
        body = bodies[index]
        inner = overrides.get(index, stubber.stubbed_inner(source, body))
        out = out[:body.start + 1] + inner + out[body.end:]
    return out

FAKE_HOT = os.environ.get("DIAG_FAKE_HOT_MARKER")

def compile_variant(label, text, limit, path=None):
    if FAKE_HOT and FAKE_HOT in text and label != "control-original":
        return float(limit), "TIMEOUT", ""
    directory = os.path.join(args.work, label)
    os.makedirs(directory, exist_ok=True)
    original = path or target
    variant = os.path.join(directory, os.path.basename(original))
    with open(variant, "w") as handle:
        handle.write(text)
    swapped = replay.swap_source(argv, original, variant, directory)
    command = replay.single(swapped, variant, os.path.join(directory, "out.o"))
    seconds, status = replay.run_frontend(command, limit, os.path.join(directory, "stderr.txt"))
    detail = "" if status in ("ok", "TIMEOUT") else replay.error_tail(os.path.join(directory, "stderr.txt"), 700)
    return seconds, status, detail

def report(label, result, extra=""):
    seconds, status, detail = result
    print("%7.1fs %-8s %-44s %s %s" % (seconds, status, label, extra, detail), flush=True)

pool = concurrent.futures.ThreadPoolExecutor(max_workers=args.workers)
control = None
if args.control:
    control_pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    control = control_pool.submit(compile_variant, "control-original", source, args.control)

if args.probe:
    probe_path = args.probe
    result = compile_variant("probe-copy", open(probe_path).read(), 600, probe_path)
    report("probe-copy " + os.path.basename(probe_path), result)
    if result[1] != "ok":
        print("PROBE FAILED: compiling a copied source does not work with this command line", flush=True)
        sys.exit(3)

def error_lines(label):
    text = open(os.path.join(args.work, label, "stderr.txt"), errors="replace").read()
    name = re.escape(os.path.basename(target))
    return {int(m) for m in re.findall(name + r":(\d+):\d+: error", text)}

for attempt in range(4):
    stub_all = compile_variant("stub-all", render(range(len(bodies))), 900)
    report("stub-all", stub_all)
    if stub_all[1] == "ok":
        break
    lines = error_lines("stub-all")
    broken = [b for b in bodies if any(b.line <= l <= b.end_line for l in lines)]
    if not broken:
        print("STUB-ALL FAILED outside any stubbed body", flush=True)
        sys.exit(2)
    print("leaving %s unstubbed: stubbing them does not compile" % ", ".join(b.label() for b in broken), flush=True)
    bodies = [b for b in bodies if b not in broken]
else:
    print("STUB-ALL FAILED", flush=True)
    sys.exit(2)
healthy = stub_all[0]
limit = max(args.min_limit, int(4 * healthy))
hot_line = 2 * healthy + 30
print("healthy %.1fs, per-variant limit %ds, hot above %.0fs" % (healthy, limit, hot_line), flush=True)

def is_hot(result):
    return result[1] == "TIMEOUT" or (result[1] == "ok" and result[0] > hot_line)

def keep_only(indices, label):
    keep = set(indices)
    return compile_variant(label, render([i for i in range(len(bodies)) if i not in keep]), limit)

def narrow(candidates, depth=0):
    while len(candidates) > 1:
        count = min(args.groups, len(candidates))
        size = -(-len(candidates) // count)
        groups = [candidates[i:i + size] for i in range(0, len(candidates), size)]
        labels = ["keep-%d-%s..%s" % (depth, bodies[g[0]].line, bodies[g[-1]].line) for g in groups]
        results = list(pool.map(lambda pair: keep_only(*pair), zip(groups, labels)))
        hot = []
        for group, label, result in zip(groups, labels, results):
            report(label, result, "(%d bodies: %s)" % (len(group), " ".join(bodies[i].name for i in group)[:160]))
            if is_hot(result):
                hot.append(group)
        if not hot:
            print("no single group reproduces the slow compile on its own; stopping at %d candidates" % len(candidates))
            return [candidates]
        if len(hot) > 1:
            found = []
            for group in hot:
                found += narrow(group, depth + 1)
            return found
        candidates = hot[0]
        depth += 1
    return [candidates]

found = narrow(list(range(len(bodies))))
culprits = [c[0] for c in found if len(c) == 1]
for c in found:
    print("CANDIDATE:", ", ".join(bodies[i].label() for i in c))

for index in culprits:
    body = bodies[index]
    alone = compile_variant("stub-only-%d" % body.line, render([index]), limit)
    report("stub-only " + body.label(), alone)
    starts = stubber.statements(source, body)
    print("culprit %s has %d top-level statements" % (body.label(), len(starts)), flush=True)
    others = [i for i in range(len(bodies)) if i != index]
    probes = {}

    def prefix(count):
        if count not in probes:
            cut = starts[count] if count < len(starts) else None
            inner = source[body.start + 1:body.end]
            if cut is not None:
                inner = source[body.start + 1:cut] + "fatalError()" + "\n" * source.count("\n", cut, body.end)
            probes[count] = compile_variant("prefix-%d-%d" % (body.line, count), render(others, {index: inner}), limit)
            report("prefix %d/%d statements" % (count, len(starts)), probes[count])
        return probes[count]

    lo, hi = 0, len(starts)
    while hi - lo > 1:
        points = sorted(set(lo + (hi - lo) * k // 4 for k in (1, 2, 3)) - {lo, hi})
        results = dict(zip(points, pool.map(prefix, points)))
        hot_points = [p for p in points if is_hot(results[p])]
        cold_points = [p for p in points if not is_hot(results[p])]
        new_hi = min(hot_points) if hot_points else hi
        new_lo = max([p for p in cold_points if p < new_hi] or [lo])
        if (new_lo, new_hi) == (lo, hi):
            break
        lo, hi = new_lo, new_hi
    line_of = lambda pos: source.count("\n", 0, pos) + 1
    if hi - 1 < len(starts):
        begin = starts[hi - 1]
        end = starts[hi] if hi < len(starts) else body.end
        print("statement %d (line %d) turns the prefix hot:" % (hi, line_of(begin)))
        print(source[begin:end][:3000])

if control is not None:
    report("control-original", control.result())
