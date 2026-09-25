import concurrent.futures, ctypes, ctypes.util, os, re, struct, subprocess, sys, time

def argv_of(pid):
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(0)
    libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0)
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        raise OSError("sysctl failed")
    raw = buf.raw[:size.value]
    argc = struct.unpack("i", raw[:4])[0]
    rest = raw[4:]
    exe_end = rest.index(b"\0")
    rest = rest[exe_end:].lstrip(b"\0")
    parts = rest.split(b"\0")
    return [p.decode() for p in parts[:argc]]

def option(argv, name):
    for i, a in enumerate(argv[:-1]):
        if a == name:
            return argv[i + 1]
    return None

def primaries(argv):
    out = []
    for i, a in enumerate(argv):
        if a == "-primary-file":
            out.append(argv[i + 1])
        if a == "-primary-filelist":
            out += [l.strip() for l in open(argv[i + 1]) if l.strip()]
    return out

DROP_WITH_VALUE = {"-o", "-supplementary-output-file-map", "-index-unit-output-path", "-index-store-path",
                   "-output-filelist", "-emit-dependencies-path", "-serialize-diagnostics-path",
                   "-emit-const-values-path", "-primary-filelist"}

def single(argv, target, out, extra=()):
    uses_filelist = "-filelist" in argv
    args, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a == "-primary-file":
            if not uses_filelist:
                args += (["-primary-file", target] if argv[i + 1] == target else [argv[i + 1]])
            i += 2
            continue
        if a in DROP_WITH_VALUE:
            i += 2
            continue
        args.append(a)
        i += 1
    if uses_filelist:
        listing = out + ".primary"
        with open(listing, "w") as handle:
            handle.write(target + "\n")
        args += ["-primary-filelist", listing]
    return args + list(extra) + ["-o", out]

def without_cache(argv):
    return [a for a in argv if a != "-cache-compile-job"]

def swap_source(argv, target, replacement, workdir):
    swapped = [replacement if a == target else a for a in argv]
    listing = option(swapped, "-filelist")
    if listing is None:
        return swapped
    inputs = [l.rstrip("\n") for l in open(listing)]
    if target not in inputs:
        raise ValueError("target missing from filelist: " + target)
    rewritten = os.path.join(workdir, "inputs.txt")
    with open(rewritten, "w") as handle:
        handle.write("\n".join(replacement if f == target else f for f in inputs) + "\n")
    at = swapped.index("-filelist") + 1
    swapped[at] = rewritten
    return swapped

def long_bodies(stderr_text):
    found = []
    for m in re.finditer(r"([^\"\\]{0,160}) took (\d+)ms to type-check", stderr_text):
        found.append((int(m.group(2)), m.group(1).strip()[-120:]))
    return sorted(set(found), reverse=True)

def run_frontend(args, limit, stderr_path):
    start = time.time()
    with open(stderr_path, "wb") as err:
        try:
            proc = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=err, timeout=limit)
            status = "ok" if proc.returncode == 0 else "exit %d" % proc.returncode
        except subprocess.TimeoutExpired:
            status = "TIMEOUT"
    return time.time() - start, status

def error_tail(stderr_path, size=600):
    text = open(stderr_path, errors="replace").read()
    errors = re.findall(r"error: [^\"\\]{0,300}", text)
    if errors:
        return " | ".join(dict.fromkeys(errors))[:size]
    return text[-size:].replace("\n", " | ")

def load_argv(path):
    return [l.rstrip("\n") for l in open(path)]

if __name__ == "__main__":
    argv = load_argv(sys.argv[1])
    limit = int(sys.argv[2])
    os.makedirs("/tmp/replay", exist_ok=True)
    files = primaries(argv)
    print("primary files:", len(files), flush=True)

    def one(f):
        out = "/tmp/replay/" + os.path.basename(f) + ".o"
        seconds, status = run_frontend(single(argv, f, out), limit, out + ".err")
        return "%6.1fs %s %s" % (seconds, os.path.basename(f), status)

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for line in pool.map(one, files):
            print(line, flush=True)
