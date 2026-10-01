#!/usr/bin/env python3
"""Lists every registry plugin with its last tag and the commits since it.

The slug, the tag name and the target come from .github/plugin-registry.json. The source paths
come from the target in project.yml: its `folder:` under Plugins/, every local package it depends
on except TableProCore, which every plugin shares, and every Native/ bridge it or its templates
name.
Nothing here restates the plugin list.

Usage:
    python3 .claude/skills/release/scripts/changed-plugins.py [--all]

Prints only plugins with commits of their own or PluginKit commits since their last tag, unless
--all is given. Run it from anywhere inside the TablePro repo.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

KIT = "Plugins/TableProPluginKit/"


def git(root, *args):
    return subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def repo_root():
    try:
        return Path(git(Path(__file__).resolve().parent, "rev-parse", "--show-toplevel"))
    except subprocess.CalledProcessError:
        sys.exit("changed-plugins.py: not inside a git checkout")


def blocks(project_yml):
    sections = {"targetTemplates": {}, "targets": {}}
    section = name = None
    for line in project_yml.read_text(encoding="utf-8").splitlines():
        top = re.match(r"^(\w+):", line)
        if top:
            section = sections.get(top.group(1))
            name = None
            continue
        header = re.match(r"^  ([A-Za-z0-9]+):\s*$", line)
        if section is not None and header:
            name = header.group(1)
            section[name] = []
        elif section is not None and name:
            section[name].append(line)
    return sections["targetTemplates"], sections["targets"]


def source_paths(root, target, templates, targets):
    lines = targets.get(target)
    if lines is None:
        sys.exit(f"changed-plugins.py: no target {target} in project.yml")
    text = "\n".join(lines)
    for used in re.findall(r"templates:\s*\[([^\]]*)\]", text):
        for template in (t.strip() for t in used.split(",")):
            text += "\n" + "\n".join(templates.get(template, []))
    folder = re.search(r"^\s+folder:\s*(\S+)", text, re.M)
    if folder is None:
        sys.exit(f"changed-plugins.py: target {target} has no folder in project.yml")
    paths = [f"Plugins/{folder.group(1)}/"]
    for package in re.findall(r"-\s*package:\s*(\S+)", text):
        if package != "TableProCore" and (root / "Packages" / package).is_dir():
            paths.append(f"Packages/{package}/")
    paths += [f"Native/{bridge}/" for bridge in re.findall(r"Native/(\w+)", text)]
    return sorted(set(paths))


def last_tag(root, slug):
    tags = git(root, "tag", "-l", f"plugin-{slug}-v*", "--sort=-version:refname")
    return tags.splitlines()[0] if tags else None


def commit_count(root, since, paths):
    revision = f"{since}..HEAD" if since else "HEAD"
    return int(git(root, "rev-list", "--count", revision, "--", *paths))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--all", action="store_true", help="list unchanged plugins too")
    args = parser.parse_args()

    root = repo_root()
    plugins = json.loads((root / ".github/plugin-registry.json").read_text())["plugins"]
    templates, targets = blocks(root / "project.yml")

    print(f"{'slug':<20} {'bundled':<8} {'last tag':<34} own  kit  paths")
    for slug, entry in sorted(plugins.items()):
        paths = source_paths(root, entry["target"], templates, targets)
        tag = last_tag(root, slug)
        own = commit_count(root, tag, paths)
        kit = commit_count(root, tag, [KIT])
        if not args.all and own == 0 and kit == 0:
            continue
        bundled = "yes" if entry["bundled"] else "no"
        print(f"{slug:<20} {bundled:<8} {tag or 'never tagged':<34} {own:>3}  {kit:>3}  {' '.join(paths)}")


if __name__ == "__main__":
    main()
