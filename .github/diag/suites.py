import os, re, shutil, sys

DISPLAY_NAME_ONLY = re.compile(r'(?m)^@Suite\("(?:[^"\\]|\\.)*"\)[ \t]*\n')

def transform(root, backup):
    shutil.copytree(root, backup)
    files = lines = 0
    for directory, _, names in os.walk(root):
        for name in names:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            text = open(path).read()
            new, count = DISPLAY_NAME_ONLY.subn("", text)
            if count:
                open(path, "w").write(new)
                files += 1
                lines += count
    print("removed %d display-name-only top-level @Suite attributes from %d files" % (lines, files))

if __name__ == "__main__":
    transform(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]))
