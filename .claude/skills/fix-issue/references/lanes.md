# Lane briefs

The lead hands each lane the path of `<tree>/.analysis/<slug>/problem.md` (and, for `critic`, `plan.md`), the subsystem in play, and the one section of this file it runs. A lane reads only its own section plus the rules below.

## Rules for every lane

- **Read-only on the repo.** Never edit, `git restore`, `git checkout`, stash or reset anything in the checkout. An experiment runs on a copy in the scratchpad. A prompt that says "read-only" is not a sandbox, so this rule is what keeps a lane from reverting the lead's work.
- **Evidence or silence.** Code claims carry a `path/File.swift:123` you opened. Platform claims carry a doc URL or an exact symbol, plus the `.swiftinterface` line when the question is whether an API exists. Dependency claims carry the vendored header line or a probe's measured output. Competitor claims carry the source you read.
- **Label every claim** `confirmed` (opened, measured or cited) or `inferred` (reasoned but unproven). An honest "could not establish" beats a confident guess, because a wrong confirmed claim is acted on.
- **Report shape.** Write the full report wherever the harness file says, then return a digest of at most 15 lines: a verdict sentence, the confidence label, up to 8 anchors (`ref`: what is there), the unknowns, and your recommendation. The lead opens the full report only where the plan depends on it, so the digest is not a summary of everything you found.

## trace

Find the cause of the reported behavior.

1. The files, types and functions involved, with `file:line`.
2. The real call path the reported scenario takes: what triggers it, what state flows through it, and where the wrong behavior starts. When several paths reach the behavior, prove which one this scenario takes from the dispatch code.
3. The mechanism, separated from the symptom. When the current structure cannot express the correct behavior without a special case, say so and why.
4. The blast radius: every other input, type, engine, state or sibling surface the same cause reaches.
5. The `CLAUDE.md` invariants this area touches, and whether that list already records this area breaking before.
6. The existing tests here and where a real regression test belongs. Tests behind `#if canImport(C...)` compile to nothing.
7. Where the fix lands: the app, a bundled plugin, a registry-only plugin (name its target), or `TableProMobile`.

## research

Establish the correct behavior from the authoritative source. `references/research-sources.md` lists where to look.

- **UI or interaction**: the HIG section, quoted and linked; the AppKit or SwiftUI API, named exactly, with its documented behavior, its availability against macOS 13 and its gotchas; any standard control that already does this. Confirm every symbol against the SDK `.swiftinterface`.
- **Driver or dependency**: the vendored header, with the version we actually link, the doc comments for each symbol in play, and what a call returns when it cannot do the job. Where the header does not settle it, compile a probe against `Libs/*.a` in the scratchpad and report the output verbatim.
- **New feature or changed interaction**: how comparable clients behave, starting with the one most users arrive from, each claim marked confirmed or inferred. Where a client and the HIG disagree, the HIG wins. This is input to the design, never text for the repo.

End with a concrete recommendation: the API, the states, the example strings.

## hunt

Find what else is wrong, not the reported bug. Everything you report that survives verification ships in this PR, so report only defects, each with a `file:line` and a failure scenario someone could actually hit.

Look in the subsystem the fix touches, then wherever the same cause or pattern lives:

- the same class of defect elsewhere in the same files, sibling plugins, `TableProMobile` and `scripts/`
- failures swallowed silently: an empty `catch`, a guard that returns the old value, a fallback that invents a plausible result instead of reporting it could not decode
- two hand-maintained lists, switches or tables that must agree and that nothing forces to agree
- work done twice, or results merged from two executions whose order is not guaranteed
- forks of this logic that have drifted apart

For each finding give: title, `file:line`, evidence, failure scenario, and whether the primary fix is wrong or incomplete without it. Style, naming and "I would have written it differently" do not count. Three real findings beat fifteen speculative ones, and an empty list is a real answer.

## verify

Try to refute each finding in the list you are given. Default to refuted when unsure.

For each one: read the cited code and its surroundings, check that nothing upstream already prevents the failure, that the path is reachable in the shipping app, and that no test or documented contract contradicts it. Measure it when measuring settles it. Return one row per finding, `real` or `refuted`, with how to reproduce it or why it fails. A finding is `real` only when you can state the reproduction.

## critic

Attack `plan.md`. Report weaknesses, not a summary; a sound part gets one line. Cover three lenses:

1. **Patterns**: where the design fights an existing pattern, helper or convention in the repo (cite it), or breaks a `CLAUDE.md` invariant.
2. **Scope**: callers that break, state or persistence that goes stale, and inputs the plan skips (empty, null, duplicate names, sentinel values, very large results, cancellation). Also a CHANGELOG or docs claim that says more than the change does.
3. **Decision**: whether refactor-or-patch is right, whether a better documented API exists (name it), and whether the rejected alternative was rejected for a real reason.

Each objection gets a severity (`blocking`, `material` or `minor`), evidence (`file:line`, an SDK symbol or measured output, since reasoning alone is not evidence), and the smallest change to the plan that answers it. Read the files you cite: a confident wrong objection costs more than a missed one.
