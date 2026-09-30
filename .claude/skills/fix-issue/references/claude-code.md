# Running under Claude Code

How each step of `SKILL.md` maps onto Claude Code's tools.

## Tracking

When `TodoWrite` or the task tools are present, open a list with the phases this run uses and keep it current. It is how the user follows a long run, and how you find your place after a compaction. Otherwise state the phase at each boundary.

## Asking

Use `AskUserQuestion`, with your recommendation as the first option. Ask only for the two cases in "Autonomy".

## Full-mode investigation: the `Workflow` tool

This skill's instructions are the opt-in the tool requires. Every lane gets the whole brief from `references/lanes.md` and writes its full report to a file, so the script stays small and a failed schema never loses the work. Fill in `SKILL`, `TREE`, `RUN` and `SUBSYSTEM` as absolute values, and drop `research` from `LANES` when the fix is purely internal logic.

```js
export const meta = {
  name: 'fix-issue-investigation',
  description: 'Trace a TablePro defect, establish the correct behaviour, hunt and verify related defects',
  phases: [{ title: 'Investigate' }, { title: 'Verify' }],
}

const SKILL = '/Users/ngoquocdat/Workspaces/TablePro/.claude/skills/fix-issue'
const TREE = '/Users/ngoquocdat/Workspaces/TablePro/.claude/worktrees/<slug>'
const RUN = `${TREE}/.analysis/<branch>`
const SUBSYSTEM = 'Plugins/DuckDBDriverPlugin/, TablePro/Core/Database/'
const LANES = ['trace', 'research', 'hunt']

const DIGEST = {
  type: 'object',
  required: ['verdict', 'confidence', 'digest'],
  properties: {
    verdict: { type: 'string', maxLength: 1000 },
    confidence: { type: 'string', enum: ['confirmed', 'inferred', 'blocked'] },
    digest: { type: 'string', maxLength: 6000 },
    findings: {
      type: 'array',
      maxItems: 20,
      items: {
        type: 'object',
        required: ['title', 'location', 'failureScenario'],
        properties: {
          title: { type: 'string', maxLength: 600 },
          location: { type: 'string', maxLength: 600 },
          evidence: { type: 'string', maxLength: 3000 },
          failureScenario: { type: 'string', maxLength: 3000 },
          blocksPrimaryFix: { type: 'boolean' },
        },
      },
    },
  },
}

const brief = lane => `
You are the ${lane} lane of a TablePro fix investigation. The code is in ${TREE}: read it there.
Read ${SKILL}/references/lanes.md: the "Rules for every lane" section and the "${lane}" section.
The problem statement is ${RUN}/problem.md. The subsystem in play: ${SUBSYSTEM}.
Write your full report to ${RUN}/lanes/${lane}.md, then return the digest schema.
${lane === 'hunt' ? 'Put every finding in the findings array too.' : 'Leave findings empty.'}
`

phase('Investigate')
const results = await parallel(LANES.map(lane => () =>
  agent(brief(lane), { label: lane, phase: 'Investigate', schema: DIGEST })))

const hunt = results[LANES.indexOf('hunt')]
const candidates = (hunt && hunt.findings) || []
log(`${candidates.length} related-defect candidates`)

phase('Verify')
const verdict = candidates.length === 0 ? null : await agent(`
You are the verify lane of a TablePro fix investigation.
Read ${SKILL}/references/lanes.md: "Rules for every lane" and "verify".
Findings to refute, as JSON:
${JSON.stringify(candidates, null, 2)}
Write one row per finding to ${RUN}/lanes/verify.md, then return the digest schema,
with a findings array holding only the findings that are real.
`, { label: 'verify', phase: 'Verify', schema: DIGEST })

return { results, verdict }
```

Rules that have cost real runs:

- **Hardcode every input** in the script. The tool's `args` parameter has arrived as an empty global and run a lane on nothing. `meta` must be a pure literal, the script is plain JavaScript, and `Date.now()`, `Math.random()` and an argless `new Date()` throw.
- **No `.then()` inside `parallel()`.** An `agent(...).then(...)` chain there has come back empty while every agent succeeded. Return raw results and pair them yourself.
- **Keep schema caps generous.** A field cap that is exceeded rejects the report after the work is done, and the lane comes back null. The report file survives either way, so read it when a digest is missing.
- **When the aggregated return looks empty**, read `subagents/workflows/<run>/journal.jsonl` before believing it. Each `{"type":"result"}` line holds one agent's full return.
- **A lane that stalls** (killed after 180 seconds without progress) is re-run as one background `Agent` with the same brief, not by re-running the whole workflow.
- **Never `SendMessage` a lane that is still running.** It resumes a second copy that writes the same files. Note the answer and apply it after the workflow returns.
- After it returns, run `git status --short` to confirm no lane touched the checkout.

## Critic

Run the `critic` lane as one background `Agent` (general-purpose), not as a workflow. Critic turns on a large plan have tripped the workflow's stall watchdog on every attempt, and the same brief as an `Agent` finishes. Its prompt names `references/lanes.md`, `plan.md`, and `.analysis/<branch>/lanes/critic.md` as its output file.

## Long commands

Pass `run_in_background: true` for `verify.sh build`, `plugins`, `test` and `uitest`, for the Codex review, and for the CI watch, so a multi-minute step does not block the session. You are re-invoked when it exits, so never poll it in between: past runs spent 1,095 calls polling Codex `status`. Keep `generate` and `lint` in the foreground. Never have two `xcodebuild` runs in flight in the same tree.

The Bash tool's working directory resets to the main checkout between calls, so start every command for the tree with `cd <tree> &&` or pass `-C <tree>`.

## Watching CI

```bash
gh pr checks <number> --repo TableProApp/TablePro --watch --interval 60
```

Run it in the background. It exits when every check has finished, non-zero when one failed. Then `gh pr checks <number>` lists the failures, and `gh run view <run-id> --log-failed` gives the log of each failed job.

## Review: Codex

A different model from a different lab reads the diff cold. Run it through the Codex plugin's companion script from inside the tree, with `cd <tree> &&` on every call: Codex job state is keyed by the checkout, so `status` run from anywhere else reports no jobs.

```bash
CODEX="$(ls -1d "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | sort -V | tail -1)"
node "$CODEX" review --wait --scope working-tree
node "$CODEX" adversarial-review --wait --scope working-tree "<the mechanism the fix rests on, in one sentence>"
node "$CODEX" status
node "$CODEX" result <job-id>
```

- Launch with `--wait` in the background and read `result` once when you are re-invoked.
- Run `review` every round. Add `adversarial-review` in Full mode, on the first round, because it attacks the design rather than the lines. Never run the two at once. Use `--base main` instead of `--scope working-tree` once the work is committed.
- **Read the findings from `result`, never from stdout.** A `--wait` run prints only reasoning headlines whether it succeeded or died, and it exits 0 either way. `status` says whether the job finished and gives its verdict. `result` has the findings, with `file:line`.
- `/codex:review` and `/codex:adversarial-review` only run when the user types them, so call the script.
- **When Codex cannot review** (`status` shows a failure: CLI missing, out of credits, usage limit), fall back to `Skill(code-review)` and say so in the PR and the report. A run that died still leaves its reasoning headlines in the job log that `status` names. Grep them for bug, risk and mismatch, and check each lead against the code. An authentication or setup error goes back to the user with `/codex:setup`.
- Add `Skill(security-review)` when the change touches a security boundary (list in `SKILL.md`, Phase 5). It reads the branch diff from git, so run it once the diff is complete.

## Screenshots

Drive a Debug build with `osascript` and capture with `screencapture`. Screen Recording has to be granted to whatever runs them. Launch the app with `TABLEPRO_UI_TEST_SANDBOX` set to a scratch directory.
