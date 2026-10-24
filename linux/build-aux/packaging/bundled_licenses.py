#!/usr/bin/env python3
# Adds the licenses of C and C++ code a crate compiles from its own copy
# of another project to data/licenses. cargo-about reads only the crate's
# license file, and libduckdb-sys packs DuckDB's third_party code, whose
# licenses are not in the crate, into one archive. Each folder under
# build-aux/about/bundled names a crate version and holds those texts as
# the bundled project ships them.

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import license_metadata  # noqa: E402

SECTION = "## Code compiled into crates"
SECTION_INTRO = (
    "These crates compile C and C++ code from other projects into TablePro. "
    "Each project is listed under the license it is used under, with the "
    "file its text comes from."
)


class BundledError(Exception):
    pass


def load_bundles(root):
    bundles = []
    for manifest_path in sorted(Path(root).glob("*/manifest.json")):
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        components = []
        for component in manifest["components"]:
            text = (manifest_path.parent / component["file"]).read_text(encoding="utf-8")
            components.append({**component, "text": text})
        bundles.append({**manifest, "components": components})
    return bundles


def combined_expression(expressions):
    nodes = [license_metadata.parse_expression(expression) for expression in expressions]
    return license_metadata.spdx(license_metadata.combine("and", nodes))


def merge_json(data, bundles):
    # Records added by an earlier run are dropped first, so a second run
    # writes the same file.
    data["licenses"] = [record for record in data["licenses"] if "component" not in record]
    crates = {crate["name"]: crate for crate in data["crates"]}
    for bundle in bundles:
        crate = crates.get(bundle["crate"])
        if crate is None:
            raise BundledError(f"{bundle['crate']} is no longer linked; remove build-aux/about/bundled/{bundle['crate']}")
        if crate["version"] != bundle["version"]:
            raise BundledError(
                f"build-aux/about/bundled/{bundle['crate']} is for {bundle['version']}, but {crate['version']} is "
                "linked; take the license files of the code the new version bundles"
            )
        for component in bundle["components"]:
            data["licenses"].append(
                {
                    "id": component["id"],
                    "name": component["license_name"],
                    "text": component["text"],
                    "used_by": [{"crate": {"name": crate["name"], "version": crate["version"]}}],
                    "component": component["name"],
                }
            )
        crate["license"] = combined_expression(
            [crate["license"]] + [component["license"] for component in bundle["components"]]
        )
    return data


def render_section(bundles):
    lines = [SECTION, "", SECTION_INTRO]
    for bundle in bundles:
        for component in bundle["components"]:
            lines += [
                "",
                f"### {component['name']}: {component['license_name']}",
                "",
                f"Compiled into {bundle['crate']} {bundle['version']}, from `{component['path']}` in {bundle['source']}.",
                "",
                "~~~~text",
                component["text"].rstrip("\n"),
                "~~~~",
            ]
    return "\n".join(lines) + "\n"


def scalar(value):
    return json.dumps(value, ensure_ascii=False)


def render_json(data):
    # The layout of build-aux/about/third-party.json.hbs, so a crate change
    # shows as the lines it changes.
    records = []
    for record in data["licenses"]:
        used_by = ",\n".join(
            f'        {{ "crate": {{ "name": {scalar(used["crate"]["name"])}, '
            f'"version": {scalar(used["crate"]["version"])} }} }}'
            for used in record["used_by"]
        )
        fields = [f'      "{key}": {scalar(record[key])}' for key in ("id", "name", "text")]
        if "component" in record:
            fields.append(f'      "component": {scalar(record["component"])}')
        fields.append(f'      "used_by": [\n{used_by}\n      ]')
        records.append("    {\n" + ",\n".join(fields) + "\n    }")
    crates = ",\n".join(
        f'    {{ "name": {scalar(crate["name"])}, "version": {scalar(crate["version"])}, '
        f'"license": {scalar(crate["license"])} }}'
        for crate in data["crates"]
    )
    return (
        '{\n  "licenses": [\n' + ",\n".join(records) + '\n  ],\n  "crates": [\n' + crates + "\n  ]\n}\n"
    )


def merge_notice(notice, bundles):
    kept = notice.split(f"\n{SECTION}\n", 1)[0].rstrip("\n")
    return f"{kept}\n\n{render_section(bundles)}"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Add the licenses of code crates bundle to data/licenses.")
    parser.add_argument("--bundled", required=True)
    parser.add_argument("--licenses", required=True)
    parser.add_argument("--notice", required=True)
    args = parser.parse_args(argv)

    try:
        bundles = load_bundles(args.bundled)
        licenses = Path(args.licenses)
        notice = Path(args.notice)
        data = merge_json(json.loads(licenses.read_text(encoding="utf-8")), bundles)
        merged_notice = merge_notice(notice.read_text(encoding="utf-8"), bundles)
    except (OSError, KeyError, ValueError, license_metadata.MetadataError, BundledError) as error:
        print(f"bundled_licenses.py: {error}", file=sys.stderr)
        return 1

    licenses.write_text(render_json(data), encoding="utf-8")
    notice.write_text(merged_notice, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
