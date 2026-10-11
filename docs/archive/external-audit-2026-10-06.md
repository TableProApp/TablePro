# External audit: BookiE after 0.2.0

Archived 2026-10-10 from the repository root into `linux/docs/archive/`
(dated review; not current task instructions). Reviewed 2026-10-06. This is a
deferred improvement plan for BookiE's Linux application and Rust backend.
Start implementation after finishing 0.2.0. The
[active sprint](../bookie-0.2-sprint.md) retains current delivery and
acceptance authority. [PLAN](../../PLAN.md) and
[ROADMAP](../../ROADMAP.md) link here for later review. No workspace move,
workflow rollout or driver addition was implemented in this audit.

The objective is a clear root workspace, independently testable Rust services,
synchronized documentation/evidence and deliberate library reuse. Preserve
the native GTK interface and Linux focus. dbx's marketing and size/speed claims
are outside scope.

## Review evidence and navigation

| Reference | Inspected snapshot and scope | Limits |
| --- | --- | --- |
| BookiE `linux` | Checkout advanced from `300e50502092a2184cef9eec7fd93b0a7e9de7a9` to `70022ac3710c50a8d3b8071fa0f8a9bb3c25b098` during review. Current manifests, contributor rules, ADRs, packaging/resources, test registries, issue forms and relevant workflows | Source review; no Rust/application/package/hosted checks rerun |
| [dbx][dbx] | `1ed598308a4c6264c7c6460ae812be8ddde69268`: architecture guards, CI planner/gates/features, templates, issue automation, examples, database lab, benchmarks, selected fixes and JDBC/native-agent foundations | Targeted review, not exhaustive semantic/security/license certification |
| [DBeaver Community][dbeaver] | `27b962eb15cfa272585defdb4e585d28beee57da`: root license and PostgreSQL driver catalog; official driver documentation | JDBC reuse reference, not every extension or vendor JAR |
| TableProApp/TablePro | Root license metadata and BookiE's existing Linux adoption records | No fresh upstream macOS source review or main-branch adoption plan |

Use sections 1–2 for layout/context, 3 for backend contracts, 4–5 for
GitHub/tests, 6 for driver reuse, and 7–8 for performance/implementation.
Sources nominate designs or reproductions; they are not proof of a BookiE bug,
runtime pass or permission to redistribute unreviewed dependencies. Refresh
chosen dependencies and source versions when implementation begins.

### Follow-up: other clients and current BookiE code

[The client lessons and Linux source review](external-audit-client-review-2026-10-06.md)
adds DBeaver, pgAdmin, Beekeeper Studio and DB Browser for SQLite examples,
an explicit BookiE-core versus dbx-core comparison, and bounded current-code
verification. Its priority findings are relational stale-write protection,
evidence-selector/source validation and shared result-memory budgets. A
2026-10-06 implementation follow-up records those changes and local checks;
cross-engine runtime, hosted CI, installed GTK and packaging gates remain
separate. Use that review for detailed evidence and residual gaps; the sections
below remain the deferred post-0.2.0 restructuring plan.

## 1. Root workspace, preserving existing ownership

The `linux` branch already contains the Linux product. Move the workspace
out of the extra `linux/` directory after 0.2.0. A flatter repository means
clear top-level responsibilities, not flattening Rust modules or copying dbx's
crate names.

Proposed layout:

```text
Cargo.toml / Cargo.lock / rust-toolchain.toml
README.md / CONTRIBUTING.md / CHANGELOG.md / PLAN.md / ROADMAP.md
CLAUDE.md / LICENSE / docs/archive/external-audit-2026-10-06.md
.github/                 forms, PR template, workflows, GitHub-specific helpers
crates/                  existing app/core/policy/storage/ssh/transport/mcp/
                         agentd/drivers and test-support packages
docs/                    architecture, ADRs, guides, plans, history and evidence
examples/                public runnable workflows and sample configurations
deploy/database/         manual disposable database lab and versioned recipes
tests/fixtures/          canonical automated integration topologies and inputs
testdata/                shared pure test inputs
assets/                  GTK resources, schemas, desktop metadata and icons
po/                      translations
packaging/               Arch, Debian and Flatpak distribution inputs
scripts/                 shared guards, layer runners, package helpers, benchmarks
vendor/                  maintained dependency patches with provenance
target/                  ignored generated builds, reports and local artifacts
```

