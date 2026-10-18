#!/usr/bin/env python3

import argparse
import hashlib
import json
import plistlib
import re
import sys
import zipfile
from pathlib import Path
from typing import Callable, Dict, List, Optional

import version

ROOT = Path(__file__).resolve().parent.parent.parent
METADATA = ROOT / ".github/plugin-registry.json"
PLUGINKIT_CONFIG = "Configs/PluginKit.xcconfig"
SCHEMA_VERSION = 3
CHANNELS = ("stable", "beta")
RELEASES_PER_KEY = 2
PROVIDES = ("TableProProvidesDatabaseTypeIds", "TableProProvidesExportFormatIds", "TableProProvidesImportFormatIds")
LISTED = (
    ("TableProProvidesDatabaseTypeIds", "databaseTypeIds"),
    ("TableProProvidesExportFormatIds", "exportFormatIds"),
)
SYSTEM_VERSION = re.compile(r"[0-9]+(\.[0-9]+){0,2}")


class RegistryError(Exception):
    pass


def load_metadata(path: Path) -> dict:
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RegistryError(f"{path}: {error}") from error
    shape = "{retainFromPluginKit, plugins: {<Target>: {name}}}"
    plugins = metadata.get("plugins") if isinstance(metadata, dict) else None
    if not isinstance(plugins, dict) or not _is_int(metadata.get("retainFromPluginKit")):
        raise RegistryError(f"{path} is not in the {shape} shape")
    for target, entry in plugins.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            raise RegistryError(f"{path}: {target} needs a name, as in {shape}")
    return metadata


def pluginkit_version(root: Path) -> int:
    try:
        text = (root / PLUGINKIT_CONFIG).read_text(encoding="utf-8")
    except OSError as error:
        raise RegistryError(f"{PLUGINKIT_CONFIG}: {error}") from error
    found = re.search(r"^TABLEPRO_PLUGINKIT_VERSION\s*=\s*([0-9]+)\s*$", text, re.MULTILINE)
    if found is None:
        raise RegistryError(f"{PLUGINKIT_CONFIG} sets no TABLEPRO_PLUGINKIT_VERSION")
    return int(found.group(1))


def publish_set(metadata: dict) -> List[str]:
    targets = sorted(metadata["plugins"])
    if not targets:
        raise RegistryError("the registry metadata publishes no plugin")
    return targets


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_info(archive: Path, target: str) -> dict:
    name = f"{target}.tableplugin/Contents/Info.plist"
    try:
        with zipfile.ZipFile(archive) as bundle:
            return plistlib.loads(bundle.read(name))
    except KeyError as error:
        raise RegistryError(f"{archive.name} has no {name}") from error
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException, ValueError) as error:
        raise RegistryError(f"{archive.name}: {error}") from error


def describe_one(archive: Path, target: str, entry: dict, release: str, build: int, kit: int) -> dict:
    info = read_info(archive, target)
    problems = []
    if info.get("CFBundleShortVersionString") != release:
        problems.append(f"CFBundleShortVersionString is {info.get('CFBundleShortVersionString')!r}, not {release!r}")
    if info.get("CFBundleVersion") != str(build):
        problems.append(f"CFBundleVersion is {info.get('CFBundleVersion')!r}, not '{build}'")
    found_kit = info.get("TableProPluginKitVersion")
    if not _is_int(found_kit) or found_kit != kit:
        problems.append(f"TableProPluginKitVersion is {found_kit!r}, not the integer {kit}")
    identifier = info.get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier:
        problems.append("CFBundleIdentifier is missing")
    system = info.get("LSMinimumSystemVersion")
    if not isinstance(system, str) or not SYSTEM_VERSION.fullmatch(system):
        problems.append(f"LSMinimumSystemVersion is {system!r}")
    listed = {}
    for key, field in LISTED:
        ids = info.get(key, [])
        if not isinstance(ids, list) or not all(isinstance(each, str) for each in ids):
            problems.append(f"{key} is not a list of strings")
        listed[field] = ids
    # The app finds the plugin that serves a database type or a file format through these keys.
    if not any(info.get(key) for key in PROVIDES):
        problems.append(f"it declares none of {', '.join(PROVIDES)}")
    if problems:
        raise RegistryError(f"{archive.name}: " + "; ".join(problems))
    return {
        "id": identifier,
        "name": entry["name"],
        **listed,
        "version": release,
        "build": build,
        "pluginKit": kit,
        "minimumSystemVersion": system,
        "file": archive.name,
        "sha256": _sha256(archive),
    }


