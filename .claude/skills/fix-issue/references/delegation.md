# Delegation and the Context Budget

How work is split so the main thread stays small enough to finish the job, and how to get detail
back when a digest is not enough. The mechanics are the same on both tracks; only the lane
questions change.

## What the mechanisms actually cost

Measured against the Claude Code contract, not guessed:

- A subagent returns **only its final message** to the parent. Its tool calls, file reads, and
  reasoning never enter the parent thread.
- A workflow returns **only the script's return value**. Lane transcripts stay in the run's
  transcript directory, and every lane's return value is one line in its `journal.jsonl`.
- Nothing caps a subagent's final message. Prompt instructions are the only lever, and a lane
  that is enjoying itself will write two thousand words. A workflow `schema` is the only
  enforceable cap, which is why the fan-out phases are workflows.
- A subagent declared `permissionMode: plan` cannot write files, so read-only lanes hand back
  digests rather than writing evidence to disk. A subagent declared `background: true` keeps
  `Write` and `Edit` but loses the `Workflow` tool, so the implementer can edit and cannot fan
  out again.
- `Bash` returns about 30,000 characters inline on success and then saves the rest to a file you
  can read. On failure it returns about 10,000 characters as a head-and-tail excerpt **with no
  file path**. Build and test failures are therefore the one case where the output is both
  largest and least recoverable. That is what this skill's `scripts/verify.sh` exists to fix.

Sources: `code.claude.com/docs/en/sub-agents`, `/workflows`, `/tools-reference`.

## Choosing the mechanism

| Situation | Use | Why |
| --- | --- | --- |
| Several independent questions at once | `Workflow` with a schema | Deterministic fan-out, enforceable digest size, transcripts stay out |
| One narrow follow-up to a finished lane | `SendMessage` to that agent | It still holds everything it read, so the answer costs nothing to re-derive |
| One focused question, no fan-out | `Agent` with a project agent type | Simpler than a workflow, and the agent stays resumable |
| Editing files under a written plan | `implementer` agent, or the main thread | One writer per checkout, always |
| Anything with build or test output | this skill's `scripts/verify.sh` | The log belongs on disk |

Do not run a workflow inside a lane. Lanes are leaves.

## The lane digest contract

`workflows/investigate.mjs` and `workflows/critique.mjs` hold the schemas. The rules the prompts
enforce, and that any hand-written lane prompt should repeat:

- Every lane reads the same `brief.md`. Never restate the problem in a prompt, and never give a
  lane the writer's preferred solution.
- One narrow question per lane. A lane that answers two questions is two lanes.
- An anchor is `Path/To/File.swift:123` plus what is there, and it is only valid for a file the
  lane actually opened. Inferred paths are not anchors.
- Confidence is `confirmed` only when a file, an SDK interface, or a measured probe backs it.
  Otherwise `inferred`, or `blocked` with what would settle it.
- The digest is a budget, not a summary style. Detail that does not fit stays in the transcript
  on purpose.

## Getting detail back

In order of cost:

1. **Open the anchor.** `Read` with `offset` and `limit`, or `grep -n`. Almost always enough.
2. **Ask the lane again.** For an `Agent` lane, `SendMessage` with the one question. The agent
   still has its full context.
3. **Read the journal.** A workflow's completion notice names its transcript directory. Each
   completed lane is one `{"type":"result"}` line in `journal.jsonl` holding its full return
   value. Grep it for a key rather than reading it whole.
4. **Re-run one lane.** Cheapest correct answer when the question changed. Re-running the whole
   phase to recover one fact is not.

Never read `agent-*.jsonl` transcripts directly. They are full conversation logs and reading one
undoes the saving that produced it.

## Implementer handoff

Delegate the edit when the blueprint touches more than about three files, when it restructures a
type, or when this run has already been compacted.

The handoff is the blueprint path and the worktree, nothing else. If the blueprint is not complete
enough to implement from, it is not finished, and fixing that here is cheaper than discovering it
in a diff. Give the implementer:

- The blueprint path and the run directory, both in the main checkout.
- The worktree path and its branch, with the instruction to write only there.
- The verification steps it must run through `verify.sh --root <worktree>` before returning.
- The requirement to return a summary of files changed and verdicts, not a narration of the
  edits. You will read the diff.

Review the returned diff with `git -C <worktree> diff` in the main thread. That is the writer's
real output, and it is the cheapest complete record of what happened.

## Parallelism and safety

- One writer per worktree, and this skill's writer is always in a worktree, never in the main
  checkout. Additional writers need their own worktree with disjoint files.
- Reads and analysis run in parallel. Generation, `xcodebuild`, tests, and ABI checks run
  serially, one process at a time, for the whole machine and not just this session.
- Reviewers are read-only. A review leader may run read-only evidence lanes and never fixes,
  commits, or starts another cross-vendor review.
- One primary external review per change, plus one adversarial pass for high-risk work. The
  writer validates and resolves every finding.

## Cross-vendor review packet

Give the reviewer observable behavior, acceptance criteria, base reference, diff scope, the
invariants that apply, the verification verdicts already collected, and one focused threat
statement. Leave out your own conclusions about whether the change is correct. Findings come back
ranked P0 to P3 against `.agents/skills/cross-model-review/references/review-rubric.md`.