| Existing material | Destination | Preserve/reconcile |
| --- | --- | --- |
| `linux/Cargo.toml`, lockfile, Cargo config, lint/deny configs and guard baselines | Root | Reconcile duplicate toolchain/config files; one canonical owner |
| `linux/crates/` | `crates/` | Keep package names, responsibilities and most crate-relative dependencies |
| `linux/docs/`, `ARCHITECTURE.md` | `docs/`, `docs/architecture.md` | Retarget links; preserve dated evidence and decisions |
| Linux README/contributor/roadmap/changelog | Root counterparts | Merge useful guidance; avoid competing entry points |
| Scripts/vendor/po/testdata | Corresponding root directories | Preserve runner behavior, fixture semantics and attribution |
| `linux/data/` and Flatpak desktop/metainfo/icons | `assets/` by resource kind | Build/package from one canonical asset set |
| Packaging and Flatpak manifest | `packaging/`, `packaging/flatpak/` | Rewrite Meson/source paths together; retain installed identifiers/layout |
| `linux/tests/fixtures/` | `tests/fixtures/` | Keep automated Compose files with certificates, init data and owning runners |
| `linux/tests/manual-connections/` | `deploy/database/` | Reuse as manual lab; do not duplicate automated TLS/release fixtures |
| Crate-specific tests/Cargo examples | Adjacent to their owning crate unless public workflow needs relocation | Root examples index can link the existing browse benchmark; a moved Rust example needs an explicit Cargo target |
| Local targets/mutation output/cache | Local generated material during transition | Classify and preserve useful proof first; no blanket deletion or addition |

Do not create empty directories merely to resemble dbx. Start public examples
with an index and a few tested MCP/configuration/driver-use workflows. Shared
fixtures have one canonical path even when deploy and tests both consume them.

### Migration packet and acceptance

1. Inventory the completed 0.2.0 checkout: tracked paths, dependency edges,
   resources, includes, translation inputs, scripts, CI filters, license files
   and generated output. Pin a clean migration baseline.
2. Add section 3's ownership checks against the old layout first. Preserve
   justified test-only dependency exceptions.
3. Move the workspace in a coherent path-only change. Update vendor patches,
   build scripts, Meson/Flatpak, package helpers, layer registries, CI paths,
   cache/artifact paths and live documentation together. Do not claim a
   partially moved tree works.
4. Reconcile root guidance and assets. Keep Rust package names, app/XDG/keyring
   identity, binary aliases, audit/protocol formats and persisted UUIDs stable.
5. Search tracked first-party inputs for old live-path assumptions. Separate
   intended historical paths from stale executable references. Record old/new
   path mappings in evidence; moving a file does not create fresh test proof.
6. Validate a fresh checkout, including locked metadata, supported feature
   profiles, resources/translations, runner/inventory/workflow tests, affected
   headless/GTK/driver/TLS suites, package contents and installed desktop flows.
   Record candidate/package/binary SHAs and unrun gates.

Preserve branch-protection check names or coordinate changes explicitly.
Verify Arch, Debian and Flatpak paths/aliases/resources; installed launch,
Secret Service and qualified Wayland desktop flows remain separate acceptance.
A warm build alone is insufficient. Revert migration commits if needed; do not
reset unrelated work or erase history. No upstream macOS tree merge is needed.
Future Rust/Linux ports become path-aware manual adoption.

## 2. Docs, examples, evidence and bounded agent context

Recommended source model: canonical docs, examples and sanitized evidence stay
with the code on the source branch, updated in the same focused PR when behavior
changes. dbx itself keeps [docs/examples in its source tree][dbx-contributing].
Use short-lived `docs/*` and `examples/*` branches merged into `linux`.
A separate publication branch can hold rendered output.

