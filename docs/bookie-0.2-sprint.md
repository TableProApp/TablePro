# BookiE 0.2 completion and continuation

## Delivery status

The maintainer confirmed 0.2.0 delivery complete on 2026-10-18. Release `linux-v0.2.0` is published and the delivery sprint is closed. The [platform guide](platforms.md#published-020-release) records its assets and package names. Remaining work and candidate order for future releases are in the [backlog](backlog.md).

The [0.2.0 scope](0.2.0-scope.md) records the completed delivery boundary. The previous scope and sprint checklists are preserved in the [completion handoff](archive/bookie-0.2-completion-handoff-2026-10-18.md). Their historical open rows do not reopen 0.2.0. This status records the maintainer's decision, not a new run of the package, driver or desktop checks.

## Current continuation

The [post-0.2.0 backlog](backlog.md) owns selected development order. [Project #3](https://github.com/users/cozyGarage/projects/3) owns issue status and Lane; the [ledger index](known-issues.md) maps IDs to issues. Existing open correctness, qualification and infrastructure issues keep their evidence and follow-up scope. They are not silently closed by a milestone-status change.

## Standing decisions

| Topic | Canonical decision |
|---|---|
| Static drivers; Linux GTK stack; Relm4 ownership | ADRs [0001](decisions/0001-no-plugin-system.md), [0002](decisions/0002-rust-gtk4-libadwaita.md), [0003](decisions/0003-relm4-architecture.md) |
| Credentials; server cancellation; panic containment | ADRs [0004](decisions/0004-libsecret-secret-storage.md), [0005](decisions/0005-server-side-cancellation.md), [0006](decisions/0006-driver-panic-containment.md) |
| Native type/value outcomes and proof | [ADR 0007](decisions/0007-type-and-value-preservation.md) |
| Session ownership, trust and uncertain outcomes | [ADR 0008](decisions/0008-connection-and-session-ownership.md) |
| Durable identity and recoverable state | [ADR 0009](decisions/0009-persistence-and-identity-compatibility.md) |
| Cursor results and full exports | ADRs [0011](decisions/0011-paged-query-results.md), [0014](decisions/0014-full-table-export-snapshot.md) |
| Shared governed consumer path and headless services | ADRs [0016](decisions/0016-governed-consumer-seam.md), [0018](decisions/0018-headless-app-services-crate.md) |

The remaining accepted decisions are in the [ADR index](decisions/README.md). Upstream source reuse does not change these contracts implicitly.

## Working on the next packet

Choose one lane-owned issue and refresh its source pins and competing PRs. State existing coverage, the missing user case, allowed files and observable acceptance. Record a handoff before cross-lane edits. Preserve exact native values, session identity, terminal audit outcomes and safe refusals.

Use the existing [validation tiers](validation-playbook.md), with one failing-before regression for a changed behavior. Driver contracts need real-engine outcomes; visual or package claims need their installed checks. Keep GitHub cheap checks and the serialized Forgejo merge gate. Record skipped, blocked and unrun checks explicitly.

Broader type/consumer matrices, mutation triage, Debian/GNOME desktop work, Flatpak and new features continue under their existing backlog owners. See [known limitations](known-limitations.md) for user-visible restrictions and the [value evidence index](value-contracts.md) for case-specific proof.

## History

The [completion handoff](archive/bookie-0.2-completion-handoff-2026-10-18.md) preserves the immediately preceding scope, qualification recipes and packet lists. The [test and validation summary](archive/bookie-0.2-test-records-2026-10-23.md) collects historical coverage records. The older [sprint history](archive/bookie-0.2-history.md) holds earlier implementation records. Read the case needed; dated plans do not override current decisions or scheduling.
