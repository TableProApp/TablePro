#!/usr/bin/env python3
"""Mechanical checks for a TablePro newsletter or X-post draft.

Catches the things that are decidable by looking at the text: house-style violations, sentence
length, subject and preview budgets, and links or images that cannot be resolved. It cannot
tell you whether a sentence is true; that pass is references/fact-checks.md.

Usage:
    python3 lint-draft.py <draft.md> [--repo <path-to-TablePro>]

Exits 1 when a hard rule is broken, 0 otherwise. Advisories never fail the run.
"""

import argparse
import os
import re
import sys

HARD = "hard"
SOFT = "soft"

BANNED = [
    "seamless", "robust", "comprehensive", "intuitive", "effortless", "streamlined",
    "leverage", "elevate", "unlock", "unleash", "supercharge", "delve", "utilize",
    "facilitate", "game-changer", "dive into", "empower", "harness",
    "you asked, we listened", "and much more", "worth your time", "you will notice",
    "excited", "thrilled", "introducing the",
]

VAGUE = [
    "many", "several", "a lot of", "significantly", "much faster", "greatly",
    "various", "numerous", "a number of",
]

FIRST_PERSON = re.compile(r"(?<![\w'])(we|our|ours|us|we're|we've|i'm|i've)(?![\w'])", re.I)
EMOJI = re.compile(
    "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF⬀-⯿]"
)

SUBJECT_COMFORTABLE = 48
SUBJECT_FIRST_ITEM = 41
PREVIEW_MIN, PREVIEW_MAX = 40, 95
MAX_SENTENCE_WORDS = 35


def strip_code(text):
    """Blank out fenced blocks and inline code so their contents do not trip the word rules."""
    text = re.sub(r"```.*?```", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"`[^`\n]*`", "``", text)


def lines_of(text):
    return text.split("\n")


def find_all(text, needle):
    """Line numbers where needle appears, case-insensitively, on a word boundary."""
    pattern = re.compile(r"(?<!\w)" + re.escape(needle) + r"(?!\w)", re.I)
    return [i for i, line in enumerate(lines_of(text), 1) if pattern.search(line)]


