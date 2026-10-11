import re
from collections import Counter


def completed_tests(output, expected):
    passed = re.findall(r"^test (.+) \.\.\. ok$", output, re.MULTILINE)
    summaries = re.findall(
        r"^test result: (\w+)\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; (\d+) filtered out",
        output, re.MULTILINE,
    )
    return (bool(expected) and len(set(expected)) == len(expected)
            and Counter(passed) == Counter(expected) and len(summaries) == 1
            and summaries[0][0] == "ok"
            and tuple(map(int, summaries[0][1:5])) == (len(expected), 0, 0, 0))
