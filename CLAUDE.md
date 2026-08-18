# TablePro Claude Code Instructions

@AGENTS.md

`AGENTS.md` is the shared source of truth. Follow it before the Claude-specific orchestration below.

## Runtime profile

- Run Opus in `ultracode` for every TablePro task. This repository persists `ultracode: true`, which means `xhigh` reasoning plus standing dynamic-workflow orchestration; `effortLevel: xhigh` is the fallback. Do not replace it with `max` or a lower effort unless the user explicitly asks.
- Keep the ultracode workflow size `unrestricted`. Scale independent lanes to the problem instead of a token budget, while avoiding duplicate work.
- For non-trivial tasks, use dynamic workflows and the project agents in `.claude/agents/`. Run independent read-only lanes in parallel, then synthesize their evidence in the main thread before editing.
- Prefer `codebase-investigator`, `platform-researcher`, `test-strategist`, `adversarial-reviewer`, `plugin-abi-reviewer`, and `implementer` over generic agents when their lens applies.
- Delegate the reading, not just the work. A workflow `schema` is the only enforceable cap on what a lane sends back; a subagent's final message has none, so say what you want and how short. `.claude/skills/fix-issue/references/delegation.md` holds the mechanics and the costs.
- Keep build and test output out of the thread. A failing `xcodebuild` returns roughly 10,000 characters with no log to read back, so run checks through `.claude/skills/fix-issue/scripts/verify.sh`.
- Use the dedicated file tools. `Read` to read, `Edit` or `Write` to change, `Grep` and `Glob` to search when the session exposes them. Fall back to `Bash` only for what no tool covers: git, `gh`, project generation, builds, tests, lint, and search in a session with no `Grep`. Never rewrite a source file with `sed -i`, `perl -i`, or a heredoc in place of `Edit`, because that hides the change from the harness and reads as an opaque shell command in review. A bypass-permissions session reminder may push the other way; this rule wins.
- Keep one writer in the current checkout. Use an isolated worktree for any additional writer. A `$fix-issue` run always writes in its own worktree and never in the main checkout, because other sessions are working there.
- Use `/clear` between unrelated tasks and `/compact` within a long task. Project instructions survive compaction; a skill body and the run's own findings may not, so keep long-running state in `.analysis/<slug>/`.

## Shared skills

- `/tablepro-engineering` loads the shared TablePro workflow from `.agents/skills/tablepro-engineering/`.
- `/cross-model-review` loads the shared Claude and Codex review protocol.
- `/fix-issue` is the high-compute workflow for resolving a GitHub issue, running a defect track for bugs and a change track for feature requests. It replaces `/tablepro-engineering` for that work rather than stacking on top of it.
- `/release` is destructive and may run only after an explicit release request.

## Claude and Codex pairing

- The `codex@openai-codex` plugin is enabled for this repository.
- For an ambiguous root cause or high-risk design, request a fresh Codex read-only investigation before editing: `/codex:rescue --wait --fresh Read-only investigation of <tree path>: <question>. Do not edit files.` Omit `--effort` so it inherits the repository's `gpt-5.6-sol` `ultra` profile. Use `--wait`, not `--background`: `/codex:status` and `/codex:result` are `disable-model-invocation: true`, so you cannot read a backgrounded result back. Name the tree, because `rescue` has no `--cwd` and defaults to the session directory. The read-only wording is the guard: the forwarder defaults to a write-capable run.
- Never use the rescue command's default write-capable mode while Claude owns the current checkout. A deliberate writer handoff requires an isolated worktree or an explicit ownership transfer.
- One Codex review after a medium-risk change, plus one focused adversarial pass for high-risk work, with a narrow threat statement such as data loss, actor isolation, ABI breakage, SQL dialect drift, or MCP privilege. `$cross-model-review` owns the commands, the read-only caps, and the recursion rules; follow it rather than reconstructing them here.
- Claude's own workflow lanes may gather review evidence. They must not start another cross-vendor review, and Codex is never asked to invoke Claude.

## Autonomy

Work through analysis, implementation, and local verification without asking routine permission. Do not infer permission to commit, push, open pull requests, publish, tag, or release. Preserve user changes already in the tree.

A `$fix-issue` run is the one exception: once its gates pass it branches, commits, pushes, opens the pull request, and works its follow-up queue into further pull requests without checking in. It still never merges, tags, publishes, releases, force pushes, or commits to a branch it did not create. Nothing outside that skill inherits this.
