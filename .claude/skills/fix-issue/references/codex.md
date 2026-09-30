# Running under Codex

How each step of `SKILL.md` maps onto Codex. Codex loads this skill through the `.agents/skills/fix-issue` symlink and the project rules through `AGENTS.md`, which sends you to `CLAUDE.md`.

## Project rules

Codex does not load `CLAUDE.md` or `.claude/rules/` by itself. Before editing, read the `CLAUDE.md` sections your change touches, and every `.claude/rules/*.md` file whose `paths:` frontmatter matches a file you will edit. Claude Code applies those rules automatically; here nothing does.

## Tracking and asking

Keep the phases in `update_plan`. Ask with `request_user_input`, recommendation first, and only for the two cases in "Autonomy".

## Full-mode investigation: subagents

Spawn the lanes with `spawn_agent`, using the project agents in `.codex/agents/`. Launch them in parallel, collect them with `wait_agent`, and `close_agent` each one when you are done with it.

| Lane | `agent_type` |
| --- | --- |
| trace | `codebase_investigator` |
| research | `platform_researcher` |
| hunt | `codebase_investigator`, with the hunt brief |
| verify | `adversarial_reviewer`, with the verify brief |
| critic | `adversarial_reviewer`, with the critic brief |

Each message names the brief to follow (`.claude/skills/fix-issue/references/lanes.md`, the rules section plus the lane's own section), the tree to read the code in, the path of `problem.md` or `plan.md`, and the subsystem in play.

These agents run in a read-only sandbox, which changes two things:

- **They cannot write report files.** A lane returns its report as its final message, and you save it to `.analysis/<branch>/lanes/<lane>.md` before reading only what the plan needs.
- **They cannot compile a probe.** When a lane says a question needs measuring, run the probe yourself in the scratchpad.

## Long commands and the sandbox

`xcodebuild` writes to `~/Library/Developer/Xcode/DerivedData`, `gh` and `git push` need the network, and `verify.sh` logs under `.analysis/`. When the sandbox refuses one of them, ask for the escalated permission for that command. Never skip the step. Give `verify.sh build`, `plugins`, `test` and `uitest` a timeout of at least 30 minutes, and never run two `xcodebuild` at once in the same tree. Run every command for the tree with `-C <tree>` or `cd <tree> &&`.

## Watching CI

`gh pr checks <number> --repo TableProApp/TablePro --watch --interval 60` blocks until every check finishes and exits non-zero when one failed. CI takes tens of minutes, so run it with a long timeout, or re-run `gh pr checks <number>` every few minutes instead of holding one call open. `gh run view <run-id> --log-failed` gives a failed job's log.

## Review

Spawn `adversarial_reviewer` over the diff. Pin the range to commit SHAs captured before spawning (`git diff <base-sha> <head-sha>`, or the working tree before the first commit), because a symbolic range such as origin/main...HEAD resolves when the agent runs and can come back empty after a merge. Give it the mechanism the fix rests on in one sentence, and tell it to cover security whenever the change touches a boundary listed in Phase 5. When `Plugins/TableProPluginKit` changed, also spawn `plugin_abi_reviewer`.

Name in the PR and in the report that the review was Codex's own reviewer agent, so nobody assumes a second model read the change.

## Images and recordings

Look at screenshots and extracted video frames with `view_image`. For screenshots of the app, drive a Debug build with `osascript` and capture with `screencapture`, launched with `TABLEPRO_UI_TEST_SANDBOX` set to a scratch directory.
