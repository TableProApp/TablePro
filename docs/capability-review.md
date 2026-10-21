# Database client capability review

This page describes the engineering checks used to assess database-client capabilities and records BookiE's current boundaries. It is not a product ranking or a release commitment. The [backlog](backlog.md) and [Project #3](https://github.com/users/cozyGarage/projects/3) own selected work; [known limitations](known-limitations.md) describes user-visible restrictions.

## How to evaluate a capability

Evaluate the complete path a user or consumer takes, not a feature label or isolated helper. External implementations are research inputs. Adoption requires a demonstrated benefit within BookiE's product goals and accepted contracts; matching another project is not a goal. Retain a different implementation when it better satisfies those requirements.

1. **Define the contract.** State inputs, outputs, limits, cancellation behavior, and what happens when the engine or metadata cannot provide a safe answer.
2. **Trace ownership.** Follow the request through UI or MCP, application services, transport, policy, driver, and result consumers. Keep responsibilities in their owning crate.
3. **Test boundaries.** Include empty and exact-page results, one-over-limit results, NULL versus empty versus unsupported values, quoted identifiers, non-default schemas, stale requests, and failures after dispatch.
4. **Use independent evidence.** Unit tests prove local logic; a real engine proves server behavior; installed UI tests prove desktop integration. A green layer does not imply another layer passed.
5. **Check user impact.** Verify that errors are explicit, partial results carry truncation state, edits preserve identity and pending state, and cancellation does not claim success without confirmation.
6. **Measure resource use.** Record workload size, latency, memory and the relevant environment before optimizing catalog queries, result paging or previews.

Every behavior change needs a regression test that observes an outcome. For database-specific behavior, compare against an engine-side oracle or native client when the server semantics are not otherwise established. See [testing](testing.md), [validation](validation-playbook.md), and [ADR 0007](decisions/0007-type-and-value-preservation.md).

## BookiE capability boundaries

