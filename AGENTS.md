# TablePro Engineering Instructions

These instructions are the shared source of truth for Claude Code, Codex, and their subagents.
Tool-specific files may add orchestration details, but they must not weaken these rules.

## Required context

- For any code, test, build, configuration, release, or user-facing documentation change, load and follow `$tablepro-engineering` before editing.
- In Claude Code, for any GitHub issue, defect or feature request alike, load `$fix-issue` instead. It is the specialized form of the same workflow and runs a defect track or a change track, so do not load both. It is Claude-only because its investigation and critique phases run workflow lanes; Codex stays on `$tablepro-engineering` and delegates those lanes with its own worker threads.
- For an independent review or any high-risk change, load and follow `$cross-model-review`.
- For SwiftUI or AppKit view work, read `$swiftui` and apply only rules compatible with TablePro's deployment targets and hybrid architecture.
- Detailed project knowledge lives in `.agents/skills/tablepro-engineering/references/`, split by domain, with `project-guide.md` as its index. Every invariant has its own `####` heading naming the subsystem and the failure it prevents, so search for the symptom or symbol and read the matching paragraph. Do not open a whole file unless the task is a broad architecture audit.
- More specific `AGENTS.md` files and Claude path rules add local constraints for their directories.

## Product and engineering principles

1. Protect user data. Treat query execution, credentials, sync, plugin loading, AI tools, and MCP as security boundaries. Validate inputs and preserve safe-mode, read-only, confirmation, scope, and allowlist checks.
2. Build a native macOS and iOS product. Prefer SwiftUI, AppKit, and system frameworks. Do not add web views or cross-platform UI abstractions for native UI.
3. Fix root causes. Reproduce, trace the real execution path, separate cause from symptom, then choose a targeted fix or refactor based on evidence.
4. Keep architecture clean. Preserve ownership boundaries, dependency direction, protocol seams, actor isolation, and testability. Do not hide a design problem behind a special case.
5. Keep the plugin domain open. `DatabaseType` is a string-backed struct, not an enum. Unknown plugin types must round-trip, and switches over it require a fallback.
6. Measure load-bearing behavior. Probe the actual SDK, C header, static library, database, or generated artifact when source inspection cannot prove behavior the design depends on.
7. Leave unrelated work untouched. The worktree may contain user changes. Never stash, reset, discard, rewrite, or include them without explicit authorization.

## High-compute collaboration

Use available compute aggressively when it improves evidence or catches independent failure modes. This repository optimizes for correctness and coverage, not usage conservation.

Spend it where the output can be thrown away. The main thread holds the problem, the plan, the decisions, and the diff; searching, reading, building, and reviewing belong in subagents, lanes, and log files. Verify a delegated claim at its `file:line` anchor instead of re-reading the file, and route build and test output through a wrapper that stores the log and returns a verdict. A thread that runs out of room mid-implementation loses the plan, which costs more than any lane.

- In Claude Code, use `ultracode`: `xhigh` reasoning plus dynamic workflow orchestration. The workflow size is unrestricted. Scale to all useful independent lanes for broad audits, migrations, and security reviews; do not invent work merely to increase agent count.
- In Codex, run the parent at `ultra`: maximum reasoning with automatic task delegation. Workers run at `max`. Use all 8 configured threads when a broad audit has eight genuinely independent lenses.
- Default lenses are code-path tracing, platform or dependency research, test and failure analysis, architecture challenge, and adversarial correctness or security review.
- The main agent owns requirements, synthesis, the implementation plan, and the final decision. Subagent reports are evidence, not truth. Verify every load-bearing claim in the repository or an authoritative source.
- Use one writer per checkout. Parallel writers require isolated worktrees and non-overlapping file ownership. Never let two agents edit the same files concurrently. When several sessions share a checkout, put the writer in a worktree so the main tree stays readable and uncontested.
- Never run two `xcodebuild` processes concurrently. Parallelize reading and analysis, then serialize generation, builds, tests, and ABI checks.
- Reviewers are read-only. A review leader may orchestrate read-only evidence lanes, but it does not fix findings, commit, push, open pull requests, or start another cross-vendor review.
- Prevent review recursion. One writer may request one primary external review and, for high-risk changes, one adversarial external review. The writer validates and resolves the findings.
- High-risk changes require review by the other vendor when its CLI or plugin is available. High-risk areas are data loss, destructive SQL, credentials, auth, MCP, AI tool permissions, sync, migrations, plugin ABI, actor isolation, process or C boundaries, release automation, and signing.

## Work sequence

1. Inspect `git status --short` and the current branch. Identify user-owned changes before touching files.
2. Restate the observable behavior and acceptance criteria. Ask only when materially different outcomes remain possible and repository evidence cannot resolve them.
3. Search before editing. Trace entry points, state transitions, callers, sibling implementations, tests, docs, and relevant project-guide invariants.
4. For non-trivial tasks, run the independent investigations above and synthesize a concrete plan with risks and verification commands.
5. Implement the smallest complete root-cause change. A small diff is not a goal if the existing shape cannot express the correct behavior.
6. Add or update tests that fail on the old behavior and pass on the new behavior.
7. Regenerate generated projects when required, then run targeted build, tests, lint, and domain checks.
8. Inspect the full diff for unintended changes. Run cross-model review at the required risk level.
9. Report changed files, evidence, test results, remaining risk, and any check that could not run.

