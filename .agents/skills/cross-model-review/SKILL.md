---
name: cross-model-review
description: Independent cross-vendor code review protocol for TablePro changes. Use after Claude Code or Codex implements a medium-risk change, and always for data loss, destructive SQL, credentials, auth, MCP, AI permissions, sync, migrations, plugin ABI, concurrency, C boundaries, signing, or release automation. It invokes the other vendor read-only, prevents review recursion, validates findings, and produces evidence-ranked results.
---

# Cross-model Review

Read `references/review-rubric.md` for the P0 to P3 scale and the evidence contract every finding
must satisfy. Do not start a cross-model review from inside a review session.

## The packet

Give the reviewer:

- Observable behavior and acceptance criteria.
- The base reference and the exact diff scope, including **which tree** the diff is in.
- The invariants that apply.
- The verification steps already run and their verdicts.
- One focused threat statement for high-risk work.

Do not prime the reviewer with your preferred conclusion, and do not include your own self-review.

## When Claude Code is the writer

Only one Codex entry point can be invoked by an agent. `/codex:review`,
`/codex:adversarial-review`, `/codex:status`, and `/codex:result` are all declared
`disable-model-invocation: true`, so they work when the user types them and not otherwise. A run
that "starts a Codex review" with those and then waits for a result waits forever.

Use `/codex:rescue`, which is model-invocable, with `--wait` so the result returns in this turn
rather than into a status command you cannot call:

```text
/codex:rescue --wait --fresh Read-only review of <tree path>. Do not edit files, do not commit,
do not run builds. Review <diff scope> against <acceptance criteria>. Read AGENTS.md and the
invariant files under .agents/skills/tablepro-engineering/references/. Report only P0 to P3
findings with file:line, evidence, a failure scenario, and the smallest valid fix.
Threat to focus on: <one threat>.
```

Three things about that command are load-bearing:

- **The read-only wording is the guard, not decoration.** The rescue forwarder defaults to a
  write-capable run and only stays read-only when the request says so. Keep "Read-only" and "Do not
  edit files" literally, and check the returned job did not write.
- **Name the tree explicitly.** `rescue` has no `--cwd`, and the companion falls back to the session
  working directory, which is the main checkout. A `$fix-issue` run's diff lives in its worktree, so
  give the absolute worktree path in the prompt and tell the reviewer to read it with
  `git -C <path> diff`. Without that the review reads a different tree and its findings are noise.
- **Omit `--effort`.** The run inherits the repository's Codex profile. Do not lower it.

Run one review for a medium-risk change, plus one focused adversarial pass for high-risk work. If
the review cannot be started, say so in the handoff and do not describe the change as reviewed.

## When Codex is the writer

Invoke Claude Code non-interactively and read-only from the repository root:

```bash
claude -p --model opus --effort ultracode --permission-mode plan --no-session-persistence \
  --tools "Read,Grep,Glob,Bash" \
  --disallowedTools "Write,Edit,NotebookEdit,Agent" \
  "Review the working tree at <path> against its merge base. Do not edit files, commit, push,
   stash, reset, build, invoke Codex, or start another cross-vendor review. Read AGENTS.md, the
   relevant invariant files, the diff, callers, and tests. Report only actionable correctness,
   security, data-loss, concurrency, ABI, behavior, and missing-test findings, each ranked P0 to
   P3 with file:line, evidence, a failure scenario, and the smallest valid fix. State explicitly
   when no findings survive verification."
```

Details that matter:

- `-p` is required. `--no-session-persistence` only applies with print mode, and without it the
  call opens an interactive session that never returns a review.
- `--tools` caps which tools exist. `--allowedTools` is a permission allow-rule, not a restriction:
  listing `Bash` there pre-approves every command in a session that cannot prompt. Cap availability
  with `--tools`, and rely on `--permission-mode plan` plus the written prohibitions above.
- `--effort ultracode` is real and maps to the ultracode profile. Do not downgrade it.

For high-risk work, make one second call with a narrow threat statement. Do not reuse or continue
the first review session.

If the Claude CLI is unavailable, use Codex's project `adversarial_reviewer` agent, which runs
`sandbox_mode = read-only`, and disclose that the review was not cross-vendor. If Codex's sandbox
blocks Claude authentication or Keychain access, request approval to run the same read-only command
in the host environment. Never modify credentials or Keychain state; if approval is unavailable, use
the local fallback and report the limitation.

## Resolve findings

1. Verify each finding in source, tests, SDK documentation, headers, or a probe.
2. Reject speculation and style-only preferences.
3. Fix confirmed P0 to P2 findings in the writer session.
4. Re-run the affected verification step.
5. Re-review only when a fix materially changes the design or a high-risk boundary.

## Recursion caps

- One primary external review per change, plus one adversarial pass for high-risk work.
- A reviewer never invokes the other vendor, never invokes another reviewer, and never reviews its
  own output.
- Reviewers are read-only. A review leader may run read-only evidence lanes; it does not fix, commit,
  push, or open pull requests.
- Never enable an automatic review gate that can fire on every stop. That is the one configuration
  that can loop two agents against each other.
- Never let both vendors write in the same checkout.

The writer validates every finding and owns the final decision.