def sentences(text):
    """Prose sentences with their line numbers, links collapsed and headings dropped."""
    out = []
    for i, line in enumerate(lines_of(text), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", ">", "|", "---", "**Subject:", "**Preview")):
            continue
        collapsed = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", stripped)
        collapsed = re.sub(r"^[-*]\s+", "", collapsed)
        for sentence in re.split(r"(?<=[.!?])\s+", collapsed):
            if sentence.strip():
                out.append((i, sentence.strip()))
    return out


def check(text, repo):
    findings = []

    def add(level, rule, detail, line=None):
        findings.append((level, rule, detail, line))

    clean = strip_code(text)

    for line in find_all(clean, "—") or [i for i, l in enumerate(lines_of(clean), 1) if "—" in l]:
        add(HARD, "em dash", "use a comma, a period, a colon, or rewrite", line)

    for i, line in enumerate(lines_of(clean), 1):
        for match in FIRST_PERSON.finditer(line):
            add(HARD, "first person", f'"{match.group(0)}", the subject is the product or "you"', i)
        if ";" in line and "&#" not in line:
            add(HARD, "semicolon", "neither shipped newsletter uses one", i)
        if "!" in line and not line.lstrip().startswith("!["):
            add(SOFT, "exclamation mark", "check this is not enthusiasm", i)
        for match in EMOJI.finditer(line):
            add(HARD, "emoji", f"{match.group(0)!r}", i)

    for word in BANNED:
        for line in find_all(clean, word):
            add(HARD, "banned filler", f'"{word}"', line)

    for word in VAGUE:
        for line in find_all(clean, word):
            add(SOFT, "vague quantifier", f'"{word}", the house writes a figure', line)

    for i, sentence in sentences(clean):
        count = len(sentence.split())
        if count > MAX_SENTENCE_WORDS and ":" not in sentence:
            add(SOFT, "long sentence", f"{count} words, split it", i)

    for i, line in enumerate(lines_of(clean), 1):
        if re.match(r"^It also\b", line.strip()):
            add(SOFT, "\"It also\" opener", "open with the real subject", i)
        if re.match(r"^\*\*[^*]{1,40}\.\*\*\s+\S", line.strip()):
            add(SOFT, "bold run-in headline", "bold is for menu paths and new proper nouns", i)

    subject = re.search(r"^\*\*Subject:\*\*\s*(.+)$", text, re.M)
    if subject:
        value = subject.group(1).strip()
        head = value.split(",")[0]
        if len(value) > SUBJECT_COMFORTABLE:
            add(SOFT, "subject length", f"{len(value)} chars, Apple Mail iPhone shows about 48")
        if len(head) > SUBJECT_FIRST_ITEM:
            add(HARD, "subject first item", f"{len(head)} chars, Gmail iOS cuts near 40")
        items = [p for p in value.split(":", 1)[-1].split(",") if p.strip()]
        if len(items) > 3:
            add(SOFT, "subject items", f"{len(items)} items, the house uses two or three")
    else:
        add(SOFT, "subject", "no **Subject:** line found")

    preview = re.search(r"^\*\*Preview text:\*\*\s*(.+)$", text, re.M)
    if preview:
        length = len(preview.group(1).strip())
        if not PREVIEW_MIN <= length <= PREVIEW_MAX:
            add(SOFT, "preview length", f"{length} chars, aim for {PREVIEW_MIN} to {PREVIEW_MAX}")
    elif subject:
        add(SOFT, "preview text", "no **Preview text:** line found")

    check_assets(text, repo, add)
    return findings


def check_assets(text, repo, add):
    if not repo:
        return

    for i, line in enumerate(lines_of(text), 1):
        for path in re.findall(r"https://docs\.tablepro\.app/images/([\w.-]+)", line):
            local = os.path.join(repo, "docs", "images", path)
            if not os.path.exists(local):
                add(HARD, "missing image", path, i)
                continue
            size = png_size(local)
            if size == (1560, 960):
                add(HARD, "placeholder image", f"{path} is a 1560x960 placeholder card", i)

        for page in re.findall(r"https://docs\.tablepro\.app/(features|databases)/([\w-]+)", line):
            local = os.path.join(repo, "docs", page[0], page[1] + ".mdx")
            if not os.path.exists(local):
                add(HARD, "missing docs page", "/".join(page), i)


def png_size(path):
    """Width and height from the PNG IHDR, so this needs no image library."""
    try:
        with open(path, "rb") as handle:
            header = handle.read(24)
        if header[:8] != b"\x89PNG\r\n\x1a\n":
            return None
        return (
            int.from_bytes(header[16:20], "big"),
            int.from_bytes(header[20:24], "big"),
        )
    except OSError:
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("draft")
    parser.add_argument("--repo", default=find_repo())
    args = parser.parse_args()

    with open(args.draft, encoding="utf-8") as handle:
        text = handle.read()

    findings = check(text, args.repo)
    hard = [f for f in findings if f[0] == HARD]
    soft = [f for f in findings if f[0] == SOFT]

    words = len(strip_code(text).split())
    print(f"{args.draft}: {words} words, {len(hard)} to fix, {len(soft)} to look at\n")

    for level, label in ((HARD, "Fix"), (SOFT, "Look at")):
        group = hard if level == HARD else soft
        if not group:
            continue
        print(f"{label}:")
        for _, rule, detail, line in sorted(group, key=lambda f: (f[1], f[3] or 0)):
            where = f"line {line}" if line else "header"
            print(f"  {where:>10}  {rule}: {detail}")
        print()

    if not findings:
        print("Nothing mechanical to report. The factual pass is references/fact-checks.md.")

    return 1 if hard else 0


def find_repo():
    path = os.getcwd()
    while path != "/":
        if os.path.exists(os.path.join(path, "CHANGELOG.md")) and \
           os.path.isdir(os.path.join(path, "docs")):
            return path
        path = os.path.dirname(path)
    return None


if __name__ == "__main__":
    sys.exit(main())
