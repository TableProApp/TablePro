import ctypes, ctypes.util, os, struct, subprocess, sys, time, concurrent.futures

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

def single(argv, target, out):
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
    return args + ["-o", out]

def run(argv, target, limit):
    out = "/tmp/replay/" + os.path.basename(target) + ".o"
    start = time.time()
    try:
        proc = subprocess.run(single(argv, target, out), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=limit)
        status = "ok" if proc.returncode == 0 else "exit %d: %s" % (proc.returncode, proc.stderr.decode()[-300:].replace("\n", " | "))
    except subprocess.TimeoutExpired:
        status = "TIMEOUT"
    return "%6.1fs %s %s" % (time.time() - start, os.path.basename(target), status)

if __name__ == "__main__":
    argv = [l.rstrip("\n") for l in open(sys.argv[1])]
    limit = int(sys.argv[2])
    os.makedirs("/tmp/replay", exist_ok=True)
    files = primaries(argv)
    print("primary files:", len(files), flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for line in pool.map(lambda f: run(argv, f, limit), files):
            print(line, flush=True)
