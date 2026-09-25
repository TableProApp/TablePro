import argparse, concurrent.futures, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replay

parser = argparse.ArgumentParser()
parser.add_argument("argv")
parser.add_argument("target")
parser.add_argument("variants", nargs="+", help="label=path of a full replacement for the target file")
parser.add_argument("--limit", type=int, default=900)
parser.add_argument("--nocache", action="store_true")
parser.add_argument("--work", default="/tmp/variants")
parser.add_argument("--workers", type=int, default=3)
args = parser.parse_args()

argv = replay.load_argv(args.argv)
if args.nocache:
    argv = replay.without_cache(argv)
listing = replay.option(argv, "-filelist")
inputs = replay.load_argv(listing) if listing else [a for a in argv if a.endswith(".swift")]
matches = [i for i in inputs if i == args.target or i.endswith("/" + args.target.lstrip("/"))]
if len(matches) != 1:
    sys.exit("cannot resolve %s: %s" % (args.target, matches[:5]))
target = matches[0]
shutil.rmtree(args.work, ignore_errors=True)

def compile_one(item):
    label, path = item.split("=", 1)
    directory = os.path.join(args.work, label)
    os.makedirs(directory, exist_ok=True)
    variant = os.path.join(directory, os.path.basename(target))
    shutil.copy(path, variant)
    swapped = replay.swap_source(argv, target, variant, directory)
    extra = ["-stats-output-dir", os.path.join(directory, "stats")]
    os.makedirs(extra[1], exist_ok=True)
    seconds, status = replay.run_frontend(replay.single(swapped, variant, os.path.join(directory, "out.o"), extra),
                                          args.limit, os.path.join(directory, "stderr.txt"))
    detail = "" if status in ("ok", "TIMEOUT") else replay.error_tail(os.path.join(directory, "stderr.txt"), 700)
    line = "%7.1fs %-8s %-40s %s" % (seconds, status, label, detail)
    print(line, flush=True)
    return line

with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
    lines = list(pool.map(compile_one, args.variants))
print("\n== summary")
for line in lines:
    print(line)
