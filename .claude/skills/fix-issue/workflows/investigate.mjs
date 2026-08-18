export const meta = {
    name: 'fix-issue-investigate',
    description: 'Run independent read-only investigation lanes over one TablePro issue brief and return capped digests',
    whenToUse: 'Phase 1 of the fix-issue skill, after the brief file exists and before any blueprint is written',
    phases: [{ title: 'Investigate', detail: 'one read-only lane per independent question' }],
}

// args: { brief: "<path to brief.md>", root?: "<path to the run's worktree>",
//         track?: "defect" | "change", lanes?: [{key, agentType, question}], extra?: [...] }
//
// The track picks the default lane set. A defect needs tracing, so the lanes hunt the cause. A
// change needs placement, so the lanes hunt the precedent and the surface it has to touch.
//
// Every lane reads the same brief and answers one narrow question. The digest schema is the
// context budget: whatever a lane learned that does not fit here stays in the lane's transcript,
// which the main agent can recover from journal.jsonl or by re-asking a focused follow-up.

const DIGEST = {
    type: 'object',
    additionalProperties: false,
    required: ['verdict', 'confidence', 'anchors', 'unknowns'],
    properties: {
        verdict: { type: 'string', maxLength: 240, description: 'One sentence answering this lane only.' },
        confidence: { type: 'string', enum: ['confirmed', 'inferred', 'blocked'] },
        rootCause: {
            type: ['string', 'null'],
            maxLength: 400,
            description:
                'On a defect, the mechanism rather than the symptom. On a change, the placement or design conclusion this lane supports. Null when this lane cannot establish it.',
        },
        anchors: {
            type: 'array',
            maxItems: 8,
            description: 'Only files this lane actually opened.',
            items: {
                type: 'object',
                additionalProperties: false,
                required: ['ref', 'claim'],
                properties: {
                    ref: { type: 'string', maxLength: 120, description: 'Path/To/File.swift:123' },
                    symbol: { type: 'string', maxLength: 80 },
                    claim: { type: 'string', maxLength: 160, description: 'What is at that line and why it matters.' },
                },
            },
        },
        collateral: {
            type: 'array',
            maxItems: 5,
            description: 'Same failure class found elsewhere. Each needs a reachable scenario.',
            items: { type: 'string', maxLength: 200 },
        },
        risks: { type: 'array', maxItems: 5, items: { type: 'string', maxLength: 160 } },
        unknowns: {
            type: 'array',
            maxItems: 5,
            description: 'What this lane could not establish, and what would settle it.',
            items: { type: 'string', maxLength: 160 },
        },
        tests: {
            type: 'array',
            maxItems: 6,
            description: 'Existing suites that cover this, or the command that would.',
            items: { type: 'string', maxLength: 160 },
        },
    },
}

const CHANGE_LANES = [
    {
        key: 'placement',
        agentType: 'codebase-investigator',
        question:
            'Decide where this behavior belongs. Name the owner that should hold it, the seam it plugs into, and the closest feature already shipping in this repository that solves a similar problem. Return that precedent end to end as a file list: model, view model, view, persistence, registration point, tests, and documentation. The writer will copy its shape, so an inaccurate precedent is worse than none.',
    },
    {
        key: 'platform',
        agentType: 'platform-researcher',
        question:
            'Establish whether the platform, SDK, or dependency supports this at all, and how. Verify the API exists for the deployment target, name the fallback for anything newer, and cite the HIG rule that governs this kind of surface. When the request names a database or driver, verify what the vendored client library and the plugin contract actually allow.',
    },
    {
        key: 'surface',
        agentType: 'codebase-investigator',
        question:
            'Ignore the implementation. Enumerate everything a user-visible feature in this repository has to touch before it can ship: registration and discovery points, menu and keyboard shortcut wiring, settings keys with their defaults and any migration for existing users, localization, the documentation page, the changelog section, feature flags, and the iOS target. Anchor each one to the file where a comparable feature does it.',
    },
    {
        key: 'tests',
        agentType: 'test-strategist',
        question:
            'Find the test that would encode the acceptance criteria, the neighboring suites this change can break, whether deterministic UI automation is possible for the new flow, and the exact serial verification commands including quarantine and environment traps.',
    },
]

