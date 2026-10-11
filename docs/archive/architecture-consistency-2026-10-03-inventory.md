# Documentation and evidence review inventory

Companion to [the review](architecture-consistency-review-2026-10-03.md). Keep
this inventory for path-level failure and disposition tables; open product
items live in the [ledger](../known-issues.md), not here.

Starting source: `4b7814f5e1f586c3761c1454e66d3394ad2c9609`. Reviewed 2026-10-03.

Every row received the consistency screen described in the review.
Baseline/current digests and exact checks are in [the manifest](../evidence/architecture-review-2026-10-03/manifest.json).
A screened row is not exhaustive semantic certification or a runtime pass.

## All tracked Markdown at baseline

| Path | Classification | Disposition |
| --- | --- | --- |
| `.github/workflows/daily-repo-status.md` (removed after this inventory) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [CLAUDE.md](../../CLAUDE.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [CODE_OF_CONDUCT.md](../../CODE_OF_CONDUCT.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [CONTRIBUTING.md](../../CONTRIBUTING.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [PLAN.md](../../PLAN.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [README.md](../../README.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [external-audit-2026-10-06.md](external-audit-2026-10-06.md) | archived dated review (moved from repo root 2026-10-10) | Corrected authority, source drift or evidence qualification |
| [linux/ARCHITECTURE.md](../../ARCHITECTURE.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/CHANGELOG.md](../../CHANGELOG.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/CONTRIBUTING.md](../../CONTRIBUTING.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/LICENSE.md](../../LICENSE.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/README.md](../../README.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/ROADMAP.md](../../ROADMAP.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/accessibility.md](../platforms.md#accessibility) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/adding-drivers.md](../adding-drivers.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/b3-review-2026-10-01.md](b3-review-2026-10-01.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/b3-test-scenario-survey.md](b3-test-scenario-survey.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/b4-task-board.md](../b4-task-board.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/baseline-review-2026-09-17.md](baseline-review-2026-09-17.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| `linux/docs/bookie-0.1.1-plan.md` (retired after this inventory) | dated plan | Superseded by the active 0.2 sprint; see the [changelog history index](../../CHANGELOG.md#engineering-history-index) |
| [linux/docs/bookie-0.2-sprint.md](../bookie-0.2-sprint.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/bug-consistency-2026-09.md](bug-consistency-2026-09.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/capability-evidence.md](../capability-evidence.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/ci-audit-2026-09-27.md](ci-audit-2026-09-27.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/code-conventions.md](../code-conventions.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/connections.md](../connections.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/decisions/0001-no-plugin-system.md](../decisions/0001-no-plugin-system.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/decisions/0002-rust-gtk4-libadwaita.md](../decisions/0002-rust-gtk4-libadwaita.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/decisions/0003-relm4-architecture.md](../decisions/0003-relm4-architecture.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/decisions/0004-libsecret-secret-storage.md](../decisions/0004-libsecret-secret-storage.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/decisions/0005-server-side-cancellation.md](../decisions/0005-server-side-cancellation.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/decisions/0006-driver-panic-containment.md](../decisions/0006-driver-panic-containment.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/decisions/README.md](../decisions/README.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/disconnection-contracts.md](../disconnection-contracts.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/adding-drivers.md#driver-maturity](../adding-drivers.md#driver-maturity) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/driver-priority.md](../adding-drivers.md#order-the-engines-were-added) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/error-handling.md](../error-handling.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/flathub.md](../platforms.md#flathub) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/ignored-tests.md](../../scripts/inventory-ignored-tests.py) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/manual-verification-0.2-features.md](../manual-verification-0.2-features.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/omarchy.md](../platforms.md#arch-and-omarchy-package) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/performance-2026-09.md](performance-2026-09.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/production-audit.md](production-audit.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/reconciliation-2026-09-26.md](reconciliation-2026-09-26.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/regression-audit-2026-09-29.md](regression-audit-2026-09-29.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/release-0.1.4.md](release-0.1.4.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/sprint-2026-09-14.md](sprint-2026-09-14.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/sprint-review-2026-09-28.md](sprint-review-2026-09-28.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/stabilization-2026-09.md](stabilization-2026-09.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/state-management.md](../state-management.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/storage.md](../storage.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/testing.md](../testing.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/toolchains.md](../platforms.md#rust-toolchain) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/type-contract-strategy.md](../type-contract-strategy.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/upstream-adoption.md](upstream-adoption.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/upstream-main-review-2026-10-03-inventory.md](upstream-main-review-2026-10-03-inventory.md) | dated evidence/planning record | Screened; retain recorded revision and limits |
| [linux/docs/upstream-main-review-2026-10-03.md](upstream-main-review-2026-10-03.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/upstream-sync.md](../upstream-sync.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/upstream-u1-sql-server-2026-10-03.md](upstream-u1-sql-server-2026-10-03.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/docs/validation-playbook.md](../validation-playbook.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/docs/value-contracts.md](../value-contracts.md) | current guide or mixed historical ledger | Corrected authority, source drift or evidence qualification |
| [linux/flatpak/screenshots/README.md](../../apps/linux/flatpak/screenshots/README.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/packaging/README.md](../../apps/linux/packaging/README.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/po/README.md](../../apps/linux/po/README.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/tests/fixtures/postgres-release/README.md](../../tests/fixtures/postgres-release/README.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/tests/manual-connections/README.md](../../tests/manual-connections/README.md) | reference/guide | Screened; retain stated scope, no exhaustive claim |
| [linux/vendor/README.md](../../vendor/README.md) | vendored reference | Screened; preserve upstream scope |
| [linux/vendor/mongodb/README.md](../../vendor/mongodb/README.md) | vendored reference | Screened; preserve upstream scope |
| [linux/vendor/redis/README.md](../../vendor/redis/README.md) | vendored reference | Screened; preserve upstream scope |
| [linux/vendor/sqlx-postgres/src/options/doc.md](../../vendor/sqlx-postgres/src/options/doc.md) | vendored reference | Screened; preserve upstream scope |
| [linux/vendor/sqlx-postgres/src/types/bigdecimal-range.md](../../vendor/sqlx-postgres/src/types/bigdecimal-range.md) | vendored reference | Screened; preserve upstream scope |
| [linux/vendor/sqlx-postgres/src/types/rust_decimal-range.md](../../vendor/sqlx-postgres/src/types/rust_decimal-range.md) | vendored reference | Screened; preserve upstream scope |

## All tracked retained evidence at baseline

| Path | Structural check | Attribution |
| --- | --- | --- |
| [linux/docs/evidence/2026-09-29-regression-audit/binary-before.txt](../evidence/2026-09-29-regression-audit/binary-before.txt) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/2026-09-29-regression-audit/change-contracts-before.txt](../evidence/2026-09-29-regression-audit/change-contracts-before.txt) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/2026-09-29-regression-audit/decimal-before.txt](../evidence/2026-09-29-regression-audit/decimal-before.txt) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/2026-09-29-regression-audit/isolated-before.txt](../evidence/2026-09-29-regression-audit/isolated-before.txt) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/2026-09-29-regression-audit/validation.json](../evidence/2026-09-29-regression-audit/validation.json) | valid-json | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/2026-09-bug-consistency/validation.json](../evidence/2026-09-bug-consistency/validation.json) | valid-json | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/2026-09-stabilization/postgres-after.jsonl](../evidence/2026-09-stabilization/postgres-after.jsonl) | valid-jsonl | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/2026-09-stabilization/postgres-before.jsonl](../evidence/2026-09-stabilization/postgres-before.jsonl) | valid-jsonl | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/2026-09-stabilization/validation.json](../evidence/2026-09-stabilization/validation.json) | valid-json | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/b3-review-2026-10-01/manifest.json](../evidence/b3-review-2026-10-01/manifest.json) | valid-json | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/b3-review-2026-10-01/probe.rs](../evidence/b3-review-2026-10-01/probe.rs) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/b3-review-2026-10-01/probe.txt](../evidence/b3-review-2026-10-01/probe.txt) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/b3-review-2026-10-01/xlsx-float-precision.txt](../evidence/b3-review-2026-10-01/xlsx-float-precision.txt) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/upstream-u1-2026-10-03/native-after.txt](../evidence/upstream-u1-2026-10-03/native-after.txt) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/upstream-u1-2026-10-03/native-before.txt](../evidence/upstream-u1-2026-10-03/native-before.txt) | utf8-text | Dated source/fixture scope; current and candidate digest results in manifest |
| [linux/docs/evidence/upstream-u1-2026-10-03/validation.json](../evidence/upstream-u1-2026-10-03/validation.json) | valid-json | Dated source/fixture scope; current and candidate digest results in manifest |

