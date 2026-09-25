import os, shutil, signal, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replay

OUT = os.path.abspath(sys.argv[1])
DERIVED = os.path.abspath("DerivedData-nocache")
target = os.path.join(OUT, "nocache-argv.txt")
files = os.path.join(OUT, "nocache-files")
os.makedirs(files, exist_ok=True)
log = open(os.path.join(OUT, "nocache-build.log"), "w")
build = subprocess.Popen(["xcodebuild", "build-for-testing", "-project", os.environ["XCODE_PROJECT"],
                          "-scheme", os.environ["XCODE_SCHEME"], "-destination", os.environ["TEST_DESTINATION"],
                          "-derivedDataPath", DERIVED, "-clonedSourcePackagesDirPath", os.path.expanduser("~/.spm-cache"),
                          "-skipPackagePluginValidation", "CODE_SIGNING_ALLOWED=NO", "COMPILATION_CACHE_ENABLE_CACHING=NO"],
                         stdout=log, stderr=subprocess.STDOUT)
started = time.time()

def ours():
    listing = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True).stdout
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(" ")
        if "swift-frontend -frontend -c" in command and DERIVED in command:
            yield int(pid), command

captured = None
while build.poll() is None and captured is None:
    time.sleep(2)
    for pid, command in ours():
        if " -module-name TablePro " not in command:
            continue
        try:
            argv = replay.argv_of(pid)
            rewritten, skip = [], False
            for i, a in enumerate(argv):
                if skip:
                    skip = False
                    continue
                if a in ("-filelist", "-primary-filelist") and i + 1 < len(argv):
                    copy = os.path.join(files, a.strip("-"))
                    shutil.copy(argv[i + 1], copy)
                    rewritten += [a, copy]
                    skip = True
                    continue
                rewritten.append(a)
            with open(target, "w") as handle:
                handle.write("\n".join(rewritten) + "\n")
            captured = pid
            break
        except (OSError, ValueError, IndexError):
            continue

build.send_signal(signal.SIGTERM)
time.sleep(3)
for pid, _ in list(ours()):
    os.kill(pid, signal.SIGTERM)
print("nocache argv %s after %ds" % ("captured from %d" % captured if captured else "NOT captured", time.time() - started))
sys.exit(0 if captured else 1)
