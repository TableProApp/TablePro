# BookiE roadmap

The [active 0.2 sprint](docs/bookie-0.2-sprint.md) owns scope, order and
acceptance. This page is a status index only; it does not define separate work
or repeat task-level evidence.

## Current milestone

BookiE 0.2.0 is in progress. The B3 value/consumer contract milestone remains
open; completed cases and remaining exact-support work are tracked in the
[B3 board](docs/type-contract-strategy.md). B4 implementation packets are on
the [B4 board](docs/b4-task-board.md). Desktop qualification and release gates
remain in the active sprint.

## After 0.2.0

The
[external audit and improvement plan](docs/archive/external-audit-2026-10-06.md)
proposes root workspace organization, Rust backend ownership checks,
GitHub/test tooling, docs/examples/evidence synchronization and optional
driver reuse. Review it after completing 0.2.0; these pending packets do not
extend the active sprint.

## Status rules

- **Implemented**: code and core tests exist.
- **Integrated**: intended production entry points use the behavior.
- **Release-verified**: deterministic real-driver, UI or installed-package
  checks prove the behavior for the stated source and environment.
- **Complete**: all acceptance criteria for the owning milestone are met.

Do not infer milestone completion from a passing subset of tests. Use the
[validation playbook](docs/validation-playbook.md) for local checks and the
[changelog](CHANGELOG.md) for dated implementation and evidence records.