Permanent docs-only/examples-only source branches add a second version
relationship to every change. A checkout would lose part of its own contracts
and proof, while branch separation alone does not bound what an agent reads.
Directory ownership, compact indexes and explicit work packets better address
the context problem.

| Material | Owner | Synchronization/context contract |
| --- | --- | --- |
| Current decisions/plans | Existing ADRs and active task owners | Read index, relevant ADR and one packet |
| Guides/public examples | `docs/`, `examples/` in code PR | Link owning contract and compile/smoke samples at the PR SHA |
| Sanitized summaries/manifests | `docs/evidence/<case>/` | Source SHA/digests, selector, fixture, profile/features, result |
| Large sanitized logs/screenshots | Exact-SHA CI artifacts or versioned archive | Small committed index, checksums, retrieval links and retention policy |
| Generated local reports | `target/quality/` | Local paths/hashes alone cannot recover proof in another checkout |
| Published docs | Optional publication branch/hosting output | Source SHA, versioned release docs and pinned build inputs; not another architecture authority |

If separate canonical source branches remain the preferred choice, evaluate
them explicitly: require a manifest tying code SHA, docs SHA and examples SHA;
a release synchronization gate; examples tested against that code SHA; immutable
release bundles and a dedicated worktree. Compare maintenance overhead before
adopting it. No new branch is created by this plan.

Reuse the [existing agent handoff template][local-validation]. Each packet names
one invariant, baseline, allowed files, owner/ADR, selected layers, reserved
Cargo/fixture resources, evidence destination and remaining acceptance. Add
directory-local guidance only where responsibilities differ. Link history and
large logs instead of automatically loading them. Keep the existing B3/B4
owners; this audit is not another progress ledger.

## 3. Executable ownership for a strong Rust backend

Preserve the current graph: core owns contracts; policy owns guarded execution;
storage/SSH/transport own persistence, tunnels and connection assembly; drivers
implement core; app/agentd compose concrete services; MCP consumes shared
contracts. Domain and driver code remains headless.

dbx's `core` instead owns application orchestration. Learn from its
[explicit boundaries][dbx-architecture], not its naming. Keep Relm4, static
registration, panic unwinding and ADR 0007's exact support/fallback/refusal.
Extract another service crate only for concrete duplicated or app-owned logic
with actual headless consumers and a tested seam. A Web server or new CLI is
not a prerequisite for a strong backend.

