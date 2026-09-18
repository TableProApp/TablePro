# Orchestration

The two `Workflow` calls this skill makes: the Phase 1 investigation and the Phase 2 challenge. Both scripts are here in full. Adapt the prompts to the problem, keep the structure.

The skill's instructions are the opt-in the `Workflow` tool requires, so these need no further user consent.

## Rules that apply to both scripts

- **Hardcode the inputs.** Paste the Phase 0 problem statement into the script as a template literal. The `args` parameter has failed to reach the script global before, and a script that silently investigates `undefined` looks like a thorough run that found nothing.
- **Plain JavaScript, not TypeScript.** Type annotations, interfaces and generics fail to parse.
- **No `Date.now()`, `Math.random()`, or argless `new Date()`.** They throw. Vary an agent by its index, not by a random seed.
- **`meta` must be a pure literal.** No variables, calls, spreads, or interpolation inside it.
- **Every claim needs evidence.** `file:line` for code, a doc URL or exact symbol name for platform claims, a named source for competitor behaviour, a reproduction for a collateral finding. `references/research-sources.md` says what counts.
- **Distinguish confirmed from inferred.** An agent that labels its uncertainty is useful. One that sounds certain about everything is a liability, because you will act on it.

## Investigation script (Phase 1)

Four investigators run concurrently, then every collateral finding is adversarially verified before it can reach the Phase 6 register. The barrier between the phases is deliberate: verification needs the full finding set so duplicates across investigators collapse first.

```js
export const meta = {
  name: 'fix-issue-investigation',
  description: 'Trace a TablePro defect, ground it in platform and competitor evidence, hunt collateral defects',
  phases: [
    { title: 'Investigate', detail: 'code path, platform API, competitor UX, collateral defects' },
    { title: 'Verify', detail: 'try to refute each collateral finding' },
  ],
}

const PROBLEM = `
PASTE THE PHASE 0 PROBLEM STATEMENT HERE, VERBATIM.
What happens now, what should happen, the smallest reproduction, the reporter's
environment, and any code pointer they gave (marked as a hint, not a fact).
`

const SUBSYSTEM = `Plugins/DuckDBDriverPlugin/`  // the area the fix will land in

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          location: { type: 'string', description: 'file:line' },
          evidence: { type: 'string' },
          failureScenario: { type: 'string', description: 'concrete inputs or state that produce the wrong result' },
          blocksPrimaryFix: { type: 'boolean', description: 'true if the reported fix is unsafe or incomplete without it' },
        },
        required: ['title', 'location', 'evidence', 'failureScenario', 'blocksPrimaryFix'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    real: { type: 'boolean' },
    reasoning: { type: 'string' },
    howToReproduce: { type: 'string' },
  },
  required: ['real', 'reasoning'],
}

// The context budget for the three reporting lanes. A schema is the ONLY enforceable cap on
// what a lane sends back: a subagent's final message has no limit, and a lane enjoying itself
// will write two thousand words of narration into the main thread. The maxLength values are
// ceilings, not quotas. Detail that does not fit stays in the lane transcript on purpose, and
// is recoverable from the run's journal.jsonl or by re-asking that lane one narrow question.
const DIGEST_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdict', 'confidence', 'anchors', 'unknowns'],
  properties: {
    verdict: { type: 'string', maxLength: 240, description: 'One sentence answering this lane only.' },
    confidence: { type: 'string', enum: ['confirmed', 'inferred', 'blocked'] },
    rootCause: {
      type: ['string', 'null'],
      maxLength: 400,
      description: 'The mechanism rather than the symptom, or the design conclusion this lane supports. Null when it cannot establish one.',
    },
    anchors: {
      type: 'array',
      maxItems: 8,
      description: 'Only files, headers, or SDK interfaces this lane actually opened.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['ref', 'claim'],
        properties: {
          ref: { type: 'string', maxLength: 160, description: 'Path/To/File.swift:123, a symbol name, or a doc URL' },
          claim: { type: 'string', maxLength: 200, description: 'What is there and why it matters.' },
        },
      },
    },
    recommendation: { type: 'string', maxLength: 400, description: 'What this lane thinks we should do, if it has a view.' },
    risks: { type: 'array', maxItems: 5, items: { type: 'string', maxLength: 200 } },
    unknowns: {
      type: 'array',
      maxItems: 5,
      description: 'What this lane could not establish, and what would settle it.',
      items: { type: 'string', maxLength: 200 },
    },
    tests: { type: 'array', maxItems: 6, items: { type: 'string', maxLength: 200 } },
  },
}

const DIGEST_RULES = `
Return the digest schema and nothing else. The schema is a hard context budget, not a summary
style. Fill a field only when it carries a decision; the array caps are ceilings and an empty
list beats a padded one. An anchor is only valid for something you actually opened, so never
anchor to a path you inferred. Label the lane confirmed only when a file, an SDK interface, a
vendored header, a cited source, or a measured probe backs the verdict; use inferred when the
mechanism is reasoned but unproven, and blocked when you could not establish it. An honest
unknown outranks a confident guess, because a wrong confirmed claim costs a verification cycle
to disprove. Your full reasoning stays in this transcript and can be recovered, so do not pad
the digest to preserve it.
`

phase('Investigate')

const [trace, platform, ux, collateral] = await parallel([
  () => agent(`
