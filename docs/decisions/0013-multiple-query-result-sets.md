# 0013: Preserve every result set from a query

- **Status**: Accepted
- **Date**: 2026-10-07

## Context

The core `QueryResult` describes one tabular result. At the time this decision
was written, SQL Server could return several result sets for one batch, but its
driver retained only the first while draining the rest. The later data was
unavailable to the editor, policy masking, MCP and export consumers (TEST-10).

## Decision

Keep `QueryResult` as the representation of one result set and add an ordered
`QueryResultBatch` containing every tabular set, including empty sets, plus one
batch-level truncation flag. Add a controlled query method with a default
implementation that wraps the existing single-result method. SQL Server
overrides it and collects every set from the TDS stream under the existing
shared row, cell and byte budgets. Existing single-result methods keep
returning the first set and drain later sets without retaining them.

The guard authorizes and audits the submitted SQL once, applies masking to
every set, and records the total retained row count. The editor exposes sets
as ordered result tabs within the statement. MCP keeps its existing first-set
`columns` and `rows` fields and adds `additional_result_sets`; JSON export
returns every set, while CSV export refuses a multi-set result rather than
silently dropping data.

Drivers must drain the full response and surface late server errors. A query
that fails after producing an earlier set returns an error with no partial
batch. Cancellation and timeout keep the existing server-side cancellation
contract. Reaching a batch budget marks the batch truncated but still drains
the response so the connection is reusable and late errors remain visible.

## Consequences

PR #228 implements this decision. The SQL Server batch API collects ordered
sets under one shared budget; the guard, editor, MCP and JSON export retain the
sets, while CSV refuses multi-set output. Docker tests cover ordering, an empty
first set, late errors, truncation and connection reuse. Current acceptance
status is recorded in TEST-10 in the [known-issues ledger](../known-issues.md).

- Existing browse, paging and single-result consumers keep using `QueryResult`.
- Existing query callers retain their first-set behavior; callers that need all
  sets opt into the batch API.
- Drivers without multiple-result support inherit a one-set default and need no
  artificial result-set logic.
- The editor and MCP can no longer discard later SQL Server results. Their
  per-set values remain subject to the same total memory and MCP row caps.
- CSV export of multiple sets becomes an explicit error; JSON export preserves
  set boundaries and column names.

## Alternatives considered

- Keep the first set and drain the rest: this is the current data-loss behavior.
- Flatten all rows: sets may have different column counts and types, so
  flattening corrupts boundaries and metadata.
- Replace `QueryResult` with a collection everywhere: that forces unrelated
  browse and paging APIs to model a capability they do not use and causes a
  larger migration than the additive batch method.