| Area | Current contract | Open boundary or evidence owner |
|---|---|---|
| Typed values | Support is type- and consumer-specific. The contract requires a supported native value to keep its meaning through each advertised result, edit, copy, export and protocol path. Unsupported values remain explicitly undecodable or are refused; they are not silently converted to NULL. | Use the [value contract index](value-contracts.md) to find the tested paths. PostgreSQL extension types such as pgvector and PostGIS need type-specific wire evidence before richer display or editing. |
| Query results | Results have row, cell and estimated-byte limits. Supported single-statement PostgreSQL editor SELECTs stream cursor pages through Core and PolicyGuard with bounded retention. | Other engines and unsupported statement shapes remain materialized. Per-page retention is row-bounded, not cell-byte-bounded. PERF-2/8 and [#554](https://github.com/cozyGarage/BookiE/issues/554) own broader memory acceptance. |
| Catalogs | PostgreSQL schema visibility can be filtered per connection; table and column metadata retain schema-qualified identity. | Hiding schemas does not reduce metadata query work. [#580](https://github.com/cozyGarage/BookiE/issues/580) owns large-catalog and restricted-role performance. Measure query latency, main-loop responsiveness and memory at representative scale before changing the implementation. |
| SQL generation | Grid writes require key information and quote identifiers through dialect-aware builders. Values use driver parameters. | Each mutation route must prove that missing or ambiguous keys are refused before reaching the driver. DDL and type support remain engine-specific. |
| Operation outcomes | Core represents success, failure, cancellation, timeout and unknown outcome. Whether a concrete operation can confirm cancellation depends on its driver and execution path; a lost acknowledgement does not authorize replay. | Check the specific operation's regression evidence. A dropped client future is not proof that the server stopped, and some paths still need outcome-conformance work. |
| Import and export | CSV import and several result-export formats are available. Limits and undecodable values are represented explicitly. | Full-table export remains refused unless a verified snapshot path exists (ADR 0014). A round-trip scenario must stay within supported import/export formats and must not imply a consistent database snapshot. |
| UI state | Relm4 commands own work tied to a component lifetime, and request identities protect some overlapping loads. Grid edits and selection retain source identity where the contract allows it. | Coverage is path-specific. For each overlapping load, search, completion or mutation path, verify a late result cannot replace newer state and cancellation reaches the owned work. |
| Access control | GUI, MCP and agent database handles use PolicyGuard. MCP scopes and connection allowlists are additional boundaries, not substitutes for SQL policy. | New write entry points need allowed and denied tests, audit terminal outcomes and proof that refusal happens before database dispatch. |
| Connections | Credentials use Secret Service; SSH and TLS identity are assembled in transport. Driver fixtures cover important TLS and tunnel paths. | Installed desktop acceptance remains distinct from container tests. See [connections](connections.md), [platforms](platforms.md) and the active acceptance board. |

## PostgreSQL edge cases

- **Retry only a known pre-execution condition.** PostgreSQL SQLSTATE `0A000` is broad. The driver retries only selected server error source/routine pairs for stale type-cache recovery; do not widen that match to the SQLSTATE alone. A failed statement can still have non-transactional effects such as sequence advancement.
- **Preserve identifier identity.** Unquoted names fold to lowercase, while quoted names preserve case and may contain dots or escaped quotes. Completion keys and catalog lookup must keep `users`, `"Users"`, `"a.b"`, and `"a""b"` distinct. The editor tests cover these forms in `apps/linux/app/src/ui/editor/completion.rs`.
- **Qualify extension types per consumer.** Existing PostgreSQL integration coverage checks hstore and ltree through server-text round trips, and citext scalar and array behavior through binding. That does not imply support for pgvector or PostGIS. Before claiming support, test the wire format and each consumer path separately; geometry needs to retain SRID, dimensions and NULL versus EMPTY state.
- **Keep session context attached to metadata.** Search path, role and temporary objects belong to a PostgreSQL session. A metadata refresh on another connection must not imply the same visible objects or permissions.

## Cross-cutting regression patterns

- **Test configured behavior at the final boundary.** For TLS, SSH and authentication settings, pair a successful route with a negative case such as an untrusted certificate or refused host key. A saved option or UI toggle does not prove the selected behavior reached the socket.
- **Carry incompleteness with the result.** Row limits, byte limits, cancellation and mid-stream failure must remain observable through grid, export and MCP consumers. A partial value must not look complete.
- **Pair cancellation with request identity.** Cancel obsolete work, then complete it late; assert it cannot replace state from the newer query, connection or search. Also verify that cancellation reaches the database operation when the contract promises it.
- **Isolate test state.** Use disposable databases and temporary config, data, audit and keyring state. A test must not overwrite or infer success from a developer's real data.
- **Use exact catalog identity.** Test non-default schemas, restricted roles, quoted identifiers, shadow objects and metadata cleanup on both success and failure. Names alone may not identify an object, and a failed metadata request must not leave its session active.
- **Pin state around successful mutations.** Assert which filters, sort order, selection, scroll position and pending edits survive each operation. Do not infer UI-state behavior from the database write succeeding.
- **Test handoff races as refusals.** When one process selects a resource for another process to claim, force a collision in the gap and assert the route fails safely instead of connecting to an unintended endpoint.

## Selecting follow-up work

Promote a candidate only when it has a user task, a code owner, an acceptance layer and a clear safety/resource contract. Existing work takes precedence over duplicate inventory:

- Large PostgreSQL catalogs belong to [#580](https://github.com/cozyGarage/BookiE/issues/580).
- PostgreSQL extension values should be qualified one type and consumer path at a time under the B3 type contract.
- Broader result memory, cancellation and transaction outcomes remain with their existing performance and B4 owners.
- UI capability requests belong in the backlog only after checking the shipped behavior and known limitations against current source.

Reports and release notes do not establish a defect in BookiE. Trace the corresponding BookiE path and reproduce the behavior before filing or changing code.
