#!/usr/bin/env python3
# The files of the two release source tarballs that are not TablePro's own,
# for build-aux/debian/copyright. cargo vendor copies every package in
# Cargo.lock into the vendor tarball, whatever its target, dependency kind
# or feature, so this reads cargo metadata, which lists the same packages,
# and not the narrower graph cargo-about walks for the binaries. Code a
# crate carries from another project and the dist tarball's third-party
# files are described in build-aux/about/source.json and the bundled
# manifests; a license file or archive inside a crate that neither
# describes fails the run.

import fnmatch
import json
import os
import re
import tarfile
from pathlib import Path

# License texts, and the notices that name the holders of code a crate
# took from elsewhere.
LICENSE_NAME = re.compile(
    r"^(?:licen[cs]es?|copying|unlicense|copyright|notices?|third[-_]?party(?:[-_]?notices)?|acknowledge?ments)(?:[-_.].*)?$",
    re.IGNORECASE,
)
# A few crates keep their license texts in a folder at the root.
LICENSE_FOLDER = "licenses"
TAR = re.compile(r"\.(?:tar|tgz|tbz2?|txz|tar\.(?:gz|bz2|xz|zst))$", re.IGNORECASE)
ARCHIVE = re.compile(r"\.(?:tar|tgz|tbz2?|txz|zip|gz|xz|bz2|zst|7z|jar|whl)$", re.IGNORECASE)


class InventoryError(Exception):
    pass


def lock_packages(lock_text):
    found = []
    for block in lock_text.split("[[package]]")[1:]:
        fields = dict(re.findall(r'^(name|version|source) = "([^"]*)"$', block, re.MULTILINE))
        if fields.get("source"):
            found.append((fields["name"], fields["version"]))
    return sorted(found)


def vendor_directory(name, version):
    return f"vendor/{name}-{version}"


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise InventoryError(f"{path} is not UTF-8: {error}") from error


# "path:START-END" takes those lines of a file whose license is a comment in
# it, without the comment markers. "archive!/member" reads a file inside an
# archive a crate ships.
EXCERPT = re.compile(r"^(.+):(\d+)-(\d+)$")
COMMENT = re.compile(r"^\s*(?:/\*+|\*+/|\*|//[/!]?|#+|dnl|%)? ?")
COMMENT_END = re.compile(r"\s*\*+/\s*$")


def read_crate_text(directory, path):
    excerpt = EXCERPT.match(path)
    if excerpt:
        path, start, end = excerpt.group(1), int(excerpt.group(2)), int(excerpt.group(3))
    if "!/" in path:
        archive, member = path.split("!/", 1)
        try:
            with tarfile.open(directory / archive) as tar:
                handle = tar.extractfile(member)
                if handle is None:
                    raise InventoryError(f"{member} in {archive} is not a file")
                text = handle.read().decode("utf-8")
        except (KeyError, tarfile.TarError, UnicodeDecodeError) as error:
            raise InventoryError(f"cannot read {member} in {directory / archive}: {error}") from error
    else:
        text = read_text(directory / path)
    if not excerpt:
        return text
    lines = text.split("\n")
    if end > len(lines) or start > end:
        raise InventoryError(f"{path} has no lines {start} to {end}")
    return "\n".join(COMMENT.sub("", COMMENT_END.sub("", line), count=1) for line in lines[start - 1 : end]) + "\n"


def paragraph_texts(directory, paragraph):
    return [read_crate_text(directory, path) for path in paragraph.get("texts", [])] + paragraph.get("text", [])


def crate_files(directory):
    found = []
    for folder, folders, files in os.walk(directory):
        folders.sort()
        relative = Path(folder).relative_to(directory)
        found += [(relative / name).as_posix() for name in sorted(files)]
    return found


def root_license_files(files):
    found = []
    for path in files:
        parts = path.split("/")
        if len(parts) == 1 and LICENSE_NAME.match(parts[0]):
            found.append(path)
        elif len(parts) == 2 and parts[0].lower() == LICENSE_FOLDER:
            found.append(path)
    return found


# License files below the root and archives anywhere: the marks of code a
# crate carries from another project.
def nested_files(files):
    found = []
    for path in files:
        parts = path.split("/")
        nested_license = len(parts) > 1 and parts[0].lower() != LICENSE_FOLDER and LICENSE_NAME.match(parts[-1])
        if nested_license or ARCHIVE.search(parts[-1]):
            found.append(path)
    return found


def matching(paths, pattern):
    return [path for path in paths if fnmatch.fnmatchcase(path, pattern)]


