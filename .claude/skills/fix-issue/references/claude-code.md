# Running under Claude Code

How `SKILL.md` maps onto Claude Code.

## Tracking and asking

- Keep a task list with the phases this run uses (`TodoWrite` or the task tools, when present), and progress in `plan.md` either way.
- Ask with `AskUserQuestion`, recommendation first, only for the cases in "Autonomy".
- The Bash tool's working directory resets to the main checkout between calls: start every command for the tree with `cd <tree> &&` or pass `-C <tree>`.

## Lanes

Run the Full-mode lanes as one `Workflow` (the skill is the opt-in it requires), or as background `Agent`s in one message when `Workflow` is not available. Each lane gets its brief from `references/lanes.md`, writes its full report to a file and returns a short digest, so a failed schema never loses the work.

```js
export const meta = {
  name: 'fix-issue-investigation',
  description: 'Trace a TablePro defect, establish the correct behavior, hunt and verify related defects',
  phases: [{ title: 'Investigate' }, { title: 'Verify' }],
}

const SKILL = '<tree>/.claude/skills/fix-issue'
const TREE = '<tree>'
const RUN = `${TREE}/.analysis/<slug>`
const SUBSYSTEM = '<the folders the fix lands in>'
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
        },
      },
    },
  },
}

const brief = lane => `
You are the ${lane} lane of a TablePro fix investigation. The code is in ${TREE}: read it there.
Read ${SKILL}/references/lanes.md: "Rules for every lane" and "${lane}".
The problem statement is ${RUN}/problem.md. The subsystem in play: ${SUBSYSTEM}.
Write your full report to ${RUN}/lanes/${lane}.md, then return the digest schema.
${lane === 'hunt' ? 'Put every finding in the findings array too.' : 'Leave findings empty.'}
`

phase('Investigate')
const results = await parallel(LANES.map(lane => () =>
  agent(brief(lane), { label: lane, phase: 'Investigate', schema: DIGEST })))

const hunt = results[LANES.indexOf('hunt')]
const candidates = (hunt && hunt.findings) || []

phase('Verify')
const verdict = candidates.length === 0 ? null : await agent(`
You are the verify lane of a TablePro fix investigation. The code is in ${TREE}.
Read ${SKILL}/references/lanes.md: "Rules for every lane" and "verify".
Findings to refute, as JSON:
${JSON.stringify(candidates, null, 2)}
Write one row per finding to ${RUN}/lanes/verify.md, then return the digest schema
with a findings array holding only the real ones.
`, { label: 'verify', phase: 'Verify', schema: DIGEST })

return { results, verdict }
```

- Fill in every `<...>` and hardcode it: the tool's `args` can arrive empty. `meta` is a pure literal; `Date.now()`, `Math.random()` and an argless `new Date()` throw.
- Return raw results; an `agent(...).then(...)` chain inside `parallel()` has come back empty.
- When a digest is missing or the return looks empty, read the lane's report file, or `journal.jsonl` for the run.
- A lane that stalls is re-run as one background `Agent` with the same brief. Never `SendMessage` a lane that is still running: that starts a second copy.
- Run the `critic` lane as one background `Agent`; long critic turns trip the workflow's stall watchdog.
- Afterwards, `git -C <tree> status --short` confirms no lane edited the tree.

Parallel implementers (`SKILL.md` Phase 3) are background `Agent`s in one message, each prompt naming the tree, `plan.md` and the exact files it owns, and saying to edit nothing else, build nothing, and finish with the files it changed.

## Long commands

Run `build`, `plugins`, `test`, `uitest`, the Codex review and the CI watch with `run_in_background: true`. You are re-invoked when each exits, so never poll in between. Keep `generate` and `lint` in the foreground, and never run two `xcodebuild` in one tree.

CI watch: `gh pr checks <n> --repo TableProApp/TablePro --watch --interval 60` exits when every check finishes, non-zero on a failure; `gh run view <run-id> --log-failed` gives the log. A background command stops after two hours; if checks are still queued then, Phase 7's backlog rule applies.

## Review: Codex

Run the Codex plugin's companion from inside the tree (`cd <tree> &&` on every call; its job state is keyed by the checkout):

```bash
CODEX="$(ls -1d "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | sort -V | tail -1)"
node "$CODEX" review --wait --scope working-tree        # --base main once the work is committed
node "$CODEX" adversarial-review --wait --scope working-tree "<the mechanism the fix rests on>"
node "$CODEX" status
node "$CODEX" result <job-id>
```

- `review` every round; `adversarial-review` in Full mode on the first round. One at a time, each in the background with `--wait`.
- Read the findings with `result`, never from stdout, which shows only progress whether the job succeeded or died. `status` says whether it finished.
- When `status` shows Codex cannot review (not installed, out of credits, usage limit), use `Skill(code-review)` and say so in the report. A setup or login error goes back to the user with `/codex:setup`.
- The security pass is a background `Agent` told to review `git -C <tree> diff origin/main...HEAD` for injection, credential exposure, authorization and unsafe execution, reporting only high and medium findings with an exploit scenario. `Skill(security-review)` reads the main checkout, not the tree.

## Screenshots

Drive a Debug build with `osascript` and capture with `screencapture`; Screen Recording must be granted to whatever runs them.