def describe(zips: Path, release: str, build: int, kit: int, metadata: dict) -> List[dict]:
    entries = []
    for target in publish_set(metadata):
        archive = zips / f"{target}-{release}.zip"
        if not archive.is_file():
            raise RegistryError(f"{archive} does not exist")
        entries.append(describe_one(archive, target, metadata["plugins"][target], release, build, kit))
    seen: Dict[str, str] = {}
    for entry in entries:
        if entry["id"] in seen:
            raise RegistryError(f"{entry['file']} and {seen[entry['id']]} share the bundle id {entry['id']}")
        seen[entry["id"]] = entry["file"]
    return entries


def empty_manifest(retain_from: int) -> dict:
    return {"schemaVersion": SCHEMA_VERSION, "retainFromPluginKit": retain_from, "plugins": []}


def load_manifest(path: Path) -> Optional[dict]:
    if not path.exists():
        return None
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RegistryError(f"{path}: {error}") from error
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != SCHEMA_VERSION:
        found = manifest.get("schemaVersion") if isinstance(manifest, dict) else None
        raise RegistryError(f"{path} has schemaVersion {found!r}; this tool writes only {SCHEMA_VERSION}")
    if not _is_int(manifest.get("retainFromPluginKit")) or not isinstance(manifest.get("plugins"), list):
        raise RegistryError(f"{path} needs an integer retainFromPluginKit and a plugins list")
    for plugin in manifest["plugins"]:
        if not isinstance(plugin, dict) or not isinstance(plugin.get("id"), str) \
                or not isinstance(plugin.get("releases"), list):
            raise RegistryError(f"{path}: every plugin needs an id and a releases list")
        for release in plugin["releases"]:
            if not isinstance(release, dict) or not all(_is_int(release.get(key)) for key in ("build", "pluginKit")) \
                    or release.get("channel") not in CHANNELS \
                    or not all(isinstance(release.get(key), str) for key in ("version", "minimumSystemVersion")):
                raise RegistryError(f"{path}: a release of {plugin['id']} lacks an integer build or pluginKit, "
                                    "a channel, a version or a minimumSystemVersion")
    return manifest


