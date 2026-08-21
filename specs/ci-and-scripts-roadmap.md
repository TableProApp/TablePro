# CI and scripts roadmap

Tracks the audit of every GitHub Actions workflow and every script under `scripts/`, and what is
left to do.

The audit read all workflows (1,488 lines of YAML), the composite actions, both Python tools and all
43 shell scripts (7,174 lines), and produced 125 findings: 4 critical, 31 high, 53 medium, 37 low.
Each finding above medium was then handed to an independent reviewer told to refute it; 34 of 35
survived, and the one that was refuted is recorded below so nobody acts on it later.

Numbers in this file are measured, not estimated. Where a number came from a specific CI run or a
local build, the source is named.

## The headline

The macOS test suite took **61.1 minutes**, all of it in one serial job. Measured from run
`32473179239` and the two `.xcresult` bundles it uploads:

| | |
| --- | --- |
| compile every plugin | 3.5 min |
| unit tests (build + run) | 15.3 min |
| UI tests | 38.8 min |
| everything else | 3.5 min |

Three root causes, all measured:

1. **11.0 minutes** of the UI suite was one XCUITest retry. 66 of 85 tests opened the sample
   database through the Help menu; the first click failed every time with
   `open menu during menu traversal`, waited out a ten second watchdog, then retried and succeeded.
2. **~12 of the unit step's 15.3 minutes was compiling.** All 12,662 unit cases execute in
   **206 seconds**; the rest was building the app and both test bundles, then throwing that away.
3. Everything ran in one job, so nothing overlapped.

The app itself is not slow: a cold launch to a visible welcome window measures 0.51s, and to a
connected sample-database window 1.02s.

## Shipped

| PR | | |
| --- | --- | --- |
| #2325 | UI harness: the ten second menu retry, the `waitForExistence` floor, the typing | merged |
| #2326 | Three more menu call sites resolved without opening the parent | merged |
| #2328 | Build once, test on four runners, shards derived from `xcodebuild` | merged |
| #2329 | Plugin tag validation, every action pinned to a SHA, token scope | merged |
| #2330 | Release build matrix, appcast history, guards that could not fail | merged |
| #2331 | Plugin release manifest, seven drifted icons, idempotent publish | merged |
| #2333 | Script defects and the `shellcheck` / `actionlint` gate | merged |
| #2334 | Test jobs need the OpenSSL dylibs the app links through an absolute rpath | merged |
| #2336 | `scripts/lib/`, one shared set of helpers for the native builds | merged |

Verified after merge:

- `actionlint`, with its shellcheck integration over every inline `run:` block, is clean across all
  six workflows. It reported six findings before this work.
- `shellcheck --severity=warning` is clean across all 43 scripts. It reported twelve before.
- `build.yml` went from 414 lines to 314, `build-plugin.yml` from 520 to 396, and the native library
  build scripts lost 496 lines to a 238-line shared library.
- The plugin manifest and its drift check ran on a real bulk release (17 registry plugins) and the
  derived plugin list matched the hand-maintained arrays it replaced, exactly.

## Not yet proven

