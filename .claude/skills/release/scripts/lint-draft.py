#!/usr/bin/env python3
"""Mechanical checks for a TablePro release announcement draft.

Covers what can be decided from the text alone: house style, sentence length, subject and preview
budgets, section weight in a blog post, and links or images that do not resolve. Whether a
sentence is true is references/fact-checks.md.

The banned words are read from scripts/banned-words.txt at the root of this repository, the one
list the docs and the agent checks share.

Usage:
    python3 lint-draft.py <draft.md> [--blog] [--repo <path-to-TablePro>]

--blog lints a post in the marketing site repo (resources/blog/<slug>.md): it drops the subject
and preview checks and adds frontmatter, section spread and image checks.

Exits 1 when a hard rule is broken, 2 when the banned-word list is missing, 0 otherwise.
"""

import argparse
import os
import re
import subprocess
import sys

HARD = "hard"
SOFT = "soft"

HYPE_PHRASES = [
    "you asked, we listened", "and much more", "worth your time", "you will notice",
    "excited", "thrilled", "introducing the",
]

VAGUE = [
    "many", "several", "a lot of", "significantly", "much faster", "greatly",
    "various", "numerous", "a number of",
]

BRITISH = re.compile(r"colour|behaviour|honour|recognis", re.I)
FIRST_PERSON = re.compile(r"(?<![\w'])(we|our|ours|us|we're|we've|i'm|i've)(?![\w'])", re.I)
EMOJI = re.compile("[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF⬀-⯿]")
FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
BLOG_FIELDS = ["slug", "title", "description", "date", "author", "tags"]

SUBJECT_COMFORTABLE = 48
SUBJECT_FIRST_ITEM = 41
PREVIEW_MIN, PREVIEW_MAX = 40, 95
MAX_SENTENCE_WORDS = 35
OG_PUNCHLINE_MAX = 90
SPREAD_FLOOR, SPREAD_TARGET = 2.0, 3.0


def repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        return subprocess.run(
            ["git", "-C", here, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def load_banned(root):
    path = os.path.join(root or "", "scripts", "banned-words.txt")
    if not root or not os.path.isfile(path):
        print(
            f"lint-draft.py: cannot read {path}. The banned-word list lives in "
            "scripts/banned-words.txt at the TablePro repo root, one term per line.",
            file=sys.stderr,
        )
        sys.exit(2)
    with open(path, encoding="utf-8") as handle:
        terms = [line.strip() for line in handle]
    return [t for t in terms if t and not t.startswith("#")]


def strip_code(text):
    text = re.sub(r"```.*?```", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"`[^`\n]*`", "``", text)


def strip_frontmatter(text):
    return FRONTMATTER.sub(lambda m: "\n" * m.group(0).count("\n"), text, count=1)


def lines_of(text):
    return text.split("\n")


def find_prefix(text, term):
    pattern = re.compile(r"(?<![\w-])" + re.escape(term), re.I)
    return [i for i, line in enumerate(lines_of(text), 1) if pattern.search(line)]


def find_word(text, term):
    pattern = re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.I)
    return [i for i, line in enumerate(lines_of(text), 1) if pattern.search(line)]


def sentences(text):
    out = []
    for i, line in enumerate(lines_of(text), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", ">", "|", "---", "<", "**Subject:", "**Preview")):
            continue
        collapsed = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", stripped)
        collapsed = re.sub(r"^[-*]\s+", "", collapsed)
        for sentence in re.split(r"(?<=[.!?])\s+", collapsed):
            if sentence.strip():
                out.append((i, sentence.strip()))
    return out


def check_prose(clean, banned, blog, add):
    for i, line in enumerate(lines_of(clean), 1):
        if "\u2014" in line:
            add(HARD, "em dash", "use a comma, a period, a colon, or rewrite", i)
        for match in FIRST_PERSON.finditer(line):
            if match.group(0) == "US":
                continue
            add(HARD, "first person", f'"{match.group(0)}", the subject is the product or "you"', i)
        if ";" in line and "&#" not in line:
            add(SOFT if blog else HARD, "semicolon", "split the sentence", i)
        if "!" in line and not line.lstrip().startswith(("![", "<!")):
            add(SOFT, "exclamation mark", "check this is not enthusiasm", i)
        for match in EMOJI.finditer(line):
            add(HARD, "emoji", f"{match.group(0)!r}", i)
        for match in BRITISH.finditer(line):
            add(HARD, "British spelling", f'"{match.group(0)}", the docs and the app use US spelling', i)
        if re.match(r"^It also\b", line.strip()):
            add(SOFT, "\"It also\" opener", "open with the real subject", i)
        if re.match(r"^\*\*[^*]{1,40}\.\*\*\s+\S", line.strip()):
            add(SOFT, "bold run-in headline", "bold is for menu paths and new proper nouns", i)

    for term in banned:
        for line in find_prefix(clean, term):
            add(HARD, "banned word", f'"{term}"', line)
    for phrase in HYPE_PHRASES:
        for line in find_word(clean, phrase):
            add(HARD, "hype phrase", f'"{phrase}"', line)
    for word in VAGUE:
        for line in find_word(clean, word):
            add(SOFT, "vague quantifier", f'"{word}", write the figure', line)

    for i, sentence in sentences(clean):
        count = len(sentence.split())
        if count > MAX_SENTENCE_WORDS and ":" not in sentence:
            add(SOFT, "long sentence", f"{count} words, split it", i)


def check_envelope(text, add):
    subject = re.search(r"^\*\*Subject:\*\*\s*(.+)$", text, re.M)
    if subject:
        value = subject.group(1).strip()
        head = value.split(",")[0]
        if len(value) > SUBJECT_COMFORTABLE:
            add(SOFT, "subject length", f"{len(value)} chars, Apple Mail on iPhone shows about 48")
        if len(head) > SUBJECT_FIRST_ITEM:
            add(HARD, "subject first item", f"{len(head)} chars, Gmail on iOS cuts near 40")
        items = [p for p in value.split(":", 1)[-1].split(",") if p.strip()]
        if len(items) > 3:
            add(SOFT, "subject items", f"{len(items)} items, use two or three")
    else:
        add(SOFT, "subject", "no **Subject:** line found")

    preview = re.search(r"^\*\*Preview text:\*\*\s*(.+)$", text, re.M)
    if preview:
        length = len(preview.group(1).strip())
        if not PREVIEW_MIN <= length <= PREVIEW_MAX:
            add(SOFT, "preview length", f"{length} chars, aim for {PREVIEW_MIN} to {PREVIEW_MAX}")
    elif subject:
        add(SOFT, "preview text", "no **Preview text:** line found")


def check_blog(text, draft_path, add):
    front = FRONTMATTER.match(text)
    if not front:
        add(HARD, "frontmatter", "no --- block at the top")
        return
    fields = dict(re.findall(r"^(\w+):\s*(.*)$", front.group(1), re.M))
    for name in BLOG_FIELDS:
        if not fields.get(name):
            add(HARD, "frontmatter", f"missing {name}")
    stem = os.path.splitext(os.path.basename(draft_path))[0]
    if fields.get("slug") and fields["slug"] != stem:
        add(HARD, "frontmatter", f"slug {fields['slug']} does not match the filename {stem}")
    title = fields.get("title", "")
    if ":" in title and not title.startswith(('"', "'")):
        add(HARD, "frontmatter", "a title with a colon must be quoted")
    punchline = fields.get("ogPunchline", "")
    if len(punchline) > OG_PUNCHLINE_MAX:
        add(SOFT, "ogPunchline", f"{len(punchline)} chars, keep it under about {OG_PUNCHLINE_MAX}")

    body = re.sub(r"<figure>.*?</figure>", "", text[front.end():], flags=re.S)
    sections = [len(s.split()) for s in re.split(r"\n## ", body)[1:]]
    if len(sections) >= 2 and min(sections) > 0:
        spread = max(sections) / min(sections)
        detail = f"{spread:.1f}x between sections of {min(sections)} and {max(sections)} words"
        if spread < SPREAD_FLOOR:
            add(HARD, "section spread", f"{detail}, every section weighs the same")
        elif spread < SPREAD_TARGET:
            add(SOFT, "section spread", f"{detail}, aim for {SPREAD_TARGET:.0f}x")

    web_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(draft_path))))
    for i, line in enumerate(lines_of(text), 1):
        for src in re.findall(r'src="/(images/blog/[^"]+)"', line):
            if not os.path.isfile(os.path.join(web_root, "public", src)):
                add(HARD, "missing image", src, i)


