import glob, os, re, sys

def heaviest_path(text):
    lines = text.split("Call graph:", 1)[-1].splitlines()
    path, last_indent = [], -1
    for line in lines[1:]:
        m = re.match(r"^(\s*[+!:| ]*)(\d+) (.*)$", line)
        if not m:
            if path:
                break
            continue
        indent = len(m.group(1))
        if indent <= last_indent:
            break
        last_indent = indent
        frame = re.sub(r"\s+\(in [^)]*\).*$", "", m.group(3)).strip()
        path.append("%s %s" % (m.group(2), frame[:160]))
    return path

def top_of_stack(text):
    block = text.split("Sort by top of stack, same collapsed", 1)
    if len(block) < 2:
        return []
    rows = []
    for line in block[1].splitlines()[1:12]:
        if not line.strip():
            break
        rows.append(re.sub(r"\s+\(in [^)]*\)", "", line.strip())[:160])
    return rows

for path in sorted(glob.glob(os.path.join(sys.argv[1], "stacks", "*.txt"))):
    text = open(path, errors="replace").read()
    print("== " + os.path.basename(path))
    frames = heaviest_path(text)
    interesting = [f for f in frames if "swift::" in f or "llvm::" in f or "clang::" in f]
    for frame in (interesting or frames)[-25:]:
        print("   " + frame)
    for row in top_of_stack(text):
        print("   top: " + row)