- [ ] **The 61 to ~25 minute claim has never been observed end to end.** No sharded run has yet gone
      green: the first one failed on the missing dylibs (#2334 fixed that), and every run since has
      queued behind the account's five concurrent macOS job cap. The only measured part is
      `Build for testing` at **20.5 minutes**, which matched its projection and passed.
      Treat the total as a projection until a green run says otherwise.

## Open work

### Needs a person, not a commit

- [ ] **Turn on branch protection for `main`.** `gh api repos/TableProApp/TablePro/branches/main/protection`
      returns 404. The `changes` plus `gate` design in `macos-tests.yml` and `ios-tests.yml` is
      carefully built to report on every pull request so it can be a required check, and nothing
      requires it, so today it is decoration. This is why #2328 could merge while its own CI was
      still running and leave `main` red. Mark `macOS Tests Gate` required, not `macOS App Tests`:
      the gate is the job that exists to be the single required check.

### Correctness

- [ ] **`build-cassandra.sh` skips the build whenever the artifact already exists**, which makes the
      CI step a guaranteed no-op. `Libs/` is populated by `download-libs.sh`, so the guard is always
      satisfied. (high)
- [ ] **`localization.py verify` is red today.** The macOS catalog gained a trailing newline that
      `serialize()` strips. Fix the file and whatever keeps adding the newline, not `serialize()`.
      (high, confirmed by running it)
- [ ] **`check-doc-symbols.sh` cannot detect the drift class it exists for**: its symbol index
      indexes comments and string literals, not declarations. It passes today (263 references check
      out), which is not evidence it works. (high)
- [ ] **`ios/build-libpq-ios.sh` silently drops a source file it cannot find**, and lists two files
      twice. (medium)
- [ ] **`install-plugin-dev.sh` picks an arbitrary DerivedData directory with `head -n 1`**, which in
      a repo with several worktrees routinely means somebody else's build. (medium)
- [ ] **`check-redis-command-routing.sh` can silently drop 115 of its 151 entries** and still report
      that the curated table matches the server. (medium)
- [ ] **`verify-build.sh` verifies 3 of the 14 plugins** `project.yml` embeds. (medium)
- [ ] **The ZIP rename in the release job is a string match with no `else`**, and every layer below
      it also skips silently. (medium)
- [ ] **`test_update_registry.py` never exercises the merge path**, which is the behaviour the
      retention policy depends on. (medium)

### Security and supply chain

- [ ] **iOS xcframeworks are downloaded and linked with no integrity check at all**, in CI included,
      while the macOS archive beside them is verified against a git baseline. Doing this properly
      needs a committed `Libs/ios/checksums.sha256`, a publisher that regenerates it under the
      stale-checkout guard `publish-libs.sh` already has, and a rewrite of the manual upload snippet
      in CLAUDE.md that currently bypasses all of it. The baseline must be captured from git *before*
      extraction, the way `download-libs.sh` already does for macOS, and the check must run against
      whatever is on disk at the end rather than only on a cold download, because `actions/cache`
      restores `Libs/.downloaded` and short-circuits it. (high)
- [ ] **The Sparkle EdDSA private key is written to disk beside an unpinned Homebrew cask install.**
      Pin Sparkle to 2.9.5 with a SHA-256 check, matching the framework already pinned in
      `Package.resolved`, using the `setup-xcodegen` pattern. (high)
- [ ] **iOS DuckDB compiles two unpinned upstream refs into a shipped App Store binary.** Pin `quack`
      to a commit SHA the way `httpfs` already is, taking it from the `v1.5-variegata` line so its
      DuckDB submodule matches `DUCKDB_VERSION`. (high)
- [ ] **`publish-libs.sh` packs `Libs/ios` and `Libs/dylibs` into the macOS archive**, republishing
      about 78 MB of iOS frameworks it never checked. Publish exactly the set the checksum guard
      covers, as an allowlist. (high)
- [ ] **A personal Apple ID is hardcoded in a tracked file.** `scripts/build-release.sh` still
      carries `APPLE_ID="${APPLE_ID:-datngoquoc@icloud.com}"`, and it is dead code: the release path
      uses `--keychain-profile`. (medium)
- [ ] **`ANALYTICS_HMAC_SECRET` is passed on the `xcodebuild` argv**, unquoted, and is redundant.
      (medium)
- [ ] **`publish-libs.sh` and `check-redis-command-routing.sh` use fixed `/tmp` paths** where every
      sibling uses `mktemp`. `/tmp` is world-writable, so another local user can own the tree first.
      (medium)

### Duplication and structure

- [ ] **`build-release.sh` is 695 lines and holds four near-identical `prepare_*` functions** that do
      the same job as `scripts/ci/prepare-libs.sh`, and the two disagree about whether to copy the
      per-architecture slice or thin the universal one. That is 163 lines that should be about 35.
      Splitting the file needs care: the signing order (deep-sign frameworks and plugins, then the
      app, then notarize, then staple) must not be broken. (medium)
- [ ] **Three notarize-and-staple implementations at three different rigor levels**, in
      `build-release.sh`, `create-dmg.sh` and `build-plugin.sh`. (medium)
- [ ] **The Xcode version and the `setup-xcode` SHA are repeated eight times across the workflows.**
      A `setup-macos-build` composite action would also absorb the checkout, `Libs` cache,
      `download-libs.sh`, `Secrets.xcconfig`, XcodeGen and package resolution, which appear in whole
      or in part in all four. (medium)
- [ ] **The changes detector and the gate step are copy-pasted between `macos-tests.yml` and
      `ios-tests.yml`**, with a comment asking a human to keep the two path lists in step and nothing
      enforcing it. Extract to `scripts/ci/detect-changed-paths.sh` taking the prefixes as arguments.
      (medium)
- [ ] **`build-plugin.sh` is invoked once per architecture**, so project generation and a full
      DerivedData build run twice per plugin. (medium, performance)
- [ ] **`create-dmg.sh` carries a 77-line `hdiutil` fallback that has never run in a release**, and
      has no cleanup trap, so a failure leaves a mounted volume and a temp DMG behind. (medium)
- [ ] **`build-freetds.sh` has no cleanup trap** and leaks four temp directories per run.
      It and `build-cassandra.sh` use fixed `/tmp` build roots. Note before changing these: FreeTDS
      caches its downloaded tarball at that fixed path, so a per-run `mktemp -d` loses the cache.
      Decide that trade deliberately. (medium)
- [ ] **`cleanup` is defined in ten scripts.** Each is one to three lines. A shared
      `make_build_dir` that sets `BUILD_DIR` and installs the trap would replace them, but it has to
      resolve the FreeTDS caching question above first.

### Coverage and dead tooling

- [ ] **Nothing loads the built `.tableplugin` before publishing it**, only builds and signs it.
      "Bundle failed to load executable" is the failure this repo has shipped twice.
- [ ] **`check-pluginkit-abi.sh` guards the repo's most expensive documented invariant and no longer
      runs in CI.** It also carries dead plumbing from when it did: an `ABI_ACKNOWLEDGED_ADDITIVE`
      branch nothing can set. Decide whether to restore the gate or delete the plumbing; do not do
      both. (high)
- [ ] **`check-mongodb-filter-shapes.sh` is referenced nowhere** and its 27 shapes are hand-copied
      from the builder with nothing keeping them in step. (medium)
- [ ] **`audit-refactor-health.sh` is orphaned**: its CI job was deleted, the roadmap it points at
      never existed, and its main gate is permanently satisfied. Delete it or give it a job. (medium)
- [ ] **33 unit suites are still quarantined** in `.github/macos-test-quarantine.txt`, roughly 537
      test cases. The file says "burn this list down". #2333 added a check that fails when an entry
      no longer names a real suite, which stops the list rotting, but has not shortened it.
- [ ] **Nothing measures CI duration or surfaces a slow test.** `grep -rn GITHUB_STEP_SUMMARY` finds
      nothing in the repo, and the two `.xcresult` bundles are uploaded and never read. A
      `summarize-xcresult` step writing a duration and slowest-20 table to `$GITHUB_STEP_SUMMARY` is
      the cheap version, and it is what would have shown the ten second retry years earlier.

### UI test suite

- [ ] **85 test methods launch 85 app processes.** Assertions that observe one screen state are
      never shared. Merging them per class is worth roughly a third of the remaining UI time. One
      caveat: `UITestCase` sets `continueAfterFailure = false`, so a merged block of independent
      read-only assertions aborts at the first failure and hides the rest; set it `true` in any
      method that merges them.
- [ ] **In-process parallel testing cannot be turned on as the suite stands.** Three things are
      shared per machine: the single `com.TablePro.uitest` defaults domain, the preferences sweep in
      `UITestCase`'s class setup, and the menu bar, which belongs to whichever app is frontmost.
      Sharding across runners, which is what #2328 does, sidesteps all three.
- [ ] **`InspectorToolbarPlacementUITests` has never run on CI and cannot.** It needs a screen at
      least 1512pt wide and the runner is 1024x768. It gates nothing today. Either set the runner
      resolution, re-express the assertion so it does not need the width, or record it in the UI
      quarantine file with its reason.

### Packaging

- [ ] **A Debug build of the app depends on a path inside the source tree at runtime.**
      `project.yml` puts `$(SRCROOT)/Libs/dylibs` on `LD_RUNPATH_SEARCH_PATHS`, so an absolute path
      is baked into the binary, and `TablePro.debug.dylib` links `@rpath/libssl.3.dylib` and
      `@rpath/libcrypto.3.dylib` which are not copied into the bundle. #2334 worked around this by
      restoring `Libs` in the test jobs and asserting the two files exist. The root fix is to copy
      them into `Contents/Frameworks` the way Sparkle and TableProPluginKit already are, which makes
      the bundle self-contained and removes the absolute rpath.

## Refuted, do not act on

- **"`minAppVersion` should be read from the plugin's own Info.plist rather than
  `Configs/Version.xcconfig`."** Refuted. `TableProMinAppVersion` in a plugin's Info.plist is a
  hand-declared *feature* floor that only 7 of 31 plugins carry; the registry's `minAppVersion` is a
  different fact. Making the change would reintroduce the "Bundle failed to load executable" failure
  CLAUDE.md dedicates two paragraphs to.

## Notes for whoever picks this up

- The native library build scripts run by hand, not in CI, so nothing catches a regression in them.
  Migrate and change them one at a time and **run each one**, then compare the produced `.a` against
  the published copy for architecture, deployment target and symbol count. That is how #2336 was
  verified for `build-hiredis.sh` and `build-libssh2.sh`. `build-libpq.sh` and `build-libmongoc.sh`
  were migrated in the same PR but have not been built end to end yet; do that before the next
  library bump.
- `Libs/libssh2.a` and `Libs/libduckdb.a` are symlinks to their `_universal` counterparts. Copying a
  file onto a symlink that points at the source truncates it, which is why `make_universal` carries
  an `-ef` guard.
- After building any library locally, restore with `scripts/download-libs.sh --force` and check the
  result against `git show HEAD:Libs/checksums.sha256`, so a locally built artifact is never left in
  a shared checkout.
- The account runs **five concurrent macOS jobs**, shared across every workflow and every branch.
  One sharded test run wants up to five of them, so several open pull requests queue behind each
  other. If that becomes the bottleneck in practice, dropping the UI matrix from three shards to two
  lowers the peak to three jobs and still leaves each shard well under the old 38.8 minutes.
