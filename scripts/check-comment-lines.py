#!/usr/bin/env python3
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINES = ROOT / "comment-line-baselines.txt"
COMMENT = re.compile(r"\s*//")


def source_files(root):
    for crate in sorted((root / "crates").glob("**/src")):
        yield from sorted(crate.rglob("*.rs"))


def comment_counts(root):
    counts = {}
    for path in source_files(root):
        count = sum(1 for line in path.read_text(errors="replace").splitlines() if COMMENT.match(line))
        if count:
            counts[path.relative_to(root).as_posix()] = count
    return counts


def read_baselines(text):
    baselines = {}
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        path, _, count = line.rpartition(" ")
        baselines[path] = int(count)
    return baselines


def problems(counts, baselines):
    found = []
    for path, count in sorted(counts.items()):
        allowed = baselines.get(path, 0)
        if count > allowed:
            found.append(f"{path}: {count} comment lines, baseline {allowed}. Express the intent in names and types instead")
    return found


def render(counts):
    header = "# Comment lines per Rust source file. A file may not gain comment lines; lower its count when it loses some.\n"
    return header + "".join(f"{path} {count}\n" for path, count in sorted(counts.items()))


def main(argv):
    counts = comment_counts(ROOT)
    if "--update" in argv:
        BASELINES.write_text(render(counts))
        return 0
    found = problems(counts, read_baselines(BASELINES.read_text()))
    for message in found:
        print(f"error: {message}", file=sys.stderr)
    print(f"comment-lines: {'ok' if not found else f'{len(found)} error(s)'} ({sum(counts.values())} lines in {len(counts)} files)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
