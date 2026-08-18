# Build, Libraries, and CI

## Build & Development Commands

```bash
# First-time setup (and after any project.yml / Configs change, or adding a source file)
scripts/download-libs.sh          # static libraries, not in git
scripts/generate-project.sh       # generates both .xcodeproj bundles from project.yml

# Build (development): -skipPackagePluginValidation required for SwiftLint plugin in CodeEditSourceEditor
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation

# Clean build
xcodebuild -project TablePro.xcodeproj -scheme TablePro clean

# Build and run
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation && open build/Debug/TablePro.app

# Release builds
scripts/build-release.sh arm64|x86_64|both

# Lint & format
swiftlint lint                    # Check issues
swiftlint --fix                   # Auto-fix
swiftformat .                     # Format code

# Tests
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProTests/TestClassName
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProTests/TestClassName/testMethodName
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProUITests

# DMG
scripts/create-dmg.sh

# Static libraries (after lib updates)
scripts/download-libs.sh --force  # Re-download and overwrite
```


### Updating Static Libraries

Static libs (`Libs/*.a`) are hosted on the `libs-v1` GitHub Release (not in git). When adding or updating a library:

```bash
# 1. Update the .a files in Libs/ (build scripts write them there)
# 2. Publish: verifies all OTHER local libs still match the checksums at HEAD,
#    regenerates checksums.sha256, uploads the archive. Name every lib you rebuilt.
scripts/publish-libs.sh libmongoc_arm64.a libmongoc_x86_64.a libmongoc_universal.a libmongoc.a
# 3. Commit the updated checksums
git add Libs/checksums.sha256 && git commit -m "build: update static library checksums"
```

Never run `shasum -a 256 Libs/*.a > Libs/checksums.sha256` by hand: regenerating from a stale `Libs/` reverts other libraries silently (this shipped a broken libmongoc and rolled back DuckDB once). `publish-libs.sh` exists to make that impossible.

```bash

# iOS xcframeworks (Libs/ios/*.xcframework)
tar czf /tmp/tablepro-libs-ios-v1.tar.gz -C Libs/ios .
gh release upload libs-v1 /tmp/tablepro-libs-ios-v1.tar.gz --clobber --repo TableProApp/TablePro
```


## CI/CD

GitHub Actions (`.github/workflows/build.yml`) triggered by `v*` tags. The release job needs all five of `lint`, `test`, `build-arm64`, `build-x86_64`, and `registry-readiness`, so a registry missing a compatible plugin binary blocks the tag. Release notes are auto-extracted from `CHANGELOG.md` by `scripts/ci/extract-release-notes.sh`, which matches `## [X.Y.Z]` exactly. Test gating, the quarantine lists, and their traps live in `.claude/skills/fix-issue/references/verification.md`.

**Plugin CI** (`.github/workflows/build-plugin.yml`): triggered by `plugin-*-v*` tags or `workflow_dispatch`. The dispatch input accepts comma-separated `tag:pluginKitVersion` pairs; if `:pluginKitVersion` is omitted, the workflow reads `currentPluginKitVersion` from `PluginManager.swift`. Registry update logic lives in `.github/scripts/update-registry.py` (atomic write, per-binary `pluginKitVersion`, prune-old policy). Use `scripts/release-all-plugins.sh <version>` for bulk re-release after an ABI bump.

**Plugin tag naming**: Tag names must match the CI workflow's `resolve_plugin_info()` mapping. Notable non-obvious mappings: `CloudflareD1DriverPlugin` → `plugin-cloudflare-d1-v*`, `EtcdDriverPlugin` → `plugin-etcd-v*`. Check existing tags with `git tag -l "plugin-*"` before creating new ones.
