# Proposal: statement effects and a joined verdict

Status: the statement-safety defects are closed by [#480](https://github.com/cozyGarage/BookiE/pull/480), [#506](https://github.com/cozyGarage/BookiE/pull/506) and the current policy suite. The remaining single-AST-walk consolidation is post-0.2.0 backlog work ([#571](https://github.com/cozyGarage/BookiE/issues/571)). This page records that proposal; it is not an accepted ADR.

## Problem

A review on 2026-10-08 found that the policy outcome depended on the order in
which statements were written, not only on what they did:

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

These were historical findings. The behavior defects are closed; duplicated
classification and masking AST walks remain a structural cleanup.

## Remaining proposal

Consolidate classification, masking and blast-radius planning around one AST
walk that produces statement effects. Preserve the current joined verdict,
stable rule names and audit behavior. This is structural cleanup; the behavioral
fixes are already closed.

## Migration

The behavioral steps landed. The remaining step is optional structural cleanup:

1. Add shared statement effects and use them across policy analysis; shared
   statement analysis landed in #506.
2. Join rule verdicts so statement order cannot weaken approval; landed in #480.
3. Consolidate classification, masking and blast-radius analysis into one AST
   walk. This remains backlog work under #571.

## Checks

- Property test: any permutation of a script's statements yields the same
  effects and the same verdict.
- Every existing `Decision` rule name still appears in the audit event.
- The agent and human paths, read-only connections and approval timeouts keep
  their current outcomes (the existing policy tests are the oracle).

## DuckDB read-only (S3)

AUD-10 is complete. Its implementation notes are archived in
[the DuckDB read-only security record](../archive/duckdb-read-only-aud10-2026-10-10.md).