## Unavailable local references

Preserved references below are cache/vendor paths; they are not current acceptance proof.

| Document | Line at this review | Missing target |
| --- | --- | --- |
| `linux/docs/validation-playbook.md` | 39 | `../target/quality/20261001T235848303064Z-layers/report.json` |
| `linux/docs/validation-playbook.md` | 44 | `../target/quality/20261001T231537044614Z-layers/report.json` |
| `linux/docs/validation-playbook.md` | 46 | `../target/quality/20261001T232237703877Z-layers/report.json` |
| `linux/docs/validation-playbook.md` | 51 | `../target/quality/20261001T232237703877Z-layers/report.json` |
| `linux/docs/value-contracts.md` | 1599 | `../target/quality/20261002T001913901283Z-layers/report.json` |
| `linux/docs/value-contracts.md` | 1600 | `../target/quality/20261002T001913960449Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3543 | `../target/quality/20261002T003009990931Z-layers/report.json` |
| `linux/docs/value-contracts.md` | 3544 | `../target/quality/20261002T003010044333Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3562 | `../target/quality/20261002T005849903174Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3579 | `../target/quality/20261002T072337041331Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3581 | `../target/quality/20261002T072915341877Z-quick/report.json` |
| `linux/docs/value-contracts.md` | 3597 | `../target/quality/20261002T074300432752Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3599 | `../target/quality/20261002T074833600560Z-quick/report.json` |
| `linux/docs/value-contracts.md` | 3616 | `../target/quality/20261002T080301493778Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3618 | `../target/quality/20261002T111624439672Z-quick/report.json` |
| `linux/docs/value-contracts.md` | 3745 | `../target/quality/20261002T004142618874Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3764 | `../target/quality/20261002T120704261619Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3766 | `../target/quality/20261002T121254146544Z-quick/report.json` |
| `linux/docs/value-contracts.md` | 3773 | `../target/quality/20261002T124905277939Z-values/report.json` |
| `linux/docs/value-contracts.md` | 3775 | `../target/quality/20261002T125842206487Z-quick/report.json` |
| `linux/vendor/redis/README.md` | 307 | `DEVELOPMENT.md` |
