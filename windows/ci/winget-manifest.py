#!/usr/bin/env python3
# Writes the winget manifest for one release's .msixbundle, in winget-pkgs' layout and the 1.12 schema its pull
# request template asks for. release-windows.yml runs it; windows/RELEASING.md says when it is submitted.

import argparse
import hashlib
import pathlib
import zipfile

IDENTIFIER = "TablePro.TablePro"
SCHEMA = "1.12.0"
# Package.appxmanifest's TargetDeviceFamily MinVersion, Windows 10 1809.
MINIMUM_OS = "10.0.17763.0"
REPOSITORY = "https://github.com/TableProApp/TablePro"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def header(kind: str) -> list[str]:
    return [f"# yaml-language-server: $schema=https://aka.ms/winget-manifest.{kind}.{SCHEMA}.schema.json", ""]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="the release's version, such as 0.1.0")
    parser.add_argument("--bundle", required=True, type=pathlib.Path, help="the .msixbundle the release publishes")
    parser.add_argument("--url", required=True, help="where the release publishes that bundle")
    parser.add_argument("--family", required=True, help="the package family name the installed bundle reports")
    parser.add_argument("--out", required=True, type=pathlib.Path, help="the folder the manifests/ tree goes in")
    args = parser.parse_args()

    bundle = args.bundle.read_bytes()
    with zipfile.ZipFile(args.bundle) as archive:
        names = archive.namelist()
        # An unsigned bundle, from a run without signing, has no signature to name.
        signature = sha256(archive.read("AppxSignature.p7x")) if "AppxSignature.p7x" in names else None

    installers = []
    for architecture in ("x64", "arm64"):
        installers += [
            f"- Architecture: {architecture}",
            f"  InstallerUrl: {args.url}",
            f"  InstallerSha256: {sha256(bundle)}",
        ]
        if signature:
            installers.append(f"  SignatureSha256: {signature}")

    common = [f"PackageIdentifier: {IDENTIFIER}", f"PackageVersion: {args.version}"]
    files = {
        f"{IDENTIFIER}.yaml": header("version")
        + common
        + ["DefaultLocale: en-US", "ManifestType: version", f"ManifestVersion: {SCHEMA}"],
        f"{IDENTIFIER}.installer.yaml": header("installer")
        + common
        + [
            "Platform:",
            "- Windows.Desktop",
            f"MinimumOSVersion: {MINIMUM_OS}",
            "InstallerType: msix",
            f"PackageFamilyName: {args.family}",
            "Commands:",
            "- tablepro",
            "Installers:",
        ]
        + installers
        + ["ManifestType: installer", f"ManifestVersion: {SCHEMA}"],
        f"{IDENTIFIER}.locale.en-US.yaml": header("defaultLocale")
        + common
        + [
            "PackageLocale: en-US",
            "Publisher: TablePro",
            "PublisherUrl: https://tablepro.app",
            f"PublisherSupportUrl: {REPOSITORY}/issues",
            "PackageName: TablePro",
            "PackageUrl: https://tablepro.app",
            "License: AGPL-3.0",
            f"LicenseUrl: {REPOSITORY}/blob/main/LICENSE",
            "ShortDescription: A native database client.",
            "Moniker: tablepro",
            "Tags:",
            "- database",
            "- sql",
            "- sqlite",
            "- postgresql",
            "- mysql",
            f"ReleaseNotesUrl: {REPOSITORY}/releases/tag/windows-v{args.version}",
            "ManifestType: defaultLocale",
            f"ManifestVersion: {SCHEMA}",
        ],
    }

    folder = args.out / "manifests" / IDENTIFIER[0].lower() / IDENTIFIER.replace(".", "/") / args.version
    folder.mkdir(parents=True, exist_ok=True)
    for name, lines in files.items():
        (folder / name).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(folder)


if __name__ == "__main__":
    main()
