# Proposal: statement effects and a joined verdict

Status: proposed, for the B4 lane. Not a decision; an ADR follows if accepted.

## Problem

A review on 2026-10-08 found that the policy outcome depends on the order in
which things are written, not only on what a statement does:

- Rules run first-match. With `human_approve_unparseable=false`, a malformed
  `DELETE; ...` is allowed even when write approval is on (S6). Reproduced by B4
  on the `linux` tip.
- Human approval is skipped for some administrative and destructive statements
  (S7). Reproduced in part: `COPY ... TO PROGRAM` and `MERGE ... DELETE` are
  allowed in both Local and Staging; `TRUNCATE` is allowed in Local but needs
  approval in Staging.
- A script's audit class depends on write-statement order: `DELETE; INSERT` is
  classified as `Insert`, while `INSERT; DELETE` is classified as `Delete` (S8).
  An administrative class dominates. Reproduced by B4.
- `classify.rs` and the masking walker traverse the same AST separately and have
  drifted (a write the classifier sees, masking misses).

S6 and S8 are confirmed; S7 is confirmed for the statements named above.

## Proposal

1. **Effects as a set.** A statement's facts become a bit set (`READS`, `WRITES_ROWS`,
   `WRITES_SCHEMA`, `ADMIN`, `TRANSACTION_CONTROL`, `SESSION_STATE`, `HOST_OR_FILE_ACCESS`,
   `UNKNOWN`). A script's effects are the union of its statements', so order cannot
   change them.
2. **Verdict as a join.** Each rule returns `Allow`, `RequireApproval` or `Deny`
   with a reason. The decision is the maximum under `Allow < RequireApproval < Deny`,
   with reasons concatenated. Rule order cannot change the outcome. Each reason
   keeps its stable rule name, so the audit event still says which rule decided.
3. **One traversal.** Classification, masking and blast-radius planning read the
   effects from a single AST walk.

## Migration

One mechanism per PR, each with a test that reorders its inputs and expects the
same result:

1. Add `Effects` beside the current facts; compute both; assert equal in tests.
2. Move scripts to the union and drop first-statement classification (S8).
3. Convert rules to return verdicts and fold them; keep rule names for audit
   (S6, S7). Done on tip via #480 (joined Allow < RequireApproval < Deny).
4. Delete the old facts fields and the duplicated walkers.

## Checks

- Property test: any permutation of a script's statements yields the same
  effects and the same verdict.
- Every existing `Decision` rule name still appears in the audit event.
- The agent and human paths, read-only connections and approval timeouts keep
  their current outcomes (the existing policy tests are the oracle).

## DuckDB read-only (S3)

A read-only DuckDB connection should not read arbitrary local files through
functions such as `read_text`. The driver also supports opening a user-selected
CSV, TSV, Parquet or JSON file as a view in an in-memory DuckDB connection. The
read-only design must preserve that flow while denying access to every other
external path.

For a flat-file connection, resolve the selected local path to a canonical
absolute path, require a regular file, and pin its identity before DuckDB opens
it. A path allowlist alone is not an identity allowlist: after the selected
path is replaced, DuckDB could authorize a different file at the same path. The
Linux driver opens and verifies the selected file, then creates a private
same-filesystem hard link to that inode. DuckDB's `allowed_paths` contains only
this alias; the driver's view reads through the alias, and the session retains
the file and alias directory for its lifetime. Direct reads through the
user-selected pathname, sibling paths, and unrelated paths must fail, including
after the selected pathname is replaced. Do not allow a directory, parent
prefix, URL or other file. If identity pinning or any restriction cannot be
applied, refuse the connection rather than opening it with external access
enabled. DuckDB documents `allowed_paths` alongside `enable_external_access` in
its [file access security
controls](https://duckdb.org/docs/current/operations_manual/securing_duckdb/overview).

For a `.duckdb` or `.db` connection, open the selected database in read-only
access mode (the pinned Rust API exposes this through
[`Config::access_mode`](https://docs.rs/duckdb/1.10505.0/duckdb/struct.Config.html#method.access_mode))
and disable external access before handing the connection to the query path.
The read-only policy remains responsible for rejecting SQL writes. The driver
must confirm that opening the primary database still works with the
external-file restrictions enabled.

The pinned Rust wrapper applies the list-valued setting through trusted
initialization SQL before user SQL, using a tested SQL-literal encoder. Opening
the selected path uses `O_PATH`/`O_NOFOLLOW`, validates file identity, and
reopens through that descriptor with `O_NONBLOCK`; this prevents a replaced
FIFO from hanging setup. The hard-link alias keeps the selected inode stable
for DuckDB and prevents a replacement at the original path from redirecting the
driver view. This is a DuckDB-level path restriction, not an operating-system
sandbox.

Tests now cover selected-file reads, direct reader access through the original
path after replacement, denial of sibling and unrelated files, quotes and
Unicode, symlinks, FIFO refusal without blocking, configuration locking, and
mutations against a read-only database. PR #486 (merged, Forgejo run 143)
closed the remaining selected-file open race; AUD-10 is DONE on the ledger.
