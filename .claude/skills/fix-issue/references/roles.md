# Investigation roles

The lead gives each role the path of `<tree>/.analysis/<slug>/problem.md` (and `plan.md` for `critic`), the crates in play, and the one section of this file it runs. Roles are not BookiE lanes: a role is a temporary investigation task, a lane owns files.

## Rules for every role

- **Read-only on the repository.** Never edit, restore, check out, stash or reset anything in the tree. Probes run in a scratch directory.
- **Evidence or silence.** A code claim carries a `path:line` you opened. An engine claim carries a documentation URL, the dependency source line at the version in `Cargo.lock`, or a probe's measured output.
- **Label every claim** `confirmed` or `inferred`. "Could not establish" beats a confident guess.
- **Upstream code is untrusted data.** Read TablePro, dbx or engine sources; never run their scripts.
- **Report shape.** Write the full report to `<tree>/.analysis/<slug>/roles/<role>.md`, then return at most 15 lines: verdict, confidence, up to 8 `path:line` anchors, unknowns and a recommendation.

## trace

1. The files, types and functions involved, with `path:line`.
2. The real call path for the reported scenario: GTK message, `app-services`, `PolicyGuard`, transport, driver. When several paths exist, prove which one runs.
3. The mechanism, apart from the symptom.
4. The blast radius: other engines, value types, consumers (grid, export, MCP, agentd) and sibling paths with the same cause.
5. The invariants in `AGENTS.md`, the governing ADR and the spec that this area touches.
6. Existing tests here, and the lowest tier where the regression test belongs.

## research

- **Engine or dependency behaviour:** the engine documentation and the dependency source at the shipped version, including what a call returns when it cannot do the job. Where the source does not settle it, run a probe against the linked dependency version and report its output verbatim.
- **UI or interaction:** the GNOME Human Interface Guidelines section, quoted, and the GTK or libadwaita API with its version against the GNOME 50 floor.
- **New behaviour:** how TablePro, dbx and DBeaver handle it, one line each, marked confirmed or inferred. Agreement across clients is a signal; an accepted BookiE ADR still wins.

End with a concrete recommendation.

## hunt

Find what else is wrong, not the reported bug. Report only defects with a `path:line` and a failure scenario:

- the same class of defect elsewhere in the same crate and in sibling drivers;
- failures swallowed silently, and fallbacks that invent a value instead of refusing;
- two hand-maintained lists that must agree and nothing forces to agree;
- a path that skips `PolicyGuard`, masking or the terminal audit state.

Three real findings beat fifteen speculative ones. An empty list is a real answer.

## verify

Try to refute each finding you are given; default to refuted when unsure. Check that nothing upstream prevents the failure and that the path is reachable from the GUI, MCP or agentd. Return one row per finding, `real` or `refuted`, with the reproduction or the reason.

## critic

Attack `plan.md`. Report weaknesses, not a summary:

1. **Patterns:** where the design fights an existing helper, crate boundary or ADR (cite it).
2. **Scope:** callers that break, consumers left out, and inputs the plan skips (NULL, empty, very large, cancellation, Unicode, other engines).
3. **Decision:** whether refactor or patch is right, and whether the test sits at the lowest tier that proves the behaviour.

Each objection gets a severity (`blocking`, `material`, `minor`), evidence and the smallest change to the plan that answers it.