## Project map

- `TablePro/`: macOS application, core services, models, view models, AppKit, and SwiftUI.
- `TableProMobile/`: iOS app and widget.
- `Plugins/`: driver, import, and export plugin bundles plus `TableProPluginKit`.
- `Packages/` and `LocalPackages/`: shared and vendored Swift packages.
- `TableProTests/`: unit and integration tests.
- `TableProUITests/`: deterministic macOS UI automation. Suites must subclass `UITestCase`.
- `docs/`: Mintlify product and developer documentation.
- `project.yml`, `TableProMobile/project.yml`, and `Configs/`: source of truth for generated Xcode projects.
- `scripts/`: generation, build, ABI, library, plugin, and release automation.

## Build and verification

Prefer the wrapper. It exports `DEVELOPER_DIR`, resolves the project from its own checkout, waits for a concurrent `xcodebuild`, keeps the full log on disk, and prints a verdict instead of thousands of lines:

```bash
.claude/skills/fix-issue/scripts/verify.sh <generate|build|plugins|test|uitest|abi|lint> [args]
```

The underlying commands, for a case the wrapper does not cover. Read the environment and failure guidance in `.claude/skills/fix-issue/references/verification.md` first:

```bash
scripts/generate-project.sh
xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug build -skipPackagePluginValidation
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProTests/<SuiteName>
xcodebuild -project TablePro.xcodeproj -scheme TablePro test -skipPackagePluginValidation -only-testing:TableProUITests/<SuiteName>
swiftlint lint --strict <changed Swift files>
```

- Run `scripts/generate-project.sh` after adding, moving, or deleting a source file, or changing project YAML or build configuration. Never hand-edit or commit generated `.xcodeproj` files.
- Build `AllPlugins` when a registry-only plugin changes.
- Run `scripts/check-pluginkit-abi.sh <merge-base>` before completing a `TableProPluginKit` change.
- Prefer targeted suites plus affected neighbors. Confirm that filters executed the intended tests.
- Treat SourceKit diagnostics as hints. A real `xcodebuild` result is authoritative.
- Do not claim success from inspection alone. Show command evidence, or state exactly why a command could not run.

## Code rules

- Follow `.swiftformat` and `.swiftlint.yml`. Use 4 spaces, explicit access control, early returns, and focused functions.
- Do not add explanatory, task-reference, or narration comments. Prefer self-explanatory names and extracted functions. Keep required legal, generated, API documentation, and genuinely non-obvious safety comments.
- Do not force unwrap or force cast without a proven invariant and an existing project precedent.
- Use structured `OSLog`, never `print()` in shipping code.
- Keep UI state mutation on the correct actor. Do not use `Task.detached` to escape isolation.
- Preserve cancellation, late-completion, and generation-token checks around connection and query work.
- Add files by domain. When a type or file approaches lint limits, extract `TypeName+Domain.swift` extensions.
- Do not introduce a production dependency or change a public contract without explaining the need and blast radius.

## User-facing change contract

- Update `CHANGELOG.md` under `[Unreleased]` for user-visible behavior. Documentation and agent-configuration-only changes do not need a changelog entry. Fold fixes to unreleased features into their existing entry.
- Update the relevant page in `docs/` for features, shortcuts, settings, external APIs, or driver behavior.
- Localize user-facing AppKit and computed strings with `String(localized:)`. SwiftUI string literals localize automatically. Never interpolate inside a localization key; use a localized format string.
- Add unit tests for testable behavior. Add UI automation for deterministic user flows, or record why automation cannot be deterministic.
- Keep commits atomic if the user asks for commits. Use a one-line Conventional Commit with a canonical scope.
- Do not commit, push, open a pull request, publish artifacts, tag, or release unless the user explicitly requests that external action.
- One standing exception: a `$fix-issue` run that passes its shipping gates branches, commits, pushes, and opens its pull request without being asked, then works its confirmed follow-up findings into their own pull requests. That authorization covers those actions only, only inside that skill, and never merging, tagging, publishing, releasing, force pushing, or rewriting history. `.claude/skills/fix-issue/references/shipping.md` holds the gates. Every other task still asks.

## Writing style

Use short, specific, human sentences in UI text, docs, changelogs, commit subjects, PR text, and agent-authored guidance. Do not use em dashes or promotional filler.

Before a requested commit, inspect added lines for:

```bash
git diff --cached -U0 | grep -nE '—|seamless|robust|comprehensive|intuitive|effortless|streamlined|leverage|elevate|delve|utilize|facilitate'
```

## Completion standard

A task is complete only when the behavior is implemented at the correct ownership boundary, relevant tests exist, required docs and changelog are updated, targeted checks pass, the diff is reviewed, and the final handoff reports evidence and limitations. Do not stop at a plausible patch or an unverified code change.
