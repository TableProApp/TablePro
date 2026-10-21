#!/usr/bin/env python3
import argparse
import ast
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "apps/linux/po/bookie.pot"
POTFILES = ROOT / "apps/linux/po/POTFILES.in"
TRANSLATION_MACRO = re.compile(
    r"(?<![A-Za-z0-9_])(?:[A-Za-z_][A-Za-z0-9_]*::)*tr!(?=\s*(?:\(|\{|\[))"
)
TRANSLATION_CALL = re.compile(r"(?<![A-Za-z0-9_])(?:[A-Za-z_][A-Za-z0-9_]*::)*tr!\s*\(\s*")
RUST_STRING = re.compile(r'"(?:\\.|[^"\\])*"', re.DOTALL)
CATALOG_DATE = re.compile(r'(?m)^"POT-Creation-Date: [^"\n]*\\n"$')


def translation_sources(root=ROOT):
    source_root = root / "apps/linux/app/src"
    return tuple(
        path
        for path in sorted(source_root.rglob("*.rs"))
        if TRANSLATION_MACRO.search(path.read_text(encoding="utf-8"))
    )


def extraction_source(source):
    lines = [[] for _ in source.splitlines()]
    for match in TRANSLATION_CALL.finditer(source):
        literal = RUST_STRING.match(source, match.end())
        if literal is None:
            raise RuntimeError("translation calls must start with a string literal")
        rust_string = re.sub(r"\\\n[ \t]*", "", literal.group())
        rust_string = re.sub(r"\\u\{([0-9a-fA-F]{1,6})\}", lambda item: f"\\U{int(item.group(1), 16):08x}", rust_string)
        message = ast.literal_eval(rust_string)
        line = source.count("\n", 0, literal.start())
        lines[line].append(f"tr({json.dumps(message, ensure_ascii=False)})")
    return "\n".join("; ".join(items) for items in lines) + "\n"


def normalize_catalog(catalog):
    catalog = CATALOG_DATE.sub(lambda _: '"POT-Creation-Date: 1970-01-01 00:00+0000\\n"', catalog)
    return catalog.replace('"Content-Type: text/plain; charset=CHARSET\\n"', '"Content-Type: text/plain; charset=UTF-8\\n"')


def package_version(root):
    manifest = tomllib.loads((root / "apps/linux/app/Cargo.toml").read_text(encoding="utf-8"))
    version = manifest["package"]["version"]
    if isinstance(version, dict) and version.get("workspace") is True:
        workspace = tomllib.loads((root / "Cargo.toml").read_text(encoding="utf-8"))
        return workspace["workspace"]["package"]["version"]
    return version


def generate_catalog(root=ROOT):
    files = translation_sources(root)
    relative_paths = [path.relative_to(root).as_posix() for path in files]
    if not files:
        raise RuntimeError("no Rust translation source files found")
    with tempfile.TemporaryDirectory(prefix="bookie-gettext-") as temporary:
        stage = Path(temporary)
        for source in files:
            target = stage / source.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(extraction_source(source.read_text(encoding="utf-8")), encoding="utf-8")
        generated = stage / "bookie.pot"
        environment = dict(os.environ, LC_ALL="C", LANG="C", TZ="UTC", SOURCE_DATE_EPOCH="0")
        subprocess.run(
            [
                "xgettext",
                "--language=Python",
                "--keyword=tr",
                "--from-code=UTF-8",
                "--no-wrap",
                "--package-name=BookiE",
                f"--package-version={package_version(root)}",
                "--copyright-holder=BookiE contributors and TablePro Authors",
                "--msgid-bugs-address=https://github.com/cozyGarage/BookiE/issues",
                f"--output={generated}",
                *relative_paths,
            ],
            cwd=stage,
            env=environment,
            check=True,
        )
        catalog = normalize_catalog(generated.read_text(encoding="utf-8")).replace(
            "#, python-brace-format", "#, rust-format"
        )
    potfiles = "\n".join(relative_paths) + "\n"
    return catalog, potfiles


def write_outputs(catalog_path, potfiles_path, catalog, potfiles):
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    for path, content in ((catalog_path, catalog), (potfiles_path, potfiles)):
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(content, encoding="utf-8", newline="")
        temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description="Generate the gettext template (bookie.pot) and source list.")
    parser.add_argument("--check", action="store_true", help="only verify that the template can be generated; write nothing")
    parser.add_argument("--output-dir", type=Path, help="write bookie.pot and POTFILES.in here instead of apps/linux/po")
    args = parser.parse_args()
    try:
        catalog, potfiles = generate_catalog()
    except (OSError, RuntimeError, subprocess.CalledProcessError, KeyError) as error:
        print(f"translation template generation failed: {error}", file=sys.stderr)
        return 1
    if args.check:
        print("translation template: ok")
        return 0
    directory = args.output_dir
    catalog_path = directory / CATALOG.name if directory else CATALOG
    potfiles_path = directory / POTFILES.name if directory else POTFILES
    write_outputs(catalog_path, potfiles_path, catalog, potfiles)
    print(f"translation template written to {catalog_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
