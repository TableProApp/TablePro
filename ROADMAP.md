# BookiE roadmap

The [completion and continuation page](docs/bookie-0.2-sprint.md) records milestone status; the [backlog](docs/backlog.md) owns post-0.2.0 order. This page is a status index only; it does not define separate work or repeat task-level evidence.

## Current milestone

The maintainer confirmed on 2026-10-18 that BookiE 0.2.0 delivery work is complete. Release publication is pending. The [completion handoff](docs/archive/bookie-0.2-completion-handoff-2026-10-18.md) preserves prior scope and acceptance records; new development follows the backlog and Project #3.

## Repository layout

The Cargo workspace already lives at the repository root (`crates/`, `apps/linux/`, `tests/`, `scripts/`, `docs/`). See [ARCHITECTURE.md](ARCHITECTURE.md#repository-layout).

## After 0.2.0

The [backlog](docs/backlog.md) owns selected work after 0.2.0, including upstream Linux adoption [#1149](https://github.com/cozyGarage/BookiE/issues/1149). The [development-process audit](docs/archive/upstream-linux-adoption-2026-10-18.md) covers code reuse, infrastructure, CI, conventions and release tooling. The [feature comparison](docs/0.2-feature-comparison.md) records parity candidates, including current-source dispositions for reported gaps and upstream bug fixes; candidates are not release commitments. The [October 20 TablePro and dbx deep review](docs/archive/tablepro-dbx-review-2026-10-20/README.md) ranks the latest candidate waves and defects to confirm. The [external audit and improvement plan](docs/archive/external-audit-2026-10-06.md) remains the dated reference for backend ownership checks, GitHub/test tooling, docs/examples/evidence synchronization, performance measurement and optional driver reuse. None of these documents extends the active sprint.

## Status rules

- **Implemented**: code and core tests exist.
- **Integrated**: intended production entry points use the behavior.
- **Release-verified**: deterministic real-driver, UI or installed-package checks prove the behavior for the stated source and environment.
- **Complete**: all acceptance criteria for the owning milestone are met.

Do not infer milestone completion from a passing subset of tests. Use the [validation playbook](docs/validation-playbook.md) for local checks and the [changelog](CHANGELOG.md) for dated implementation and evidence records.