def load_source(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    crates = {}
    for entry in data.get("crates", []):
        key = (entry["crate"], entry["version"])
        if key in crates:
            raise InventoryError(f"build-aux/about/source.json describes {key[0]} {key[1]} twice")
        crates[key] = entry
    return crates, data.get("files", [])


def load_bundles(root):
    bundles = {}
    for manifest_path in sorted(Path(root).glob("*/manifest.json")):
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        components = []
        for component in manifest["components"]:
            if "file" in component:
                component = {**component, "text": read_text(manifest_path.parent / component["file"])}
            components.append(component)
        bundles[(manifest["crate"], manifest["version"])] = {**manifest, "components": components}
    return bundles


def check_described(described, locked, what):
    for name, version in sorted(set(described) - set(locked)):
        versions = ", ".join(v for n, v in locked if n == name) or "no version"
        raise InventoryError(
            f"{what} describes {name} {version}, but Cargo.lock has {versions}; "
            "read what the locked version carries and update it"
        )


def crate_unit(package, files, clarified):
    name, version = package["name"], package["version"]
    expression = clarified.get(name) or package.get("license")
    if not expression:
        raise InventoryError(f"{name} {version} declares no license expression; add a clarify entry to about.toml")
    directory = Path(package["manifest_path"]).parent
    authors = [author.strip() for author in package.get("authors") or [] if author.strip()]
    return {
        "files": [f"{vendor_directory(name, version)}/*"],
        "expression": expression,
        "texts": [read_text(directory / path) for path in root_license_files(files)],
        "authors": authors or [f"the {name} authors"],
    }


# The license files inside the tar archives a paragraph claims that its
# texts do not read, since a pattern cannot reach into an archive.
def unread_members(directory, files, patterns, texts):
    read = {EXCERPT.sub(r"\1", text) for text in texts}
    unread = []
    for archive in sorted({path for pattern in patterns for path in matching(files, pattern)}):
        if not TAR.search(archive):
            continue
        try:
            with tarfile.open(directory / archive) as tar:
                members = [member.name for member in tar.getmembers() if member.isfile()]
        except tarfile.TarError as error:
            raise InventoryError(f"cannot list {directory / archive}: {error}") from error
        for member in members:
            if LICENSE_NAME.match(member.rpartition("/")[2]) and f"{archive}!/{member}" not in read:
                unread.append(f"{archive}!/{member}")
    return unread


def nested_units(package, files, entry, bundle):
    name, version = package["name"], package["version"]
    directory = Path(package["manifest_path"]).parent
    prefix = vendor_directory(name, version)
    units = []
    unread = []
    claimed = list(entry.get("own", [])) if entry else []
    for paragraph in entry.get("paragraphs", []) if entry else []:
        units.append(
            {
                "files": [f"{prefix}/{pattern}" for pattern in paragraph["files"]],
                "expression": paragraph["license"],
                "texts": paragraph_texts(directory, paragraph),
                "copyright": paragraph.get("copyright", []),
            }
        )
        claimed += paragraph["files"]
        unread += unread_members(directory, files, paragraph["files"], paragraph.get("texts", []))
    if bundle and "files" in bundle:
        unread += unread_members(directory, files, [bundle["files"]], [])
        described = [component for component in bundle["components"] if "text" in component]
        units.append(
            {
                "files": [f"{prefix}/{bundle['files']}"],
                "expression": " AND ".join(f"({component['license']})" for component in described),
                "texts": [component["text"] for component in described],
                "copyright": [holder for component in described for holder in component.get("copyright", [])],
            }
        )
        claimed.append(bundle["files"])
    for pattern in claimed:
        if not matching(files, pattern):
            raise InventoryError(f"the pattern {pattern} for {name} {version} matches no file")
    unclaimed = [path for path in nested_files(files) if not any(matching([path], pattern) for pattern in claimed)]
    return units, [f"{prefix}/{path}" for path in unclaimed + unread]


# The files under the pattern's folder, walked from the folder before its
# first wildcard rather than from the root, which holds the build trees.
def pattern_files(root, pattern):
    literal = re.split(r"[*?\[]", pattern, maxsplit=1)[0]
    folder = root / literal.rpartition("/")[0]
    if not folder.is_dir():
        return []
    candidates = [
        (Path(path).relative_to(root) / name).as_posix() for path, _, files in os.walk(folder) for name in files
    ]
    return matching(candidates, pattern)


def dist_units(entries, source_root):
    units = []
    for entry in entries:
        for pattern in entry["files"]:
            if not pattern_files(Path(source_root), pattern):
                raise InventoryError(f"the pattern {pattern} in build-aux/about/source.json matches no file")
        units.append(
            {
                "files": entry["files"],
                "expression": entry["license"],
                "texts": paragraph_texts(Path(source_root), entry),
                "copyright": entry.get("copyright", []),
            }
        )
    return units


# The units in the order DEP-5 needs, where the last paragraph matching a
# file wins: the dist tarball's own exceptions, one per vendored crate, then
# the code inside crates that the crate's own paragraph does not cover.
def inventory(metadata, clarified, source_path, bundled_root, source_root):
    packages = sorted(
        (package for package in metadata["packages"] if package.get("source")),
        key=lambda package: (package["name"], package["version"]),
    )
    entries, dist_entries = load_source(source_path)
    bundles = load_bundles(bundled_root)
    locked = [(package["name"], package["version"]) for package in packages]
    check_described(entries, locked, "build-aux/about/source.json")
    check_described(bundles, locked, "build-aux/about/bundled")

    crates, nested, unclaimed = [], [], []
    for package in packages:
        key = (package["name"], package["version"])
        files = crate_files(Path(package["manifest_path"]).parent)
        crates.append(crate_unit(package, files, clarified))
        units, found = nested_units(package, files, entries.get(key), bundles.get(key))
        nested += units
        unclaimed += found
    if unclaimed:
        raise InventoryError(
            "these license files and archives inside vendored crates mark code that build-aux/about/source.json "
            f"does not describe; read where each comes from and describe it there: {', '.join(unclaimed)}"
        )
    return dist_units(dist_entries, source_root), crates, nested
