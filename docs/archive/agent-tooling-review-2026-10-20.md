# Agent tooling review: TablePro and dbx, October 20

Dated review of how TablePro and dbx set up coding agents, and what BookiE adopts. Pins: TablePro `main` `3222542a4`, dbx `main` `d1e88ab4b`, BookiE `linux` after the [TablePro and dbx deep review](tablepro-dbx-review-2026-10-20/README.md). Files were read, not run.

BookiE keeps its lanes as defined in [AGENTS.md](../../AGENTS.md#lanes-and-ownership). Nothing here changes lane ownership.

## What each project has

### TablePro

| Path | What it is |
|---|---|
| `AGENTS.md`, `apple/AGENTS.md`, `linux/AGENTS.md`, each with a one-line `CLAUDE.md` (`@AGENTS.md`) | One rulebook per app, loaded by folder. Same idea as BookiE's single `AGENTS.md` |
| `.claude/settings.json` | Disables co-author attribution; enables the `feature-dev` and `codex` plugins |
| `.claude/rules/*.md` (18 files) | Area rules with a `paths:` glob header. Claude Code loads a rule only when a matching file is read, for example `mysql-driver.md`, `data-grid.md`, `ci.md`, `tests.md`, `ai-mcp-security.md` |
| `.claude/skills/fix-issue/` | The main workflow skill: intake, investigate, plan, implement, verify, review, ship, land, report. References per platform, a role brief file, `worktree.sh` and `verify.sh` |
| `.claude/skills/release/` | Order of release decisions; every command stays in `RELEASING.md` |
| `.agents/skills/*` | Symlinks to `.claude/skills/*` so Codex loads the same skills |
| `.codex/config.toml`, `.codex/agents/*.toml` | Codex settings and four read-only agents: `adversarial_reviewer`, `codebase_investigator`, `platform_researcher`, `plugin_abi_reviewer` |
| `scripts/banned-words.txt`, `scripts/check-banned-words.sh` | Writing-style check (em dash, sales words) over staged files and PR bodies |

### dbx

| Path | What it is |
|---|---|
| `skills/dbx/SKILL.md` and `references/` | A skill for end users' agents, not contributors: how to drive the `dbx` CLI safely (bounded read-only queries by default, explicit approval for writes, never bypass a refusal with another client, never expose secrets, a failure table) |
| `crates/dbx-core/src/skills` | Built-in assistant skills inside the product; out of scope for BookiE (no in-app AI) |

dbx has no `.claude`, `.codex` or `.agents` directory and no contributor agent rules.

## Best ideas

1. **A workflow skill that holds the order, not the rules.** TablePro's `fix-issue` names each phase and points to the rulebook for every rule. It keeps the run consistent without a second copy of the rules.
2. **Investigation roles with evidence rules.** `trace`, `research`, `hunt`, `verify` and `critic`, each read-only, each writing a full report to disk and returning a short digest. "Evidence or silence" and "confirmed or inferred" labels stop confident wrong claims. A `verify` role tries to refute each hunted defect before it enters scope.
3. **Run state on disk.** `problem.md` and `plan.md` under `.analysis/<slug>/` survive a compaction or usage limit. BookiE already ignores `.analysis/`. The October 20 research run lost six agents to a usage limit; on-disk reports were what let it resume.
4. **A verdict wrapper.** `verify.sh` prints `PASS`, `FAIL` or `INCONCLUSIVE`, sums Cargo's per-binary counts, and treats a filter that matched zero tests as inconclusive. BookiE's `run-test-layer.py` and `ci-report.py` cover part of this; a zero-test filter is not yet called out.
5. **Read-only reviewer agents for a second model.** Codex agent definitions with `sandbox_mode = "read-only"` give an independent reviewer that cannot edit the tree.
6. **Path-scoped rules.** Rules load only when the matching files are touched, which keeps context small.
7. **A banned-words check.** Turns the writing-style rule into a script.
8. **An end-user agent skill (dbx).** A skill shipped with the CLI that tells any agent how to use the product inside its safety boundary.

## Decisions for BookiE

| Idea | Decision | Why |
|---|---|---|
| Workflow skill | **Adopted** as [`.claude/skills/fix-issue`](../../.claude/skills/fix-issue/SKILL.md) with [roles](../../.claude/skills/fix-issue/references/roles.md) | Encodes `AGENTS.md` Workflow, the Forgejo gate and lane checks in order. It points to `AGENTS.md` for every rule, so `CLAUDE.md`'s "one copy of the rules" holds |
| Investigation roles and run state | **Adopted** inside the skill | Renamed from TablePro's "lanes" to "roles" so they are not confused with BookiE's ownership lanes |
| Path-scoped `.claude/rules` | **Not adopted** | `AGENTS.md` requires one rule text for every agent; Claude-only rules would split it. Revisit only as pointer files that link to existing docs and add no rule |
| `.agents/skills` symlink for Codex | **Follow-up, gated** | A symlink is not a documentation change; it needs a pull request through the Forgejo gate |
| `.codex/agents` read-only reviewers | **Follow-up, gated** | Same reason. Start with `adversarial_reviewer` and `codebase_investigator`, pointed at `AGENTS.md` and the skill's roles file |
| `.gitignore` for committed skills | **Follow-up, gated** | `.claude/` is ignored for session state. The skill files are tracked by explicit add; narrowing the ignore to `.claude/*` with `!.claude/skills/` makes new skill files visible to `git status` |
| Verdict wrapper | **Candidate** | Extend `run-test-layer.py` to report a zero-test filter as inconclusive before writing a new wrapper |
| Banned-words check | **Candidate** | Small script for the writing-style rule in `AGENTS.md`; needs a gated pull request and a word list the maintainer accepts |
| Release skill | **Later** | Publication is pending and owned by the maintainer. Write it after the first 0.2.0 publication, from the steps actually used |
| dbx-style user skill for `bookie-agentd` | **Candidate** | Tells a consumer agent to use scoped tokens, expect PolicyGuard refusals, never retry a refusal through another client, and never ask for secrets. Fits the governed-MCP product choice |
| Disabling co-author attribution | **Not adopted** | Attribution follows the session's own rules, not repository settings |

## Follow-up order

1. One gated pull request: `.gitignore` narrowing, `.agents/skills/fix-issue` symlink, and two `.codex/agents` files.
2. Zero-test filter verdict in `run-test-layer.py`.
3. `bookie-agentd` consumer skill under `docs/` or the package data, reviewed by B4.
4. Banned-words check, if the maintainer wants it enforced.
