# Capability evidence

Historical capability audit: 2026-09-07. Current scope and acceptance are in the [active sprint](bookie-0.2-sprint.md); the [consistency review](archive/architecture-consistency-review-2026-10-03.md) records evidence availability.

This historical audit evaluates ten capabilities previously listed as "Already
useful on Linux" in `PLAN.md`. Its evidence and verdicts apply to the September
7, 2026 audit snapshot, not current coverage. Status terms follow
[ROADMAP.md](../ROADMAP.md); current work belongs to the active sprint and boards.

The September [bug and consistency audit](archive/bug-consistency-2026-09.md) is also historical; historical numeric counts below describe the earlier audit, not current totals.

Evidence tiers are the regression tiers in [testing.md](testing.md):
`unit`, `sandbox`, `driver`, `release`, `gtk`.

| Capability | Strongest evidence | Verdict |
|---|---|---|
| Saved connections and secret storage | Connection-file compatibility tests plus a real Secret Service round-trip in the required GTK job | **Integrated** — exact-candidate hosted and installed-package evidence remain RC gates |
| Multi-tab workspace and restoration | Unit tests on workspace state, including structure-tab restore mapping, last-connection restore selection, plus an installed GTK scenario that switches away and back after the persist debounce | **Weak** — a switch no longer wipes the previous connection's tabs, structure tabs are persisted, and startup reopens the last connection when that saved id still exists. No installed test starts the app, opens tabs, restarts the process, and checks they return |
| SQL editor and multi-result execution | 19 unit tests on the SQL text scanner, 15 on completion, 1 gtk scenario for parameters | **Partial** — editing and completion are well covered; nothing proves one batch produces several result tabs |
| Browse/edit/filter/sort/pagination | 34 unit tests on filters, 6 release tests covering all 17 operators, keyset vs offset paging, and an injection payload | **Release-verified** for filter, sort, and pagination. The inline-edit write path has unit tests only |
| Table/column/index/foreign-key editing | 76 unit tests on DDL generation, 5 release tests against PostgreSQL | **Release-verified**. This suite found two real bugs when it was written |
| Query history | 2 tests against ~600 lines of code | **Weak** — the least-tested subsystem in the workspace relative to its size |
| CSV and JSON export | Core CSV escaping, agent release coverage, and an installed GTK current-page CSV scenario | **Partial** — the GUI intentionally exports only the loaded page; snapshot/full-table streaming is deferred and JSON UI automation is absent |
| Activity and EXPLAIN | 2 unit tests plus 2 release tests for activity, 7 unit tests plus release coverage for EXPLAIN classification | **Integrated** |
| Read-only schema review | Unit tests for the empty default and a governed `list_views` read, plus a PostgreSQL integration assertion | **Partial** — PostgreSQL views list through the guard; the daemon wrapper now preserves that metadata and controlled dispatch. Other object kinds are not started |
| SSH, TLS, reconnect and Kerberos foundations | 8 release tests for TLS identity, 2 for reconnect, 3 for the shared transport | **Partial** — proven on PostgreSQL only. Kerberos has no test of any kind; there is no KDC in any fixture |
| MCP and headless agent foundations | 9 + 2 sandbox tests, 6 release tests, 1 transport regression test | **Integrated** |

## What this changes

Three claims need work before the list is accurate:

1. **Query history** carries the most code per test of anything in the
   workspace. It stores user SQL, so it is also privacy-relevant.
2. **Workspace restoration** after a process restart is still untested in the
   installed suite. Startup now reopens the last connection when that saved id
   still exists. A connection switch no longer wipes the previous connection's
   tabs; that race has an installed GTK scenario.
3. **JSON export** still needs installed GTK automation. Current-page CSV is
   covered with a 150-row fixture that asserts only the first 100 PK-ordered
   rows are written; full-table snapshot streaming is a separate future capability.

Two claims are overstated rather than untested:

- **Kerberos** appears in a list of "foundations" with zero tests. Either build a
  KDC fixture or say plainly that Kerberos is configuration-only.
- **Secret storage** has a real Secret Service job configured, but the exact RC
  workflow result and clean-package session remain required evidence.

Connection-layer evidence is tracked separately and in more detail in
[connections.md](connections.md).