def write_manifest(path: Path, manifest: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def retain(releases: List[dict], floor: int) -> List[dict]:
    kept = [release for release in releases if release["pluginKit"] >= floor]
    kept = [
        release for release in kept
        if release["channel"] != "beta" or not any(
            other["channel"] == "stable" and other["pluginKit"] == release["pluginKit"]
            and other["minimumSystemVersion"] == release["minimumSystemVersion"] and other["build"] > release["build"]
            for other in kept)
    ]
    groups: Dict[tuple, List[dict]] = {}
    for release in sorted(kept, key=lambda candidate: candidate["build"], reverse=True):
        key = (release["channel"], release["pluginKit"], release["minimumSystemVersion"])
        groups.setdefault(key, []).append(release)
    survivors = [release for group in groups.values() for release in group[:RELEASES_PER_KEY]]
    return sorted(survivors, key=lambda candidate: candidate["build"], reverse=True)


def _release(entry: dict, channel: str, url_base: str) -> dict:
    return {
        "version": entry["version"],
        "build": entry["build"],
        "channel": channel,
        "pluginKit": entry["pluginKit"],
        "minimumSystemVersion": entry["minimumSystemVersion"],
        "url": url_base.rstrip("/") + "/" + entry["file"],
        "sha256": entry["sha256"],
    }


def add(path: Path, entries: List[dict], channel: str, url_base: str, retain_from: int,
        log: Callable[[str], None] = print) -> bool:
    loaded = load_manifest(path)
    before = json.dumps(loaded, sort_keys=True) if loaded is not None else None
    manifest = loaded if loaded is not None else empty_manifest(retain_from)
    floor = max(manifest["retainFromPluginKit"], retain_from)
    plugins = {plugin["id"]: plugin for plugin in manifest["plugins"]}

    arrived = []
    for entry in entries:
        release = _release(entry, channel, url_base)
        plugin = plugins.setdefault(entry["id"], {"id": entry["id"], "releases": []})
        same = [existing for existing in plugin["releases"] if existing["build"] == release["build"]]
        if same and same[0].get("sha256") != release["sha256"]:
            raise RegistryError(f"{entry['id']} already has build {release['build']} with sha256 "
                                f"{same[0].get('sha256')}, not {release['sha256']}")
        if same:
            log(f"{entry['id']} {release['version']}: already in the manifest")
            continue
        plugin["releases"].append(release)
        arrived.append((entry, release))

    for plugin in plugins.values():
        plugin["releases"] = retain(plugin["releases"], floor)
    for entry, release in arrived:
        plugin = plugins[entry["id"]]
        if not any(kept is release for kept in plugin["releases"]):
            log(f"{entry['id']} {release['version']}: pruned on arrival by retention, not added")
        elif plugin["releases"][0] is release:
            plugin.update({key: entry[key] for key in ("name", "databaseTypeIds", "exportFormatIds")})

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "retainFromPluginKit": floor,
        "plugins": [_ordered(plugins[key]) for key in sorted(plugins) if plugins[key]["releases"]],
    }
    if json.dumps(manifest, sort_keys=True) == before:
        return False
    write_manifest(path, manifest)
    return True


def _ordered(plugin: dict) -> dict:
    keys = ("id", "name", "databaseTypeIds", "exportFormatIds")
    return {**{key: plugin[key] for key in keys if key in plugin}, "releases": plugin["releases"]}


def withdraw(path: Path, release: str, log: Callable[[str], None] = print) -> bool:
    version.parse_version(release)
    manifest = load_manifest(path)
    if manifest is None:
        raise RegistryError(f"{path} does not exist")
    removed = 0
    for plugin in manifest["plugins"]:
        kept = [candidate for candidate in plugin["releases"] if candidate.get("version") != release]
        removed += len(plugin["releases"]) - len(kept)
        plugin["releases"] = kept
    if not removed:
        log(f"{path.name} has no {release} release")
        return False
    manifest["plugins"] = [plugin for plugin in manifest["plugins"] if plugin["releases"]]
    write_manifest(path, manifest)
    log(f"withdrew {removed} {release} release(s) from {path.name}")
    return True


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="The registry plugins and the v3 plugin manifest.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("targets", help="print the targets the registry publishes")
    command.add_argument("--metadata", type=Path, default=METADATA)
    command = commands.add_parser("describe", help="check the built plugin zips as the manifest will read them")
    command.add_argument("--zips", type=Path, required=True)
    command.add_argument("--version", required=True)
    command.add_argument("--build", type=int, required=True)
    command.add_argument("--kit", type=int, help=f"default: TABLEPRO_PLUGINKIT_VERSION in {PLUGINKIT_CONFIG}")
    command.add_argument("--metadata", type=Path, default=METADATA)
    args = parser.parse_args(argv)

    try:
        if args.command == "targets":
            print("\n".join(publish_set(load_metadata(args.metadata))))
        else:
            kit = args.kit if args.kit is not None else pluginkit_version(ROOT)
            entries = describe(args.zips, args.version, args.build, kit, load_metadata(args.metadata))
            print(f"described {len(entries)} plugins")
    except (RegistryError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