You are the Codebase Tracer on a TablePro fix investigation. Working dir: the TablePro repo.
Read CLAUDE.md first for architecture context.

Problem statement:
${PROBLEM}

Trace the code that produces this behaviour. I need:
1. The exact files, types and functions involved, with file:line references.
2. The real call path: what triggers this, what state flows through it, where the wrong
   behaviour originates. If more than one path reaches it (buffered vs streaming, grid vs
   export, parameterized vs not), say which one the reported scenario actually takes and
   prove it from the dispatch code.
3. Root cause vs symptom. If the current structure cannot express the correct behaviour
   cleanly, say so and explain why.
4. Blast radius: the reported symptom is usually one case of a class. How many other inputs,
   types, or states hit the same cause?
5. Which TablePro invariants (the Invariants section of CLAUDE.md) this area touches, and
   whether the list already records this area breaking before.
6. Existing tests covering this area and the obvious gaps. Say concretely where a real,
   non-dead test could live. Watch for tests gated behind '#if canImport(C...)', which
   compile to nothing.
7. Whether the fix lands in the app, a bundled plugin, or a registry-only plugin. Name the
   target and, for a plugin, its CI tag.

Change nothing. Say "not confirmed" rather than guessing.
${DIGEST_RULES}
  `, { label: 'trace', agentType: 'feature-dev:code-explorer', schema: DIGEST_SCHEMA }),

  () => agent(`
You are the Platform Researcher on a TablePro fix investigation. TablePro is a native macOS
app (SwiftUI + AppKit, macOS 14+) built with the Xcode at /Applications/Xcode-beta.app.

Problem statement:
${PROBLEM}

Establish what the correct behaviour and the right API are, from the authoritative source.

If this is a UI or interaction problem, that source is Apple:
1. The relevant Human Interface Guidelines section, quoted and linked.
2. The right AppKit/SwiftUI API, named exactly, with its documented behaviour, its
   availability against our macOS 14 target, and its gotchas. Prefer the modern API; if the
   only option is deprecated, say so and name the replacement.
3. Any standard system control that already does this, so we do not reinvent it.
4. Confirm every symbol against the local SDK interface, which is exact for our toolchain:
   /Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/<Framework>.framework/Modules/<Framework>.swiftmodule/arm64e-apple-macos.swiftinterface

If this is a database driver or dependency problem, that source is the vendored header and
the shipped binary, not the web docs:
1. Find the header (look under Plugins/*/C*/include/ and Libs/) and state which version we
   actually link. Build scripts have named a version we never shipped.
2. Grep the header for every symbol in play and quote the doc comments, especially anything
   about deprecation or about what a call returns when it cannot do the job.
