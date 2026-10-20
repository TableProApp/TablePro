# Platform: Apple

The macOS app and the iOS app, with everything they build from. Every profile has these seven sections in this order, so a value is always in the same place.

## Covers

- A report from macOS or iOS.
- Code: `apple/TablePro/`, `apple/Plugins/`, `apple/Packages/`, `apple/Native/`, `apple/TableProMobile/` and the build scripts in `apple/scripts/`.
- Tests: `apple/TableProTests/`, `apple/TableProUITests/`, `apple/Plugins/*Tests/`, `apple/Packages/*/Tests/` and `apple/TableProMobile/TableProMobileTests/`. The plans are in `apple/TestPlans/`.
- A fix lands in the app, a bundled plugin, a registry-only plugin (name its target), a package or `apple/TableProMobile/`.

## Base

- Worktree base: `origin/main`.
- Pull request base: `main`.

## Done

- The tree's `apple/AGENTS.md`, the root `AGENTS.md` it points to, and every `.claude/rules/` file whose `paths:` header matches what you edit (`SKILL.md`, Phase 2, Rules read). The per-change checklist is the Every change section of `apple/AGENTS.md`. Under Claude Code, `apple/CLAUDE.md` loads it once a file under `apple/` is read; read it by path anyway in Phase 0.
- Before naming a test in `plan.md`, read `.claude/rules/tests.md` (Where a test goes): a path rule loads only once a matching file is open. Add a UI flow only when `.claude/rules/ui-tests.md` (What earns a UI flow) says so.

## Native standard

- The AppKit or SwiftUI mechanism Apple documents, and the Human Interface Guidelines rule behind it.
- The version floor is the deployment target: macOS 13 (`apple/project.yml`) and iOS 18 (`apple/TableProMobile/project.yml`). An API introduced later needs an `if #available` branch, and the plan names the fallback.
- Sources, the API ground truth and how to build a probe: `references/research-apple.md`.

## Verify

`verify.sh` runs these steps on a Mac without `--platform`. `build`, `test` and `lint` take the arguments in `apple/AGENTS.md`, Commands.

| Step | Arguments | When |
| --- | --- | --- |
| `generate` | none | a new tree; a new, moved or deleted file; an `apple/project.yml` change; first after a merge from the base. Runs `apple/scripts/generate-project.sh` for both projects |
| `build` | AGENTS | always |
| `test` | AGENTS | always, naming the suites that own the types you changed |
| `uitest` | `[Test...]`; none runs the whole UI plan | an end-to-end flow changed or was added |
| `package` | `<Package> [regex]` | `apple/Packages/` changed and you want the whole package; `test <Suite>` already routes a package suite |
| `ios` | `<Suite> [Suite...]`, at least one | `apple/TableProMobile/` or a file it compiles changed |
| `plugins` | none | anything under `apple/Plugins/` changed. Builds `AllPlugins`, building the HANA helper first when it is missing and Go is installed |
| `abi` | `[base]`, default the newest `v*` tag | PluginKit changed (`.claude/rules/plugin-system.md`, ABI) |
| `lint` | AGENTS | every changed Swift file |
| `l10n` | none | strings, or plugin or package messages, changed. Passes only when every plugin and package string, and every string the last build of each app in the tree extracted, is in that app's catalog. Prints the `--add` command for each check that failed |
| `docs` | `[docs-checkout]`, default `tablepro-docs` beside the main checkout | AGENTS Every change 4 applies, or a menu, shortcut, driver list or docs.tablepro.app link changed |

- Pick tests by the types you changed, not the test files you edited: `verify.sh` finds a type name in every test target of the tree.
- Extra review pass: the ABI pass when PluginKit changed.
- Test names, verdicts, the remedies `verify.sh` does not print, and red CI checks: `references/verification-apple.md`.

## Screen

- Launch a Debug build with `TABLEPRO_UI_TEST_SANDBOX` set to a scratch directory, so it never touches the real connections, defaults or keychain. Drive it with `osascript` and capture with `screencapture`; Screen Recording must be granted to whatever runs them.
- A registry-only plugin from the `plugins` step is signed ad hoc, and the plugin signature check refuses it. The app then installs the published plugin in its place, so the shot shows the old behavior. Launch the Debug build with `TABLEPRO_ALLOW_UNSIGNED_PLUGINS=1`, or re-sign the copy in `<sandbox>/TablePro/Plugins/` with the identity `codesign -dvv` prints for the app.
- Reuse the shots in `../tablepro-docs/images/` when a docs page shows that surface.

## Ship

- Stage a string catalog only for the keys you added.
- A fix for a bug on the current beta or stable gets the label `backport release/<X.Y>`.
- A probe worth keeping goes under `apple/scripts/probes/`.
