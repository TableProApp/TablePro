export const meta = {
    name: 'fix-issue-critique',
    description: 'Attack a written TablePro fix blueprint from independent lenses and return only objections that survive their own evidence bar',
    whenToUse: 'Phase 2 of the fix-issue skill, after the blueprint file is written and before any product file is edited',
    phases: [{ title: 'Critique', detail: 'one independent lens per critic' }],
}

// args: { blueprint: "<path to blueprint.md>", brief?: "<path to brief.md>",
//         root?: "<path to the run's worktree>",
//         track?: "defect" | "change", lenses?: [...], extra?: [...] }
//
// The safety lens is the same either way. The first two change with the track: a defect plan is
// most often wrong about ownership, a change plan is most often wrong about size.

const OBJECTIONS = {
    type: 'object',
    additionalProperties: false,
    required: ['lens', 'objections'],
    properties: {
        lens: { type: 'string', maxLength: 60 },
        verdict: {
            type: 'string',
            enum: ['sound', 'needs-change', 'wrong-shape'],
            description: 'wrong-shape means the blueprint solves the wrong problem or sits at the wrong ownership boundary.',
        },
        objections: {
            type: 'array',
            maxItems: 6,
            items: {
                type: 'object',
                additionalProperties: false,
                required: ['severity', 'claim', 'evidence'],
                properties: {
                    severity: {
                        type: 'string',
                        enum: ['blocking', 'material', 'minor'],
                        description: 'blocking: shipping this blueprint is incorrect or unsafe. material: it leaves a real gap. minor: preference.',
                    },
                    claim: { type: 'string', maxLength: 240 },
                    evidence: {
                        type: 'string',
                        maxLength: 240,
                        description: 'file:line, SDK symbol, invariant name, or measured output. Reasoning alone is not evidence.',
                    },
                    correction: { type: 'string', maxLength: 240, description: 'The smallest change to the blueprint that answers this.' },
                    check: { type: 'string', maxLength: 160, description: 'What would prove this objection right or wrong.' },
                },
            },
        },
    },
}

const CHANGE_LENSES = [
    {
        key: 'fit',
        agentType: 'codebase-investigator',
        prompt: 'Attack the design as product and architectural fit. Is there a smaller design that satisfies the acceptance criteria in the brief? Does this invent a pattern, a control, or a settings surface the app does not already use, where an existing one would do? Does it follow the precedent the blueprint claims to follow, or only resemble it? Name the existing feature it should have copied, with file evidence, and say plainly if the feature is larger than the problem.',
    },
    {
        key: 'scope',
        agentType: 'codebase-investigator',
        prompt: 'Attack the completeness of a user-visible feature. What does this plan omit that every comparable feature in the repository has: an empty state, an error and offline state, cancellation, undo, keyboard and menu access, a settings default, a migration for existing stored data, localization, the documentation page, the changelog entry, the iOS target, an unknown plugin type falling through a switch? Verify each gap against a shipping example before claiming it.',
    },
    {
        key: 'risk',
        agentType: 'adversarial-reviewer',
        prompt: 'Attack correctness and safety. You are reviewing a written blueprint, not a diff. Look for data loss, destructive SQL, credential or scope leakage, actor isolation and cancellation errors, late completion, ABI breakage, and native UX or responder-chain regressions. New surfaces bring new trust boundaries: check what this feature lets a user or a plugin do that they could not do before. Assume the blueprint will be implemented literally.',
    },
]

const DEFECT_LENSES = [
    {
        key: 'architecture',
        agentType: 'codebase-investigator',
        prompt: 'Attack the ownership boundary. Does this blueprint put the behavior where the repository already puts that kind of decision, or does it bolt a special case onto a shape that cannot express the correct behavior? Name the existing pattern it should have followed, with file evidence. Challenge the targeted-fix versus refactor call in both directions.',
    },
    {
        key: 'scope',
        agentType: 'codebase-investigator',
        prompt: 'Attack the scope. What caller, state transition, persisted value, plugin, migration, localization, document, or edge case does this blueprint miss? What breaks for existing users, existing data, or an unknown plugin type? Verify each gap against the code before claiming it.',
    },
    {
        key: 'risk',
        agentType: 'adversarial-reviewer',
        prompt: 'Attack correctness and safety. You are reviewing a written blueprint, not a diff. Look for data loss, destructive SQL, credential or scope leakage, actor isolation and cancellation errors, late completion, ABI breakage, and native UX or responder-chain regressions. Assume the blueprint will be implemented literally.',
    },
]

const blueprint = args?.blueprint
if (!blueprint) throw new Error('args.blueprint is required: the path to the blueprint')

const track = args?.track ?? 'defect'
if (track !== 'defect' && track !== 'change') throw new Error(`args.track must be "defect" or "change", got "${track}"`)

const lenses = [...(args?.lenses ?? (track === 'change' ? CHANGE_LENSES : DEFECT_LENSES)), ...(args?.extra ?? [])]
const briefLine = args?.brief
    ? `The accepted problem statement is ${args.brief}. Do not relitigate the problem, and treat its non-goals as decided: a plan that respects a non-goal is not incomplete.`
    : ''

const root = args?.root
const rootLine = root ? `Verify against the tree at ${root}, this run's pinned worktree, not the directory you started in.` : ''

const CONTRACT = `
Read ${blueprint}. ${briefLine} ${rootLine}

Attack the blueprint, not the problem statement, and not the other critics. The writer already believes this plan is right, so agreeing costs nothing and finding the flaw is the whole job.

Verify before you object. An objection with no file:line, SDK symbol, named invariant, or measured output is noise that will cost the writer a verification cycle to disprove. Drop taste, formatting, and product decisions that are the user's to make.

Return the schema and nothing else. If the blueprint survives your lens, say so with verdict "sound" and an empty objections list. That is a useful answer, not a failure.
`

phase('Critique')

const reports = (
    await parallel(
        lenses.map((lens) => () =>
            agent(`${lens.prompt}\n${CONTRACT}`, {
                label: `critic:${lens.key}`,
                phase: 'Critique',
                agentType: lens.agentType,
                schema: OBJECTIONS,
            }),
        ),
    )
).filter(Boolean)

const all = reports.flatMap((r) => (r.objections ?? []).map((o) => ({ lens: r.lens, ...o })))
const kept = all.filter((o) => o.severity !== 'minor')
const dropped = all.length - kept.length
if (dropped) log(`dropped ${dropped} minor objection(s); they are in the lane transcripts`)

return {
    blueprint,
    root: root ?? null,
    track,
    verdicts: reports.map((r) => ({ lens: r.lens, verdict: r.verdict ?? 'needs-change' })),
    objections: kept.sort((a, b) => (a.severity === 'blocking' ? -1 : 1)),
    droppedMinor: dropped,
}
