# Running under Codex

How `SKILL.md` maps onto Codex. Codex loads the skill through `.agents/skills/fix-issue` and the project guide from `AGENTS.md`.

## Rules and tracking

- Codex loads the root `AGENTS.md` and nothing else by itself. When the profile's "Done" section names another guide, read it. Before editing, read every rule under `.claude/rules/` whose `paths:` frontmatter matches a file you will touch (the guide lists them).
- Keep progress in `plan.md`, and in the plan or goal tool your session offers, if any.
- Ask with `request_user_input`, recommendation first, only for the cases in "Autonomy".

## Lanes

Spawn the lanes in parallel with `spawn_agent`, collect them with `wait_agent`, and end the ones you no longer need with `close_agent` or `interrupt_agent`, whichever the session exposes.

| Lane | `agent_type` |
| --- | --- |
| trace, hunt | `codebase_investigator` |
| research | `platform_researcher` |
| verify, critic, review | `adversarial_reviewer` |
| ABI review | `plugin_abi_reviewer` |

Each message names the brief (`.claude/skills/fix-issue/references/lanes.md`: the shared rules and the lane's section), the platform profile, the tree, `problem.md` or `plan.md`, and the subsystem. These agents are read-only: a lane returns its report as its final message and you save it to `<tree>/.analysis/<slug>/lanes/<lane>.md`, and a probe that needs compiling is yours to run.

Parallel implementers (`SKILL.md` Phase 3) use the default agent type, since the project agents cannot write. Each message names the tree, `plan.md` and the exact files it owns, and says to edit nothing else, build nothing, and finish with the files it changed.

## Commands

- A build can write outside the tree (the profile's verification file says where), `gh` and `git push` need the network, and `verify.sh` logs under `.analysis/`. When the sandbox refuses one, request escalation for that command; never skip the step.
- Give the profile's build and test steps a timeout of at least 30 minutes, and never run two builds in one tree.
- CI: `gh pr checks <n> --repo TableProApp/TablePro --watch --interval 60` blocks until the checks finish, or re-run `gh pr checks <n>` every few minutes; `gh run view <run-id> --log-failed` gives a failed job's log.

## Review

Spawn `adversarial_reviewer` over the diff pinned to commit SHAs captured before spawning (`git diff <base-sha> <head-sha>`), since a symbolic range can resolve to nothing once the branch merges. Give it the mechanism the fix rests on in one sentence, and ask for security coverage when Phase 5 calls for it. Add `plugin_abi_reviewer` when the profile calls for the ABI pass. The report says the reviewer was a Codex agent.

## Images

Look at screenshots and video frames with `view_image`. The profile's "Screen" section names the tools that launch, drive and capture the app.
