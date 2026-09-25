import collections, re, sys

TARGETS = {"TablePro", "TableProTests", "TableProUITests"}
pattern = re.compile(r"^(\d\d:\d\d:\d\d) (\S+) .*\(in target '([^']+)' from project")
compiles = collections.defaultdict(list)
events = []
for line in open(sys.argv[1], errors="replace"):
    m = pattern.match(line)
    if not m or m.group(3) not in TARGETS:
        continue
    stamp, kind, target = m.groups()
    if kind == "SwiftCompile":
        compiles[target].append(stamp)
    elif kind not in ("CpResource", "ProcessInfoPlistFile", "CopySwiftLibs", "Copy", "WriteAuxiliaryFile",
                      "CompileAssetCatalogVariant", "MkDir", "Touch", "SymLink", "CreateBuildDirectory"):
        events.append("%s %-28s %-16s %s" % (stamp, kind, target, line.strip()[len(stamp) + 1:][:150]))
for target, stamps in compiles.items():
    per_minute = collections.Counter(s[:5] for s in stamps)
    print("%s SwiftCompile lines=%d first=%s last=%s per-minute=%s" % (target, len(stamps), stamps[0], stamps[-1],
                                                                       " ".join("%s:%d" % kv for kv in sorted(per_minute.items()))))
for event in events:
    print(event)
