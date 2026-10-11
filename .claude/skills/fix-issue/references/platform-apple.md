# Platform: Apple

The macOS app and the iOS app, with everything they build from. Every profile has these seven sections in this order, so a value is always in the same place.

## Covers

A report from macOS or iOS. The code is the repository root: `TablePro/`, `Plugins/`, `Packages/`, `Native/`, `TableProMobile/`, the tests in `TableProTests/` and `TableProUITests/`, and the build scripts under `scripts/`. A fix lands in the app, a bundled plugin, a registry-only plugin (name its target) or `TableProMobile`.

## Base

- Worktree base: `origin/main`.
- Pull request base: `main`.

## Done

`AGENTS.md` and the `.claude/rules/` files whose `paths:` match what you edit. The per-change checklist is its "Every change" section. Codex loads `AGENTS.md` and not the rules, so under Codex read the matching rules yourself.

## Native standard

The AppKit or SwiftUI mechanism Apple documents, and the Human Interface Guidelines rule behind it. The version floor is the deployment target, macOS 13: an API introduced later needs an `if #available` branch, and the plan names the fallback.

Sources, the API ground truth and how to build a probe: `references/research-apple.md`.

## Verify

`verify.sh` runs these steps on a Mac without `--platform`:

| Step | When |
| --- | --- |
| `generate` | a new tree; a new, moved or deleted file; `project.yml` |
| `build`, `test <SuiteType>...` | always |
| `uitest <SuiteType>...` | a user flow changed |
| `package <Package> [filter]` | `Packages/` changed |
| `ios <SuiteType>...` | `TableProMobile/` or a file it shares changed |
| `plugins` | `Plugins/` changed |
| `abi <merge-base>` | `TableProPluginKit` changed (commit first) |
| `lint <file>...` | every changed Swift file |
| `l10n` | strings or plugin messages changed |
| `docs [<docs checkout>]` | a paired docs change, or a change to a menu, shortcut, driver list or docs.tablepro.app link |

- The first step after a merge from the base is `generate`.
- Pick suites by the types you changed: `grep -rl <TypeName> TableProTests`.
- Extra review pass: the ABI pass when PluginKit changed.
- Traps and remedies: `references/verification-apple.md`.

## Screen

Launch a Debug build with `TABLEPRO_UI_TEST_SANDBOX` set to a scratch directory, so it never touches real connections. Drive it with `osascript` and capture with `screencapture`; Screen Recording must be granted to whatever runs them. A registry-only plugin cannot load in a sandboxed Debug build; say so when that blocks a shot. Reuse the shots in `../tablepro-docs/images/` when a page shows that surface.

## Ship

- Stage a string catalog only for the keys you added.
- A probe worth keeping goes under `scripts/probes/`.
