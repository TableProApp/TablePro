# Linux architecture and evidence consistency review

Reviewed on 2026-10-03 at `4b7814f5e1f586c3761c1454e66d3394ad2c9609`, branch
`linux`, fork `cozyGarage/BookiE`. The checkout was fast-forwarded from
`6822efa42` to include the already merged editor retirement fix (#19).
This follow-up changes documentation only.

## Scope and conclusion

The inventory covers **all 72 tracked Markdown files** at the starting SHA
(66 first-party, six vendored), plus **all 16 tracked evidence files** under
`linux/docs/evidence/`. Each document received authority/date, architecture
claim and local-link screening. High-risk statements were checked against
current manifests and relevant production source. This is a consistency audit,
not exhaustive semantic certification of every sentence or every Rust file.

The [per-file inventory](architecture-consistency-2026-10-03-inventory.md) and
[manifest](../evidence/architecture-review-2026-10-03/manifest.json) retain coverage,
source fingerprints, dependency edges, evidence checks and unresolved links.
The manifest describes its mechanical checks; it does not turn a screened
document into a runtime pass.

The declared crate graph is acyclic. Core/policy/drivers remain headless;
drivers depend only on core among workspace crates. The GTK and headless
composition roots use the shared transport and policy boundary. Existing
architectural choices fit together. Documentation drift and several known
ownership/privacy gaps remain the risk; a redesign is not justified by this
audit. B3/B4 and installed-package acceptance remain open.

## Document authority

| Question | Authority | How to use older records |
| --- | --- | --- |
| Crate boundaries, GTK ownership, secret storage, cancellation and panic strategy | Accepted [ADRs](../decisions/README.md), `CLAUDE.md`, [architecture](../../ARCHITECTURE.md), actual manifests | External planning advice cannot override these. Resolve a code/ADR mismatch explicitly |
| Delivery order and milestone acceptance | [Active 0.2 sprint](../bookie-0.2-sprint.md), with [B4 board](../b4-task-board.md) and B3 case ledgers | PLAN is the capability backlog/entry point; ROADMAP summarizes it. Archived phase checkboxes do not close newer gates |
| A specific bug, native type or consumer contract | [Value contracts](../value-contracts.md), [B3 findings](b3-review-2026-10-01.md), retained evidence at its SHA | Match implementation fingerprint, selector, fixture and consumer scope. A nearby commit or test count is insufficient |
| Test selection and execution ownership | [Validation playbook](../validation-playbook.md), [testing](../testing.md), executable layer catalog and workflows | Distinguish checked-in tests, local execution, hosted jobs and installed acceptance |
| External bug-fix adoption | [Main review](upstream-main-review-2026-10-03.md), [older releases](upstream-older-releases-review-2026-10-03.md), [adoption matrix](upstream-adoption.md) | Release notes and subjects nominate reproductions. Existing Linux contracts decide implementation |
| Release approval | Frozen-candidate acceptance in the sprint | Source versions, recipes, historic published packages and a green fixture do not promote 0.2 |

## Source boundaries checked

1. **Headless graph.** All 18 workspace package manifests were inspected,
   including local normal/build/dev edges. Core has no workspace dependency;
   policy and eight production drivers point to core. SQLite also has a test-only policy dependency for governed fixtures; it introduces no production cycle. Storage points to core/policy/SSH;
   transport points to core/storage/SSH; MCP points to core/policy/storage.
   App and agentd assemble them. Test-support crates consume the same contracts.
   GTK dependencies belong to the app. No dependency cycle was found.
2. **Policy and audit.** `DatabaseService::guard_with_identity` returns a
   `PolicyGuard` and weak physical-connection identity; agentd wraps its acquired
   handle too. MCP scopes and SQL policy retain distinct responsibilities.
   Guarded writes keep durable intent and honest unknown outcomes. This source
   trace is not a proof that all future entry points are automatically guarded.
3. **Ownership.** Relm4 command/messages keep GTK on its main context. Per-tab
   `thread_local!` registries are documented exceptions, not cross-thread global
   mutation. Dedicated editor sessions pin one connection; the merged retirement
   fix refuses subsequent SQL rather than falling back to a pool. F4/F9 still
   own invalidation after an automatic shared-connection/tunnel replacement.
4. **Persistence.** GSettings preferences/geometry coexist with JSON fallback
   and rollback mirrors. Workspace's locked per-connection merge writer and
   whole-document `StateFile` have different concurrency contracts; merging them
   mechanically would lose updates. Stable app/keyring/XDG identifiers survive
   the BookiE rename. Secrets remain in Secret Service, with typed access errors.
5. **Transport.** Saved assembly separates service identity from the dial
   endpoint. PostgreSQL tunneled verification uses a private Unix socket;
   explicit TCP identity handling exists for SQL Server/ClickHouse. Saved client
   certificate/key assembly remains U5. Built-in russh and system OpenSSH are
   distinct backends under shared route ownership.
6. **Panic containment.** The guard catches unwinds and reports read failures or
   unknown writes. No Cargo profile selects `panic = "abort"`. ADR 0006 requires
   unwind; the contrary external recommendation was explicitly superseded.

## Documentation corrections

| Conflict | Correction and reason |
| --- | --- |
| PLAN and ROADMAP both claimed sequencing authority | Sprint owns delivery/acceptance; ADRs constrain it; historical phase records are labeled |
| Root build instructions still required Rust 1.93 / older GTK | Match pinned Rust 1.98 and ADR 0002 GNOME 50 library requirements |
| Architecture described JSON-only preferences and Ubuntu 25.10 GTK CI | Match GSettings mirrors, Debian testing GTK CI and GNOME 50 Flatpak builder; do not imply installed qualification |
| Diagram omitted transport and storage's policy/SSH edges | Reflect actual package dependencies and the shared composition boundary |
| TLS prose equated absence of a forwarded socket with inability to verify | Document engine-specific identity handling and retain C6 acceptance |
| Driver guide duplicated obsolete signatures, library choices, registry location and fixture API | Link current traits/source; require both composition roots, capability declarations, wrapper forwarding and real-engine evidence |
| Secret Service failures were described as a missing password | Distinguish `Ok(None)` from typed keyring failure and propagated connect refusal |
| Error guide allowed query bodies at trace level | Apply privacy rules at every level; explicitly retain panic-payload risk |
| Old external brief recommended abort/Tauri extraction/obsolete GLib channel and unmeasured performance | Mark these superseded before the preserved historical text |
| Live entry points directed agents to September audits as current proof | Point to active sprint and this review; retain dated evidence unchanged |
| Adoption matrix linked deleted `core/src/export.rs` | Point to current export module |
| B4 described merged work as isolated/unmerged | Add an October 3 integration checkpoint; retain older worktree evidence under its original scope |

## Evidence audit

All retained JSON and JSONL files parsed. Source-digest fields were compared
with available current files, and candidate-commit blobs where a candidate was
explicitly recorded. A historical mismatch with HEAD is expected after later
changes; it does not falsify the original result. Per-field results are retained
in the manifest. Of 85 recorded source-digest entries, 17 match this working tree, 67 changed and one path is unavailable; all 39 comparisons with explicitly recorded candidate blobs match. These counts are fingerprint checks, not re-executed tests. Logs and probes remain dated diagnostic/native evidence.

- U1's three production/test fingerprints still match the current files. Its
  committed native red/green logs prove the bounded metadata/INSERT case, not
  all consumers, SQL Server versions or current editor integration.
- The September bug-consistency/stabilization records and September 29 audit
  prove their own candidate/working-tree fingerprints. Existing limitation
  fields keep hosted/installed/soak gates separate. They are not a current
  full-branch acceptance report.
- B3's October 1 manifest includes case-level follow-ups. Some report/log paths
  are local cache references, not committed artifacts. Retained summaries and
  hashes remain useful, but a hash cannot recover missing raw output.
- The local-link screen found **20 references to unavailable `target/quality`
  reports** (19 distinct paths) in value-contracts and the validation playbook.
  These were preserved as dated references and explicitly labeled unavailable
  in this checkout. One missing Redis vendor `DEVELOPMENT.md` belongs to the
  vendored upstream documentation; it was recorded without changing the vendor.

For new proof, retain a sanitized report summary and enough raw output to audit
test execution, with source hashes and a hosted artifact/run URL where relevant.
Do not mark an unavailable local path passed again. If raw evidence is required
for a release decision, retrieve its exact-SHA artifact or rerun that gate.

## Remaining source risks

These are future work, with a bounded reproduction and existing owner. This
documentation pass does not implement them or weaken existing safe refusal.

| Risk | Source evidence / owner | Acceptance before closure |
| --- | --- | --- |
| Sensitive data in caught panic payload or default panic hook | `policy/src/guard/panic_boundary.rs::report` logs arbitrary text; ADR 0006's “logs only” is not redaction. Privacy follow-up in policy/app/agentd logging | Sentinel SQL/password/result in a panicking fake driver must be absent from captured tracing and stderr, returned errors and audit fields; preserve useful operation identity, unwind containment and terminal outcomes |
| Panic/disconnection conversion without headless handle retirement | agentd creates `PolicyGuard::new` without a fault sink; GUI installs one. A converted read error alone cannot prove protocol reuse is safe | Coordinate B4 daemon cache/retirement ownership. Next request must reacquire or refuse the damaged handle; prove cleanup and no replay with native loss/panic cases |
| Connection uncertainty currently uses shared audit disabling state | GUI guards clone the same `AuditState`; **B4 F8** already owns the split | Connection A's unknown write blocks A; B follows the approved scope contract; journal-wide failure still blocks all; old generations cannot clear/poison replacements |
| Dedicated session and tunnel replacement identity | F5 is merged; **B4 F4/F9** remain open. Physical identity, saved UUID and session UUID are distinct | Bastion loss/automatic reconnect invalidates old sessions even when ping appears healthy; stale callbacks cannot revive them; installed routes remain explicit |
| Permanent connect errors retry indefinitely and saved mTLS fields are incomplete | **U4/U5**, reinforced by older releases | Preserve typed classification and no insecure fallback; native configured client-cert and failure-class tests |
| Completion identity and whole-collection export gaps | **U3/U6**, plus older-release O1–O3 candidates | Independent schema/case/dotted-name and late-field oracles; no second conflicting cache/export engine |

## Handoff and validation boundary

Read CLAUDE, ADRs, the active sprint, then the owning packet. Confirm branch/SHA
and reserved files before editing. Use one shared core contract across GUI,
agentd and MCP; extend each owning wrapper in the same change. Preserve refusal
until native behavior is proven. Record before/after, source hashes, selectors,
layer results and unrun scopes. Rebase evidence when touched source changes.

This pass verifies manifests, document links, retained JSON structure/digests
and whitespace. It does not rerun Rust/native/GTK suites, CI, packaging,
Wayland, KDC or soak checks. Prior U1 native/local results remain at their
documented fingerprint; they do not certify the later editor merge. Hosted
results must be checked by exact SHA separately.

Hosted snapshot before this documentation commit: at `4b7814f5e`, [Linux Security](https://github.com/cozyGarage/BookiE/actions/runs/37073137737) and [Flatpak packaging](https://github.com/cozyGarage/BookiE/actions/runs/37073137723) succeeded; [Build Linux](https://github.com/cozyGarage/BookiE/actions/runs/37073137726) was still running. The previous U1 commit `6822efa42` had successful Security/Flatpak jobs but its Build run was cancelled by the later push. These results do not establish a passing regression gate for this documentation commit.