Adapt [dbx's architecture guard][dbx-guard] into the existing Python tooling.
Use Cargo metadata for dependencies/targets and an explicit map for resource
inputs Cargo cannot infer. Avoid adding Node solely for repository scripts.

| Contract | Proposed check | Required proof/reuse |
| --- | --- | --- |
| Dependency boundaries | Allowed production/build/dev workspace edges, acyclic graph, no GTK in headless owners or reverse dependencies | Inventory actual edges; preserve legal SQLite/policy test-only exceptions; synthetic forbidden edge fails |
| Feature forwarding | App/agentd DuckDB and Kerberos propagation; supported profiles compiled separately | Default/no-default/DuckDB/Kerberos as supported; consumer checks expose hidden workspace feature unification |
| Shared consumers | Registry parity and behavior through GUI service, daemon cache/view, MCP and policy/session/transport wrappers | Same native value/refusal, timeout, retirement and audit contracts; extend every affected wrapper/caller with an API change |
| Resource ownership | Schema/GResource, gettext, desktop/metainfo/icons, askpass, fixture material and vendor patch owners | Input changes select checks; inspect built package and installed behavior, not only source presence |
| Test ownership | Existing layer, isolated, ignored and change-test registries extended together | New member/target cannot vanish from selection; missing/zero/duplicate execution fails |
| Docs/example ownership | Links, source/version metadata, sample configs and public Cargo targets | Contract change nominates guides/examples; run with isolated fixtures and no real secrets |

A headless conformance harness can use existing Connection/Session traits and
recording fakes. Share true common assertions while keeping per-engine native
oracles. Do not force all engines into a weaker value model or advertise
cancellation/metadata they cannot implement.

Reuse `test-layers.json`, `isolated-tests.json`, `change-test-map.json`,
`check-ci-jobs.py`, runner regressions, file/function guards, existing fixtures,
ADRs and evidence indexes. Strengthen these owners instead of duplicating them.

## 4. Selective adoption from .github

Existing BookiE forms already capture distribution, display protocol, install
method and policy context. Extend them. Keep pinned Actions and current workflow
contract tests. Workflow count is not an improvement metric.

| dbx source | Apply to BookiE | Acceptance |
| --- | --- | --- |
| [PR template][dbx-pr] | Problem/result, issue, exact validation, unrun gates/evidence, UI screenshots where relevant | Retain focused commits and regression rules; checklist cannot imply unexecuted proof |
| [Compatibility form][dbx-compat] | Engine/distribution/version, consumer, direct/SSH, TLS/auth mode, native expectation and minimal reproduction | Connect to sanitized support information; extend rather than weaken current forms |
| [Issue/PR labeling][dbx-labels] | Deterministic area/database/platform/regression labels | Narrow writes, trusted code, stale-event/label-preservation tests |
| [CI planner][dbx-ci-guide] | Cargo reverse dependencies including test/build edges, renamed/deleted paths and resource owners | Missing diff, unknown member, config/vendor/lock/toolchain/planner changes select broad coverage |
| [Feature audit][dbx-ci-guide] | Compare selected package features with intended full profile | Preserve legal combinations; no automatic assumption that all-features is valid |
| [Aggregate gate][dbx-gate] | Extend existing strict gate if conditional lanes are added | Required jobs succeed; only explicitly unselected jobs skip; invalid/missing plan, failure/cancellation fail |
| [Docs workflow][dbx-docs-workflow] | Separate docs/examples validation from optional publishing | PRs use no deployment secrets; trusted publication records exact source; hosting choice deferred |
| [Database lab][dbx-lab] | Version/configuration recipes built around current manual/automated fixtures | Pinned image/digest, readiness, unique data, isolated ports, cleanup and explicit reset |
| [Grouped tests/timing][dbx-ci] | Suite timing, slow-lane isolation and bounded nextest pilot | Exact-test evidence and no hidden retries; shared local Cargo targets/fixtures serialized |

Evaluate change selection against full runs before reducing authoritative
coverage. A recipe/configuration check is not a native database pass. Preserve
full-profile and installed acceptance at release.

dbx's privileged PR-label workflow checks out trusted base code and inspects
a fetched head. Do not mechanically copy `pull_request_target`, checkout
opt-outs or deployment secrets. Fork validation must never execute contributor
code with write tokens/secrets. Prefer ordinary read-only PR validation and
add privileged automation only when needed with failure-path tests.

Defer AI priority scoring, duplicate-issue bots, claim/close automation and
sponsor/provider integrations until actual intake volume justifies them.
Labels do not diagnose defects or close release acceptance. Template adoption
must not incidentally send public report text to an external model service.

## 5. Tests, fixes and edge-case discovery

Keep one executable test catalog and exact execution evidence. Pilot nextest
on one bounded lane before adopting it: preserve selector counts, ignored cases,
timeouts, isolation and report parsing. Run doctests separately. Faster execution
that omits a suite is a regression.

Fix workflow: minimal failing reproduction, owning-contract patch, affected
consumer proof, independent native/destination oracle, focused fix/test commit
and explicit remaining scope. Path/convention cleanup is a separate change.

[dbx contribution guidance][dbx-contributing] prefers production functions or
mounted components over source-spelling assertions. Manifest/artifact checks
are valid structural contracts; policy, rollback, session ownership and UI
behavior need executed proof. Keep useful guards until equivalent coverage exists.

| External candidate | BookiE owner and required assertion |
| --- | --- |
| [Count/page disagreement and stale callbacks][dbx-pagination] | Browse/session: honest completeness, no old callback updating refreshed/reconnected tabs; check existing behavior first |
| [PostgreSQL identity/sequence export][dbx-export-fix] | Existing export/SQL owners if supported, otherwise deferred capability; restore native IDs then test default INSERT, renamed/descending/unused/cycling sequences |
| [Dialect backslash rules][dbx-lexer-fix] | Shared lexer/policy/editor/import contract across execution entry points and malformed/escaped inputs |
| Metadata fan-out/deduplication | Existing metadata services: per-connection limit, bounded queue, cancellation/generation invalidation, independent connection fairness |
| Import byte/packet boundaries | Import/drivers: exact data, bounded buffering, pre/post-dispatch cancellation and native committed/unchanged state |
| Poisoned engine/process handle | Existing B4 retirement or future bridge owner: reacquire/refuse, no handle reuse or write replay |
| Lossy driver text decoding | Existing B3: preservation/fallback/refusal; replacement characters never count as exact source data |

These are applicability candidates, not confirmed BookiE defects. Classify
covered, inapplicable with reason, reproduction needed, or reproduced gap.
Use risk-based engine/version/type/consumer/configuration coverage and pairwise
ordinary combinations. Explicitly test high-risk intersections, such as SSH +
strict TLS + reconnect + an open transaction. One version pass is not universal.

Add sanitized "Copy support information": version/commit, architecture, distro,
package origin, desktop/display backend, GTK stack and selected driver/runtime
versions. Exclude credentials, URIs, SQL, result values and private path names by
default. Test exclusions and connect the output to existing issue forms.

## 6. Driver and library reuse

Yes: reuse maintained libraries before implementing wire protocols again.
BookiE already builds on SQLx, Tiberius, MongoDB, Redis, ClickHouse, DuckDB,
russh and gtk-rs. Distinguish a protocol library, an application's adapter
and an application's plugin framework.

| Reuse source | Suitable unit | Treatment |
| --- | --- | --- |
| Native Rust dependencies | Protocol, TLS/auth, native values, maintained fixes | First choice; upgrade/upstream focused patches with regression proof |
| Applicable TableProApp Linux/shared Rust | Bounded driver/SQL/transport behavior and tests | Extend [current adoption records][local-upstream], manually retarget after relocation; no Swift/macOS plugin ABI import |
| dbx Rust adapters/vendor patches | Engine handling, metadata queries and reproductions | Port behavior into BookiE contracts or use the underlying maintained library; inspect dependency/value differences |
| dbx standalone agents | Process/protocol and shared JDBC lifecycle design | Later bridge reference, not a drop-in BookiE trait implementation |
| DBeaver Community | JDBC artifact catalog, metadata/dialect behavior and scenarios | Prefer underlying official JDBC artifacts, not the Java/Eclipse application framework |
| Official JDBC drivers | An unmet engine with mature Java support | Optional constrained bridge after ADR and proof; keep working Rust drivers |
| C/ODBC libraries | Another supported native interface | Separate evaluation for FFI, cancellation, values, licensing and Linux packaging |

[DBeaver's PostgreSQL catalog][dbeaver-pg] specifies `org.postgresql.Driver`
and Maven `org.postgresql:postgresql`, plus optional related artifacts.
The application plugin adds metadata/UI/configuration behavior.
[pgJDBC][pgjdbc] is the independently reusable driver; the catalog's selected
version is not a BookiE dependency recommendation.

[dbx agents][dbx-agents] run separate native/JVM processes over stdio JSON-RPC,
with shared JDBC execution/metadata/pooling and pinned stateful sessions.
The [authoring guide][dbx-agent-guide] distinguishes bundled and user-supplied
drivers. Inspected builds include H2, Jaybird and vendor JARs. Presence in an
open-source application or Maven repository is not redistribution clearance.

### Provenance and dependency review

BookiE's [LICENSE](../../LICENSE) and dependency policy remain authoritative.
dbx's inspected root [LICENSE][dbx-license] is Apache-2.0, but its agents README
still says AGPL-3.0. Resolve provenance for copied agent files before adoption.
DBeaver Community's [license][dbeaver-license] is Apache-2.0 with additional
component notices. TableProApp root license metadata reports AGPL-3.0.
Root licenses/badges do not determine every vendor JAR, patch, binary or asset.

For an adopted unit record repository/immutable revision, selected files,
artifact coordinates/version/checksum, applicable license/notices,
modifications, dependency closure, upstream tracking/removal condition, tests
and Linux targets. Preserve required attribution. Cargo advisory/license checks
do not cover JARs, native clients or JVM runtimes; inventory those separately.
Prefer maintained upstream dependencies to unexplained application forks.

### Optional JDBC bridge, after an ADR decision

[ADR 0001][local-static] currently uses static Rust drivers with no external
driver discovery. A process/JDBC backend changes that decision. First write an
explicit amendment defining the narrow exception, engines, runtime ownership
and Linux packaging. Keep existing native drivers intact.

Candidate flow:

```text
GTK / agentd / MCP
    -> existing Rust services and PolicyGuard
    -> compile-time registered Rust JDBC adapter
    -> owned versioned stdio protocol
    -> optional JVM bridge + approved JDBC artifact
    -> database
```

Rust retains policy/audit, secrets, transport identity and supervision.
The bridge owns JDBC calls and pinned physical sessions. No sidecar endpoint
may bypass the guard. A subprocess is not automatically an OS sandbox.
Start with approved engine/class/artifact profiles, not arbitrary JAR loading.

Required contracts:

- Version/capability handshake; bounded frames/queues/result bytes/concurrency;
  request, session and connection-generation identity.
- Explicit typed encoding for wide integers, decimal scale, binary, NULL/empty,
  temporal zones/precision and native/nested values. JSON-RPC alone is not
  lossless; ADR 0007 applies across the bridge.
- Parameter binding and known engine dialect. Conservative refusal for
  unsupported policy syntax; no bridge-local SQL-prefix safety classifier.
- Pinned transactions/cursors, no cross-session state leakage, and no reconnect
  silently replacing a transaction.
- Real cancellation where supported, awaited close, timeout retirement,
  child reap/kill and stale-response rejection. Killing a process does not prove
  a dispatched write rolled back; retain unknown outcomes and no replay.
- Secret transfer over private protocol handles, never argv/environment/logs;
  sanitized errors/stderr; strict TLS service identity through SSH.
- Explicit JRE/artifact installation, version/checksum/provenance, offline and
  update/rollback behavior; no surprise launch-time download.

A disposable H2 proof of concept is a bounded infrastructure experiment,
not a shipping commitment or proof of Oracle/DB2 compatibility. Test lossless
results/binding, metadata, sessions, cancellation, denied writes, crash retirement
and offline packaging. Then select one real unmet engine and qualify its native
behavior and independent driver terms. Mark unproven capabilities experimental
or refuse them explicitly. A Rust-owned backend can use a Java bridge without
moving its domain/policy/services into Java.

## 7. Performance and operational proof

Reuse the method in [dbx's benchmark guide][dbx-bench] and BookiE's
[PostgreSQL measurements][local-performance], ignoring external speed claims.
Measure release binaries at exact hashes on the same machine/fixtures.

Track cold/warm startup to interactive editor, idle/connected memory, large-schema
expansion/search, wide-grid first paint/scroll, large text/binary results,
import/export throughput, cancellation settlement and memory after closing
tabs/disconnecting. Measure GTK/Wayland and headless consumers separately.
A row cap is not a total byte budget.

Profile before per-connection metadata deduplication/concurrency changes,
bounded result/import buffers, avoiding duplicate matrices, deferred catalog
loading or native bulk paths. Preserve exact values, transaction outcomes and
destination safety. Report memory/latency tradeoffs and correctness assertions.

## 8. Ordered implementation packets

Every packet is pending. After 0.2.0, reconcile against the actual source before
choosing work; some improvements may already exist. No new release target or
completed milestone is declared here.

| Order | Deliverable | Acceptance |
| --- | --- | --- |
| E0 baseline | Completed-release inventory and adoption/ownership map | Clean pinned source, current decisions and coverage classified |
| E1 guards | Dependency, feature, registry and resource checks on current layout | Synthetic violations fail; test exceptions explicit |
| E2 root move | Section 1 mapping and canonical guidance | Fresh-checkout automated/package/installed proof, stable identities/contracts |
| E3 docs/context | Compact indexes, samples, evidence policy and scoped agent guidance | Links/samples validate; code/docs/evidence remain synchronized |
| E4 intake | PR/compatibility forms and sanitized support info; labels if useful | Schema/behavior tests, safe automation and actionable reports |
| E5 test/CI | Existing Python mapping/gate extended, feature audit, timing and optional nextest pilot | Compare broad runs, cover new/renamed/missing inputs, retain exact execution |
| E6 reproductions | Section 5 candidates reconciled with current owning boards | Failing-before/passing-after native/consumer proof or explicit applicability disposition |
| E7 measurement | Release/Wayland/headless benchmarks and measured fixes | Raw sanitized samples, hashes/profile/environment and correctness |
| E8 reuse decision | Native/JDBC/ODBC comparison, dependency/provenance inventory and ADR | Concrete unmet need; no generic driver-marketplace commitment |
| E9 optional bridge | One constrained adapter/runtime and H2 lifecycle/protocol proof | Section 6 contracts, package/offline acceptance |
| E10 engine if needed | Native or approved bridge-backed engine | Real version/configuration proof through required consumers and Linux packages |

Each packet returns baseline, changed files, initial behavior, selected/executed
tests, source fingerprints, reports/artifact links, unrun scope and resulting SHA.
Use the owning evidence index rather than copying status into every plan.
Hosted CI, builds, installed desktop acceptance and native live tests remain
separate facts.

Do not copy huge monoliths, duplicate SQL/value policy or test registries, silent
self-skips, feature-unification assumptions, abort-on-panic in the guarded app,
unreviewed JARs or arbitrary downloads. dbx's UI/Web product, marketplace,
Windows/macOS workflows and sponsor integrations are outside this Linux plan.

[dbx]: https://github.com/t8y2/dbx/tree/1ed598308a4c6264c7c6460ae812be8ddde69268
[dbx-architecture]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/crates/ARCHITECTURE.md
[dbx-guard]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/scripts/core-architecture.test.mjs
[dbx-contributing]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/CONTRIBUTING.md
[dbx-pr]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/.github/pull_request_template.md
[dbx-compat]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/.github/ISSUE_TEMPLATE/database_compatibility.yml
[dbx-labels]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/.github/workflows/pull-request-labels.yml
[dbx-ci-guide]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/.github/scripts/ci-guide.md
[dbx-gate]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/.github/scripts/ci-gate.mjs
[dbx-docs-workflow]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/.github/workflows/docs.yml
[dbx-lab]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/deploy/database/README.md
[dbx-ci]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/.github/workflows/ci.yml
[dbx-pagination]: https://github.com/t8y2/dbx/commit/f8b7ffe516e74af624ce8f84550c2a3479be852d
[dbx-export-fix]: https://github.com/t8y2/dbx/pull/11095
[dbx-lexer-fix]: https://github.com/t8y2/dbx/commit/5067514e8d81eb969167d80a7157ff2ac432e75a
[dbx-agents]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/agents/README.md
[dbx-agent-guide]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/agents/docs/agent-authoring.md
[dbx-license]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/LICENSE
[dbx-bench]: https://github.com/t8y2/dbx/blob/1ed598308a4c6264c7c6460ae812be8ddde69268/scripts/bench/README.md
[dbeaver]: https://github.com/dbeaver/dbeaver/tree/27b962eb15cfa272585defdb4e585d28beee57da
[dbeaver-pg]: https://github.com/dbeaver/dbeaver/blob/27b962eb15cfa272585defdb4e585d28beee57da/plugins/org.jkiss.dbeaver.ext.postgresql/plugin.xml
[dbeaver-license]: https://github.com/dbeaver/dbeaver/blob/27b962eb15cfa272585defdb4e585d28beee57da/LICENSE.md
[pgjdbc]: https://jdbc.postgresql.org/documentation/use/
[local-validation]: linux/docs/validation-playbook.md#agent-task-template
[local-upstream]: linux/docs/upstream-sync.md
[local-static]: linux/docs/decisions/0001-no-plugin-system.md
[local-performance]: linux/docs/performance-2026-09.md
