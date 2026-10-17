#!/usr/bin/env python3

import argparse
import hashlib
import json
import plistlib
import re
import sys
import zipfile
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set

import version

ROOT = Path(__file__).resolve().parent.parent.parent
METADATA = ROOT / ".github/plugin-registry.json"
PROJECT = ROOT / "project.yml"
SCHEMA_VERSION = 3
CHANNELS = ("stable", "beta")
RELEASES_PER_KEY = 2
PROVIDES = ("TableProProvidesDatabaseTypeIds", "TableProProvidesExportFormatIds", "TableProProvidesImportFormatIds")
SYSTEM_VERSION = re.compile(r"[0-9]+(\.[0-9]+){0,2}")
SHA256 = re.compile(r"[0-9a-f]{64}")


class RegistryError(Exception):
    pass


def load_metadata(path: Path) -> dict:
    try:
        metadata = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RegistryError(f"{path}: {error}") from error
    shape = "{retainFromPluginKit, plugins: {<Target>: {name, iconName}}}"
    plugins = metadata.get("plugins") if isinstance(metadata, dict) else None
    if not isinstance(plugins, dict) or not _is_int(metadata.get("retainFromPluginKit")):
        raise RegistryError(f"{path} is not in the {shape} shape")
    for target, entry in plugins.items():
        if not isinstance(entry, dict) or not all(isinstance(entry.get(key), str) for key in ("name", "iconName")):
            raise RegistryError(f"{path}: {target} needs a name and an iconName, as in {shape}")
    return metadata


def bundled_targets(project: str) -> Set[str]:
    block = re.search(r"^aggregateTargets:\n(?:^(?: .*)?\n)*?^  BundledPlugins:\n^    targets:\n((?:^      - .*\n)+)",
                      project, re.MULTILINE)
    if block is None:
        raise RegistryError("project.yml has no BundledPlugins aggregate with a targets list")
    return {line.strip()[2:].strip() for line in block.group(1).splitlines()}


def publish_set(metadata: dict, bundled: Set[str]) -> List[str]:
    targets = sorted(metadata["plugins"])
    inside = [target for target in targets if target in bundled]
    if inside:
        raise RegistryError(f"the app bundles {', '.join(inside)}, so the registry must not publish them")
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
    type_ids = info.get(PROVIDES[0], [])
    if not isinstance(type_ids, list) or not all(isinstance(type_id, str) for type_id in type_ids):
        problems.append(f"{PROVIDES[0]} is not a list of strings")
    # The app finds the plugin that serves a database type or a file format through these keys.
    if not any(info.get(key) for key in PROVIDES):
        problems.append(f"it declares none of {', '.join(PROVIDES)}")
    if problems:
        raise RegistryError(f"{archive.name}: " + "; ".join(problems))
    return {
        "id": identifier,
        "name": entry["name"],
        "iconName": entry["iconName"],
        "databaseTypeIds": type_ids,
        "version": release,
        "build": build,
        "pluginKit": kit,
        "minimumSystemVersion": system,
        "file": archive.name,
        "sha256": _sha256(archive),
    }


def describe(zips: Path, release: str, build: int, kit: int, metadata: dict, bundled: Set[str]) -> List[dict]:
    entries = []
    for target in publish_set(metadata, bundled):
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


def _check_entry(entry: dict, channel: str) -> None:
    missing = [key for key in ("id", "name", "iconName", "databaseTypeIds", "version", "build", "pluginKit",
                               "minimumSystemVersion", "file", "sha256") if key not in entry]
    if missing:
        raise RegistryError(f"an entry has no {', '.join(missing)}")
    if not SHA256.fullmatch(str(entry["sha256"])):
        raise RegistryError(f"{entry['id']}: sha256 {entry['sha256']!r} is not 64 lowercase hex digits")
    parsed = version.parse_version(entry["version"])
    if parsed.build != entry["build"]:
        raise RegistryError(f"{entry['id']}: build {entry['build']} is not {parsed.build}, the build of {parsed}")
    if parsed.channel != channel:
        raise RegistryError(f"{entry['id']}: {parsed} belongs to the {parsed.channel} channel, not {channel}")


def add(path: Path, entries: List[dict], channel: str, url_base: str, retain_from: int,
        log: Callable[[str], None] = print) -> bool:
    if channel not in CHANNELS:
        raise RegistryError(f"channel {channel!r} is not one of {', '.join(CHANNELS)}")
    if not url_base.startswith("https://"):
        raise RegistryError(f"the URL base {url_base!r} is not https")
    for entry in entries:
        _check_entry(entry, channel)
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
            plugin.update({key: entry[key] for key in ("name", "iconName", "databaseTypeIds")})

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
    keys = ("id", "name", "iconName", "databaseTypeIds")
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
    command.add_argument("--project", type=Path, default=PROJECT)
    command = commands.add_parser("describe", help="read the built plugin zips into manifest entries")
    command.add_argument("--zips", type=Path, required=True)
    command.add_argument("--version", required=True)
    command.add_argument("--build", type=int, required=True)
    command.add_argument("--kit", type=int, required=True)
    command.add_argument("--metadata", type=Path, required=True)
    command.add_argument("--project", type=Path, default=PROJECT)
    command.add_argument("--out", type=Path, required=True)
    command = commands.add_parser("add", help="add described releases to the manifest")
    command.add_argument("--manifest", type=Path, required=True)
    command.add_argument("--entries", type=Path, required=True)
    command.add_argument("--channel", choices=CHANNELS, required=True)
    command.add_argument("--url-base", required=True)
    command.add_argument("--retain-from", type=int, required=True)
    command = commands.add_parser("withdraw", help="remove one version's releases from the manifest")
    command.add_argument("--manifest", type=Path, required=True)
    command.add_argument("--version", required=True)
    args = parser.parse_args(argv)

    try:
        if args.command == "targets":
            bundled = bundled_targets(args.project.read_text(encoding="utf-8"))
            print("\n".join(publish_set(load_metadata(args.metadata), bundled)))
        elif args.command == "describe":
            bundled = bundled_targets(args.project.read_text(encoding="utf-8"))
            entries = describe(args.zips, args.version, args.build, args.kit, load_metadata(args.metadata), bundled)
            args.out.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
            print(f"described {len(entries)} plugins in {args.out}")
        elif args.command == "add":
            entries = json.loads(args.entries.read_text(encoding="utf-8"))
            if not isinstance(entries, list):
                raise RegistryError(f"{args.entries} is not a list of entries")
            changed = add(args.manifest, entries, args.channel, args.url_base, args.retain_from)
            print(f"{args.manifest} {'updated' if changed else 'unchanged'}")
        elif args.command == "withdraw":
            withdraw(args.manifest, args.version)
    except (RegistryError, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
