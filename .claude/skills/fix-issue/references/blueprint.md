# The Blueprint

`.analysis/<slug>/blueprint.md` is the run's contract. It is the input the critics attack, the
instruction the implementer follows, the checklist shipping reads, and the one artifact that
survives a compaction. Written well, nothing later has to reconstruct the plan from the
conversation. Written vaguely, the implementer invents the missing half and you find out in the diff.

Write it before touching a product file, and update it when a critic or a measurement changes it.

## On a defect

- **Root cause**, stated as a mechanism and separated from the symptom. "The list does not refresh"
  is a symptom. "The refresh clears the cache it is about to read, so the second call sees empty"
  is a cause.
- **The ownership boundary** that makes the behavior correct: which type first has enough
  information to decide, and why the fix belongs there rather than where the symptom appeared.
- **Targeted fix or refactor**, with the reason. See `quality-bar.md`.

## On a change

- **The design**, the ownership boundary it sits at, and the **precedent** it follows, named as
  files. Where it departs from that precedent, say why. Copying a shipping example beats inventing
  a shape, and an inaccurate precedent is worse than none.
- **The user-visible surface**: entry point, menu placement, keyboard shortcut, settings and their
  defaults, empty state, error state, and what happens to existing users and their stored data.
- **The non-goals.** Unwritten, they let each critic, reviewer, and implementer invent a different
  larger feature. Written, a plan that respects them is complete rather than thin.

## Both tracks

- **Every affected path**: callers, state, persistence, plugins, docs, localization, migration, ABI.
- **The invariants it must not break**, named, from the project guide.
- **The file list.** Shipping stages exactly this, by explicit path, so a file missing here does not
  get committed and a file added here without a reason gets caught.
- **Verification**: the test that fails before and passes after, plus the build, lint, UI, probe,
  and ABI steps this change requires, as `verify.sh` steps.
- **The collateral register**, in three parts: required scope, independently useful findings, and
  unverified hypotheses. The middle part becomes the follow-up queue, so each entry needs
  `file:line`, a reachable failure scenario, and evidence that no upstream guard already prevents
  it. See `shipping.md`.
- **Rejected objections** and why, once the critique phase has run. Otherwise the next reader
  re-raises them.

## The test it has to pass

Hand the blueprint to someone who did not watch the investigation. If they cannot implement it
without guessing, it is not finished, and finishing it now is cheaper than discovering the gap in a
diff or a review.
