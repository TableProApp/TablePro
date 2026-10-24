# B4 release wrap-up review, 2026-10-11

Reviewed BookiE `fork/linux` at `c320e68565a87ea85da9d09712e9bea3e6aaf52b`.
This is a source and local-test review, not release approval or a new Forgejo
acceptance run. GitHub had no open pull requests when queried.

## Where B4 stands

The old code branches are integrated. Joined verdicts and order-independent
script classification are merged (#480, #460); shared statement analysis is
merged (#506). DuckDB read-only selected-file pinning is merged (#486).
Per-hop SSH storage, transport, bundle v2 and passphrase coverage are merged
(#490, #492, #494, #528). PostgreSQL guarded read snapshots are merged (#524).
MySQL lock-release and session-variable rollback contracts are merged
(#522, #525, #526). There is no reason to merge these old branches again.

The remaining B4 work falls into correctness fixes, candidate acceptance and
later features. The new [0.2.0 scope](../bookie-0.2-sprint.md#delivery-boundary) narrows delivery to an
Arch/Hyprland development release. It does not require completing every old B4
checkbox or every engine configuration before the release.

## Findings that affect the next work

### AUD-9 remains a real correctness blocker

The current masking helper treats only a wildcard over a derived table as a
recursive projection. Named outer projections are checked without resolving
their source. The query

```sql
SELECT d.payload FROM (SELECT json_agg(c) AS payload FROM cards c) d
```

returned the sensitive JSON unchanged through an agent PolicyGuard in a local
stub-driver integration test. The test used the same agent, policy and audit
setup as the existing JSON aggregate guard test. It expected redaction and
failed with the original value containing a synthetic card number.

A helper-level reproduction also classified these projections as nonsensitive:

- `SELECT d.p FROM (SELECT pan AS p FROM cards) d`
- `SELECT c.p FROM cards AS c(p)`
- `SELECT c FROM cards c`
- `SELECT array_agg(c) FROM cards c`

Only the named derived JSON case was reproduced through the complete guard;
these additional helper failures still need native result/decoder proof where
relevant. Fix unknown source lineage conservatively, with allowed simple-column
coverage, rather than extending a serialization-function name list alone.
Keep the explain-plan redaction decision from #461.

### Snapshot refusal skips terminal audit

After a successful PostgreSQL read-only snapshot start, a DELETE is refused
before dispatch by `PolicySession::statement`. That early return occurs before
authorization and outcome recording. A local session test expected one Denied
terminal audit outcome and observed zero. The write was refused; this finding
is an audit gap, not a successful database write.

Review the adjacent early refusal paths as part of the same bounded audit fix:
weak read-only isolation, unsupported engine, hidden transaction controls and
retired sessions. Each needs an explicit audit contract and a test of its
observable outcome. Do not change transaction semantics merely to add logging.

### Full export has a decision conflict

UI-13b is in the backlog and known limitations, but accepted ADR 0014 requires
a snapshot or refusal before publishing a full export. `export_pages.rs` still
uses independent offset requests without that check. #524 is a prerequisite;
it does not make exports consistent.

Recommended release path: refuse an unsupported full export before publishing,
retain current-result export, and defer engine-by-engine snapshot wiring. If the
maintainer instead accepts best-effort full export, amend ADR 0014 explicitly.
A limitation entry by itself does not override an accepted ADR. The shared app
change needs a B4/UX handoff before implementation.

## Documentation reconciliation

The maintainer has deferred Debian/GNOME desktop acceptance and Flatpak in the
scope and backlog. The active sprint still calls Debian required and B7 still
requires both desktop targets. The B4 board still includes Debian I1 even
though B4-10 is DONE. Align these instructions before freezing; preserve their
historical evidence rather than silently treating them as passed.

AUD-11 steps 1 to 3 fix the reported policy behaviour. The remaining single-AST
walk is structural consolidation, not an independently reproduced remaining
S6/S7/S8 bypass. Recommend moving that remainder to the backlog and closing the
behavioural issue after candidate verification. This recommendation does not
close the row or change its accepted scope.

The backlog says transport, SSH and storage mutation runs are unmeasured, but
all three now have reports. The 2.5x grid memory figure predates #518, which
shares immutable values with materialized rows. Treat it as a historical
baseline until comparable profiling measures the current code.

A green merge-tier run may now include one GTK scenario retry (#531). It does
not satisfy the existing retry-free qualification soak. Keep first-attempt
failures visible under TEST-31 and retain the distinct soak exit criterion.

## Remaining local worktrees

All 16 pre-review worktrees were inspected. The 12 named branches were clean;
the three old detached candidates report only an untracked `linux/target`, and
the detached DuckDB review checkout is clean.

| Worktree or branch | Disposition |
|---|---|
| `b4/ui1b-bundle-v2` | #494 merged; storage and app bundle files match current linux; retire |
| `b4/read-snapshot-guard` | #524 merged; its policy files match current linux; retire after preserving this review, not by adding export implementation to the old branch |
| `b4/mysql-release-lock`, `b4/mysql-lock-release-effects` | #522/#525 merged; the corresponding test files match current linux; retire |
| `b4/mysql-user-variable-rollback-effects` | #526 merged; current linux adds the pool-order fix from #534; retain the newer test, retire the old branch |
| `b4/ui1b-hop-passphrase` | #528 merged; transport test files match current linux; retire |
| `b4/mysql-advisory-lock-rollback-20261009` | #435 merged and later tests extend it; preserve the missing old approval-run evidence before retiring |
| `b4/s6-s7-joined-verdict` | #480 merged and #506 supersedes its implementation; preserve its additional release manifest before retiring |
| `docs/b4-postgres-release-current-tip` | #500 merged; evidence files identical on linux; retire |
| `docs/b4-hosted-linux-tip-20261009`, `docs/b4-release-evidence-100fb6fa`, `docs/b4-current-tip-20261010` | Unique historical evidence is absent from linux; reconcile/archive it first, then retire |
| Detached `candidate-0529`, `candidate-49a7`, `candidate-a7f14` | HEADs are ancestors of linux; inspect target symlink/cache ownership before removal |
| Detached `review-pr-463` | Old DuckDB review superseded by #463/#486; retire after checking no unique evidence |

Three documentation branches contain evidence rather than unfinished product
code. The packaged-binary manifest explicitly says extracted, not installed;
it cannot close package acceptance. Import historical manifests with their
original SHA and limitations. Do not bring back their old ledger edits.

## Finite finish order

1. Reconcile the release instructions and preserve unique old evidence; retire
   completed worktrees. Keep one B4 checkout and reuse the existing build cache.
2. Fix the demonstrated AUD-9 named-source leak, then the snapshot refusal audit
   gap in separate small PRs. Start with the saved failing tests, broaden only
   to related source-lineage and terminal-outcome cases, and run preflight.
3. Resolve the export/ADR conflict with the maintainer and UX. Prefer a bounded
   refusal fix over completing all snapshot engines for this release.
4. Triage only mutation survivors relevant to masking, trust refusal, secret
   selection, bundle rollback and durable audit. Survivors are test gaps or
   equivalent mutations until investigated; raw percentages are not a release
   verdict. Add confirmed defects to existing rows or request a scope decision.
5. Freeze the resulting SHA. UX/maintainer runs its Forgejo gate, then the Arch
   installed/native Wayland approval, SSH refusal/audit, session retirement,
   bundle audit and package upgrade/rollback checks. TEST-15 gets an explicit
   reviewed list of enabled write/retry/session paths, not an unlimited request
   to test every possible transport failure.
6. Record scoped acceptance for AUD-2, AUD-9, B4-7, B4-16, B4-22 and TEST-15.
   Release only after the maintainer decides TEST-31/32, manual acceptance and
   qualification. Keep UI-1b editor, progressive results, broad snapshot support,
   optional MySQL engines and Windows AD in the backlog, with their limitations.

## Validation boundary

Unmodified source passed 219 policy unit tests, 6 AUD-11 integration tests and
4 guard-transparency tests. The three added review reproductions failed as
recorded above. Their patch and logs are saved in
[archived review evidence](evidence/b4-release-review-2026-10-11/manifest.json);
the [preservation note](evidence/b4-release-review-2026-10-11/preserved-worktree-evidence.md)
maps the retained records to the retired worktrees. The failing test edits were
removed from product test files after reproduction.
No full preflight, Docker driver, Forgejo, installed GTK or native Wayland run
was performed by this review. Existing green tests do not establish the missing
behaviour demonstrated by the failing reproductions.