def check_assets(text, repo, add):
    if not repo:
        return
    for i, line in enumerate(lines_of(text), 1):
        for path in re.findall(r"https://docs\.tablepro\.app/images/([\w.-]+)", line):
            local = os.path.join(repo, "docs", "images", path)
            if not os.path.exists(local):
                add(HARD, "missing image", path, i)
            elif png_size(local) == (1560, 960):
                add(HARD, "placeholder image", f"{path} is a 1560x960 placeholder card", i)
        for kind, page in re.findall(r"https://docs\.tablepro\.app/(features|databases)/([\w-]+)", line):
            if not os.path.exists(os.path.join(repo, "docs", kind, page + ".mdx")):
                add(HARD, "missing docs page", f"{kind}/{page}", i)


def png_size(path):
    try:
        with open(path, "rb") as handle:
            header = handle.read(24)
    except OSError:
        return None
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def main():
    root = repo_root()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("draft")
    parser.add_argument("--blog", action="store_true", help="lint a marketing site blog post")
    parser.add_argument("--repo", default=root, help="the TablePro checkout for docs links")
    args = parser.parse_args()

    banned = load_banned(root)
    with open(args.draft, encoding="utf-8") as handle:
        text = handle.read()

    findings = []

    def add(level, rule, detail, line=None):
        findings.append((level, rule, detail, line))

    clean = strip_code(strip_frontmatter(text))
    check_prose(clean, banned, args.blog, add)
    if args.blog:
        check_blog(text, args.draft, add)
    else:
        check_envelope(text, add)
    check_assets(text, args.repo, add)

    hard = [f for f in findings if f[0] == HARD]
    soft = [f for f in findings if f[0] == SOFT]
    words = len(re.sub(r"<figure>.*?</figure>", "", clean, flags=re.S).split())
    print(f"{args.draft}: {words} words, {len(hard)} to fix, {len(soft)} to look at\n")

    for label, group in (("Fix", hard), ("Look at", soft)):
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


if __name__ == "__main__":
    sys.exit(main())
