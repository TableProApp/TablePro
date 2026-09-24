import concurrent.futures, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import replay

TARGET = os.path.abspath("TablePro/Core/VersionHistory/LinkedFileVersionHistoryProvider.swift")
FUNCS = ["loadHistory", "content", "prepareRestore", "prepareDiscard", "rejectLargeFileStoragePointer",
         "writePlan", "currentBytes", "differsFromLastCommit", "makeClient", "gitCall"]

def stub(lines, name):
    start = next(i for i, l in enumerate(lines) if ("func " + name + "(") in l or ("func " + name + "<") in l)
    open_line = next(i for i in range(start, len(lines)) if lines[i].rstrip().endswith("{"))
    depth, end = 0, None
    for i in range(open_line, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0:
            end = i
            break
    return lines[:open_line + 1] + ["        fatalError()\n", "    }\n"] + lines[end + 1:]

EDITS = {
    "fix-hoist-locals": ('        let client = try makeClient()\n        let current = try currentBytes()\n        let staged = try await gitCall { try await client.blob(revision: "", path: indexPath, in: directory) }\n        try Self.rejectLargeFileStoragePointer(staged)\n        let directory = directory\n        let indexPath = indexPath\n', '        let client = try makeClient()\n        let current = try currentBytes()\n        let directory = directory\n        let indexPath = indexPath\n        let staged = try await gitCall { try await client.blob(revision: "", path: indexPath, in: directory) }\n        try Self.rejectLargeFileStoragePointer(staged)\n'),
    "fix-rename-locals": ('        let client = try makeClient()\n        let current = try currentBytes()\n        let staged = try await gitCall { try await client.blob(revision: "", path: indexPath, in: directory) }\n        try Self.rejectLargeFileStoragePointer(staged)\n        let directory = directory\n        let indexPath = indexPath\n        return writePlan(\n            replacing: current,\n            with: staged,\n            replacesUncommittedChanges: true,\n            sourceIsUnchanged: { (try? await client.blob(revision: "", path: indexPath, in: directory)) == staged }', '        let client = try makeClient()\n        let current = try currentBytes()\n        let staged = try await gitCall { try await client.blob(revision: "", path: indexPath, in: directory) }\n        try Self.rejectLargeFileStoragePointer(staged)\n        let stagedDirectory = directory\n        let stagedPath = indexPath\n        return writePlan(\n            replacing: current,\n            with: staged,\n            replacesUncommittedChanges: true,\n            sourceIsUnchanged: { (try? await client.blob(revision: "", path: stagedPath, in: stagedDirectory)) == staged }'),
}

def variants():
    lines = open(TARGET).readlines()
    text = "".join(lines)
    yield "original", text
    yield "stub-prepareDiscard", "".join(stub(lines, "prepareDiscard"))
    for label, (old, new) in EDITS.items():
        if old in text:
            yield "edit-" + label, text.replace(old, new)
        else:
            print("edit not applicable:", label, flush=True)

def run(argv, label, text, limit):
    os.makedirs("/tmp/bisect/" + label, exist_ok=True)
    path = "/tmp/bisect/" + label + "/LinkedFileVersionHistoryProvider.swift"
    open(path, "w").write(text)
    swapped = [path if a == TARGET else a for a in argv]
    if "-filelist" in swapped:
        at = swapped.index("-filelist") + 1
        inputs = [l.rstrip("\n") for l in open(swapped[at])]
        if TARGET not in inputs:
            return "%-40s target missing from filelist" % label
        listing = "/tmp/bisect/" + label + "/inputs.txt"
        open(listing, "w").write("\n".join(path if f == TARGET else f for f in inputs) + "\n")
        swapped[at] = listing
    args = replay.single(swapped, path, "/tmp/bisect/" + label + "/out.o")
    start = time.time()
    try:
        proc = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=limit)
        status = "ok" if proc.returncode == 0 else "exit %d: %s" % (proc.returncode, proc.stderr.decode()[-400:].replace("\n", " | "))
    except subprocess.TimeoutExpired:
        status = "TIMEOUT"
    return "%6.1fs %-40s %s" % (time.time() - start, label, status)

if __name__ == "__main__":
    argv = [l.rstrip("\n") for l in open(sys.argv[1])]
    print("filelist" if "-filelist" in argv else "inline inputs", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for line in pool.map(lambda v: run(argv, v[0], v[1], int(sys.argv[2])), list(variants())):
            print(line, flush=True)