3. Where behaviour cannot be read off the header, compile a small C probe against the real
   Libs/*.a and measure it. Report the measured output verbatim. This outranks any doc page.

Separate what you confirmed from what you inferred.
${DIGEST_RULES}
  `, { label: 'platform', schema: DIGEST_SCHEMA }),

  () => agent(`
You are the Competitor / UX Researcher on a TablePro fix investigation. TablePro is a native
macOS database client positioned as a lightweight alternative to TablePlus.

Problem statement:
${PROBLEM}

I need:
1. How TablePlus, DataGrip, Postico and Sequel Ace handle this behaviour, as concretely as
   you can from docs, help pages, release notes and issue trackers. Start with TablePlus:
   most of our users arrive with its habits and often describe it when they say "how it
   should work".
2. The interaction users expect: the control, the keyboard and mouse affordances, the edge
   cases these tools handle.
3. What these tools get wrong that we should avoid. Matching TablePlus is not a goal in
   itself; where it conflicts with the macOS HIG, say so.
4. A short, concrete recommendation for what TablePro should do, with example strings or
   states rather than adjectives.

Use WebSearch and WebFetch. You cannot run these apps, so rely on their documentation and
credible descriptions. Follow the competitor method in references/research-sources.md, and
anchor every competitor claim to the source you read, marked CONFIRMED or INFERRED.
${DIGEST_RULES}
  `, { label: 'ux', schema: DIGEST_SCHEMA }),

  () => agent(`
You are the Collateral Hunter on a TablePro fix investigation. Your job is NOT the reported
bug. It is everything else wrong in the same subsystem, because that subsystem is about to be
edited. What you find gets reported to the user with your evidence, and anything the primary
fix is unsafe or incomplete without ships with it, so set blocksPrimaryFix carefully: true
means the reported fix is wrong or leaves the same class of bug latent unless this lands too.

Reported problem, for context only:
${PROBLEM}

Subsystem to audit: ${SUBSYSTEM}

Look for, with evidence:
- Defects of the same class as the reported one, elsewhere in the same files.
- Paths that silently swallow a failure: an empty catch, a guard that returns the old value,
  a fallback that fabricates a plausible-looking result instead of reporting it could not
  decode. These are the worst kind, because they look like working software.
- Two hand-maintained lists, switches or tables that must agree and that nothing forces to
  agree.
- Work done twice, or a result merged from two separate executions where ordering is not
  guaranteed.
- Forks of this logic elsewhere in the repo that have drifted (check TableProMobile/ and any
  sibling plugin).
- Build or release scripts in scripts/ that reference this subsystem and are stale.

Rules: report only what you can evidence with a file:line and a concrete failure scenario.
Style preferences, naming and "I would have written it differently" do not count and will be
discarded. Better to return three real findings than fifteen speculative ones. Return an empty
list if the subsystem is clean; that is a legitimate and useful answer.
  `, { label: 'collateral', schema: FINDINGS_SCHEMA }),
])

phase('Verify')

const candidates = (collateral && collateral.findings) || []
log(`${candidates.length} collateral findings to verify`)

const verified = await parallel(candidates.map((finding, index) => () =>
  agent(`
Try to REFUTE this claim about the TablePro codebase. Default to refuted when uncertain.

Claim: ${finding.title}
Location: ${finding.location}
Evidence given: ${finding.evidence}
Claimed failure: ${finding.failureScenario}

Read the actual code at that location and the code around it. Then answer: is this real, and
would the described failure actually happen? Check specifically whether something upstream
already prevents it, whether the path is reachable at all in the shipping app, and whether the
claimed behaviour is contradicted by a test or by the dependency's own documented contract.
If measuring settles it, measure it.

Set real=false unless you can state exactly how to reproduce the failure.
  `, { label: `verify:${index + 1}`, phase: 'Verify', schema: VERDICT_SCHEMA })
    .then(verdict => ({ finding: finding, verdict: verdict }))
))

const confirmed = verified.filter(Boolean).filter(item => item.verdict && item.verdict.real)
log(`${confirmed.length} of ${candidates.length} collateral findings survived`)

return { trace: trace, platform: platform, ux: ux, collateral: confirmed }
```

Scale the finder pool to the ask. A contained bug needs the four above. "Audit this properly" justifies several collateral hunters on different slices of the subsystem, and a loop that keeps hunting until two consecutive rounds surface nothing new.

## Challenge script (Phase 2)

Runs after you have written the blueprint. Three critics on distinct lenses beat three on the same one, because a single lens finds a single class of problem.

```js
export const meta = {
  name: 'fix-issue-challenge',
  description: 'Attack a draft TablePro fix blueprint from three independent lenses',
  phases: [{ title: 'Critique', detail: 'patterns, scope, refactor-vs-patch' }],
}

const BLUEPRINT = `
PASTE THE FULL DRAFT BLUEPRINT HERE, PLUS THE ESTABLISHED FACTS IT RESTS ON,
SO THE CRITICS DO NOT RE-DERIVE THEM OR ARGUE WITH SETTLED MEASUREMENTS.
`

// The critics used to return free text. A subagent's final message has no length limit, so three
// of them writing essays is exactly the context blowout DIGEST_RULES warns about in the
// investigation script. The schema is the only thing that actually caps it.
const OBJECTIONS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['lens', 'verdict', 'objections'],
  properties: {
    lens: { type: 'string', maxLength: 40 },
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
          severity: { type: 'string', enum: ['blocking', 'material', 'minor'] },
          claim: { type: 'string', maxLength: 240 },
          evidence: { type: 'string', maxLength: 240, description: 'file:line, an SDK symbol, or measured output. Reasoning alone is not evidence.' },
          correction: { type: 'string', maxLength: 240, description: 'The smallest change to the blueprint that answers this.' },
        },
      },
    },
  },
}

const LENSES = [
  {
    key: 'patterns',
    ask: `Where does this design fight existing patterns in the codebase instead of following
them? Cite the pattern with file:line. Does the repo already have a helper, protocol hook or
convention for this that the blueprint reinvents? Does it violate any invariant in CLAUDE.md?`,
  },
  {
    key: 'scope',
    ask: `What scope is missing? Callers that break, files that also need changing, state or
persistence that goes stale, edge cases the design does not mention. Be specific about inputs:
empty, null, duplicated names, sentinel values, very large results, cancellation. Does the
CHANGELOG or docs claim more than the change delivers?`,
  },
  {
    key: 'decision',
    ask: `Is the refactor-vs-patch call right? If this patches a symptom while the underlying
cause survives, say so plainly. If it refactors more than the cause justifies, say that too.
Is there a better-fitting documented API than the one chosen? Name it. Is the rejected
alternative rejected for a real reason or a convenient one?`,
  },
]

phase('Critique')

const critiques = await parallel(LENSES.map(lens => () => agent(`
You are reviewing a draft implementation blueprint for a TablePro fix. Read CLAUDE.md, paying
particular attention to the Invariants section.

Draft blueprint:
${BLUEPRINT}

Attack it through one lens only: ${lens.key}.

${lens.ask}

I want weaknesses, not a summary. If a part of the blueprint is sound, say so in one line and
move on. Verify before you assert: read the files you cite, and measure rather than assume when
the answer depends on a dependency's behaviour. A confident wrong objection costs more than a
missed one, because it will be acted on. Report as structured text with file:line evidence.
  `, { label: `critique:${lens.key}`, agentType: 'feature-dev:code-architect', schema: OBJECTIONS_SCHEMA })))

return critiques.filter(Boolean)
```

## Reading the results

- Fold what survives into the blueprint. A critic can be wrong; check its file:line before acting on it.
- When a critic and a measurement disagree, the measurement wins.
- A critic finding that is real but outside the reported fix is not a reason to widen the primary PR. It is a new entry in the collateral register, and Phase 6 ships it.
