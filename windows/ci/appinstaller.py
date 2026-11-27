#!/usr/bin/env python3
# A Windows release's package version and channel, and the App Installer file that installs its .msixbundle and
# keeps the install on its channel (windows/docs/decisions/0020-app-installer-updates.md). release-windows.yml runs it.

import argparse
import pathlib
import re
import sys
import xml.etree.ElementTree as ElementTree
import zipfile

SITE = "https://updates.tablepro.app/windows/"
FILES = {"stable": "TablePro.appinstaller", "beta": "TablePro-Beta.appinstaller"}
# The 2017/2 schema is the one Microsoft.Windows.SDK.BuildTools.MSIX's own template writes; its OnLaunch
# HoursBetweenUpdateChecks and AutomaticBackgroundTask arrived in Windows 10 1803, below the app's 1809 floor.
NAMESPACE = "http://schemas.microsoft.com/appx/appinstaller/2017/2"
BUNDLE_NAMESPACE = "{http://schemas.microsoft.com/appx/2013/bundle}"
# As often as the macOS app's Sparkle checks (SUScheduledCheckInterval, 86400 s).
HOURS_BETWEEN_CHECKS = 24
# The fourth number: N for beta.N, and above every beta for the release.
RELEASE_REVISION = 99
LAST_BETA = RELEASE_REVISION - 1

VERSION = re.compile(r"(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})(?:-beta\.([1-9][0-9]?))?")


def package_version(version: str) -> tuple[str, str]:
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError(f"'{version}' is not X.Y.Z or X.Y.Z-beta.N")
    numbers = [int(part) for part in match.group(1, 2, 3)]
    if any(number > 65535 for number in numbers):
        raise ValueError(f"{version} has a number above 65535")
    beta = match.group(4)
    if beta is not None and int(beta) > LAST_BETA:
        raise ValueError(f"{version}: a beta is numbered 1 to {LAST_BETA}")
    revision = int(beta) if beta is not None else RELEASE_REVISION
    return ".".join(str(number) for number in [*numbers, revision]), "beta" if beta is not None else "stable"


def channel_uri(channel: str) -> str:
    return SITE + FILES[channel]


def bundle_identity(bundle: pathlib.Path) -> dict[str, str]:
    with zipfile.ZipFile(bundle) as archive:
        manifest = ElementTree.fromstring(archive.read("AppxMetadata/AppxBundleManifest.xml"))
    identity = manifest.find(f"{BUNDLE_NAMESPACE}Identity")
    if identity is None:
        raise ValueError(f"{bundle} has no bundle identity")
    return {key: identity.attrib[key] for key in ("Name", "Publisher", "Version")}


# App Installer reads only ASCII with no escapes (the AppInstaller element's schema page, Remarks).
def plain(name: str, value: str) -> str:
    if not value or any(not 32 <= ord(char) < 127 or char in '"&<>' for char in value):
        raise ValueError(f"{name} '{value}' needs characters an App Installer file cannot hold")
    return value


# Windows updates a release install by itself. A beta install it leaves to the app's own check: Windows never
# moves an install to a lower version, so a tester who goes back to Stable would keep getting betas from it.
def appinstaller(identity: dict[str, str], bundle_uri: str, uri: str, channel: str) -> str:
    version = plain("Version", identity["Version"])
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<AppInstaller xmlns="{NAMESPACE}" Version="{version}" Uri="{plain("Uri", uri)}">',
        f'  <MainBundle Name="{plain("Name", identity["Name"])}" Publisher="{plain("Publisher", identity["Publisher"])}"'
        f' Version="{version}" Uri="{plain("bundle Uri", bundle_uri)}" />',
    ]
    if channel == "stable":
        lines += [
            "  <UpdateSettings>",
            f'    <OnLaunch HoursBetweenUpdateChecks="{HOURS_BETWEEN_CHECKS}" />',
            "    <AutomaticBackgroundTask />",
            "  </UpdateSettings>",
        ]
    return "\n".join([*lines, "</AppInstaller>", ""])


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def read(path: pathlib.Path) -> tuple[dict[str, str], str]:
    main = ElementTree.fromstring(path.read_bytes()).find(f"{{{NAMESPACE}}}MainBundle")
    if main is None:
        raise ValueError(f"{path} names no main bundle")
    return {key: main.attrib[key] for key in ("Name", "Publisher", "Version")}, main.attrib["Uri"]


# The beta channel carries the newest build of either channel, as the macOS beta feed carries every stable item.
def channels(release: pathlib.Path, site: pathlib.Path) -> list[pathlib.Path]:
    identity, bundle_uri = read(release)
    revision = version_key(identity["Version"])[3]
    written = []
    for channel in ["stable", "beta"] if revision == RELEASE_REVISION else ["beta"]:
        target = site / FILES[channel]
        if target.exists():
            published = read(target)[0]["Version"]
            if version_key(published) > version_key(identity["Version"]):
                if channel == "beta" and revision == RELEASE_REVISION:
                    continue
                raise ValueError(f"{target} already names {published}, above {identity['Version']}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(appinstaller(identity, bundle_uri, channel_uri(channel), channel).encode("ascii"))
        written.append(target)
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    version = commands.add_parser("version", help="print the package version, channel and App Installer file name")
    version.add_argument("version", help="the release's version, such as 0.2.0 or 0.2.0-beta.1")
    write = commands.add_parser("write", help="write the App Installer file for a release's bundle")
    write.add_argument("--version", required=True, help="the release's version, such as 0.2.0 or 0.2.0-beta.1")
    write.add_argument("--bundle", required=True, type=pathlib.Path, help="the .msixbundle the release publishes")
    write.add_argument("--bundle-uri", required=True, help="where the release publishes that bundle")
    write.add_argument("--uri", help="where the file lives; the version's channel file by default")
    write.add_argument("--out", required=True, type=pathlib.Path, help="the file to write")
    publish = commands.add_parser("channels", help="move the channel files a release's App Installer file belongs to")
    publish.add_argument("--release", required=True, type=pathlib.Path, help="the App Installer file the release ships")
    publish.add_argument("--site", required=True, type=pathlib.Path, help="the folder served as " + SITE)
    args = parser.parse_args()

    try:
        if args.command == "channels":
            for path in channels(args.release, args.site):
                print(path)
            return
        package, channel = package_version(args.version)
        if args.command == "version":
            print(f"package={package}\nchannel={channel}\nappinstaller={FILES[channel]}")
            return
        identity = bundle_identity(args.bundle)
        if identity["Version"] != package:
            raise ValueError(f"{args.bundle} is version {identity['Version']}, not {package}")
        text = appinstaller(identity, args.bundle_uri, args.uri or channel_uri(channel), channel)
    except (ValueError, KeyError, OSError, ElementTree.ParseError, zipfile.BadZipFile) as error:
        sys.exit(f"appinstaller.py: {error}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(text.encode("ascii"))
    print(args.out)


if __name__ == "__main__":
    main()