const DEFECT_LANES = [
    {
        key: 'path',
        agentType: 'codebase-investigator',
        question:
            'Trace the real shipping execution path that produces the reported behavior. Identify the entry point, the state transitions, the first owner that has enough information to behave correctly, and the root cause separated from the symptom. Name the project-guide invariants that apply.',
    },
    {
        key: 'siblings',
        agentType: 'codebase-investigator',
        question:
            'Ignore the primary path. Search the affected subsystem for the same failure class: silent fallbacks, duplicated source-of-truth lists, missing generation or cancellation checks, and drifted sibling implementations. Every finding needs file:line, a reachable failure scenario, and evidence that no upstream guard already prevents it.',
    },
    {
        key: 'platform',
        agentType: 'platform-researcher',
        question:
            'Establish the documented platform or dependency contract this behavior depends on. Verify the API exists in the installed SDK for the deployment target, check availability and the fallback path, and measure with a minimal probe anything source inspection cannot prove.',
    },
    {
        key: 'tests',
        agentType: 'test-strategist',
        question:
            'Find the smallest regression test that fails before the fix and passes after, the neighboring suites the change can break, whether deterministic UI automation is possible, and the exact serial verification commands including quarantine and environment traps.',
    },
]

const brief = args?.brief
if (!brief) throw new Error('args.brief is required: the path to the run brief')

const track = args?.track ?? 'defect'
if (track !== 'defect' && track !== 'change') throw new Error(`args.track must be "defect" or "change", got "${track}"`)

const lanes = [...(args?.lanes ?? (track === 'change' ? CHANGE_LANES : DEFECT_LANES)), ...(args?.extra ?? [])]

const root = args?.root
const rootLine = root
    ? `\nRead the tree at ${root}, not the directory you started in. That worktree is this run's pinned base; the main checkout has other sessions' half-finished edits in it, and a file that appears or vanishes there is their work, not evidence. Anchor with repository-relative paths so they stay valid in both.\n`
    : ''

const CONTRACT = `
Read ${brief} first. It is the full problem statement and the acceptance criteria. Treat any suspected subsystem in it as a hint, not a conclusion, and treat the reporter's proposed fix or proposed design as a hypothesis: they described what they want, not where it belongs.
${rootLine}

Answer only your own question. Do not design the patch and do not review anyone else's work.

Return the digest schema and nothing else. The schema is a hard context budget, not a summary style: the main agent's context is the scarce resource, so send it only what it needs to decide, with anchors precise enough to verify without re-reading whole files. Your full reasoning stays in this transcript and can be recovered, so do not pad the digest to preserve it.

Rules for the digest:
- Fill a field only when it carries a decision. The array caps are ceilings, not quotas, and an empty list beats a padded one.
- An anchor is only valid for a file you actually opened. Never anchor to a path you inferred.
- Label the lane confirmed only when a file, an SDK interface, or a measured probe backs the verdict. Use inferred when the mechanism is reasoned but unproven, and blocked when you could not establish it.
- An honest unknown outranks a confident guess. A wrong confirmed claim costs more than an empty lane.
`

phase('Investigate')

const results = await parallel(
    lanes.map((lane) => async () => {
        const digest = await agent(`${lane.question}\n${CONTRACT}`, {
            label: `lane:${lane.key}`,
            phase: 'Investigate',
            agentType: lane.agentType,
            schema: DIGEST,
        })
        return digest ? { key: lane.key, agent: lane.agentType, ...digest } : { key: lane.key, agent: lane.agentType, failed: true }
    }),
)

const lanesOut = results.filter(Boolean)
const dead = lanesOut.filter((l) => l.failed).map((l) => l.key)
if (dead.length) log(`lanes returned nothing: ${dead.join(', ')}`)

return {
    brief,
    root: root ?? null,
    track,
    lanes: lanesOut.filter((l) => !l.failed),
    deadLanes: dead,
    unresolved: lanesOut.flatMap((l) => (l.unknowns ?? []).map((u) => `${l.key}: ${u}`)),
}
