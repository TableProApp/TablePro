# Mutation run on `tablepro-policy`, 2026-10-11

Command, from `linux/` on `origin/linux` at `0d21eb6d4`:

```bash
cargo mutants --package tablepro-policy --test-tool cargo --timeout 60 \
  --build-timeout 900 --jobs 4 --no-shuffle -- --lib --tests
```

Result: 832 mutants in 23 minutes. 474 caught, 225 missed, 133 unviable (did not
compile), 0 timeouts. Caught share of the viable ones: 474 of 699, about 68 percent.
The full list of missed mutants is in [policy-missed-mutants.txt](policy-missed-mutants.txt).

Scope: this runs only the policy crate's own unit and integration tests. A mutant
that the `mcp`, `agentd` or app tests would catch still shows as missed here, and
some missed mutants are equivalent (the change cannot alter behaviour). Each row
below needs a person to decide which it is.

## Missed mutants by file

| File | Missed |
|---|---|
| `classify.rs` | 74 |
| `audit.rs` | 24 |
| `effects_classification.rs` | 18 |
| `guard/connection.rs` | 17 |
| `guard.rs` | 16 |
| `rules.rs` | 14 |
| `config.rs` | 13 |
| `guard/bulk.rs` | 10 |
| `principal.rs`, `guard/session.rs` | 7 each |
| `effects.rs`, `transaction_control.rs` | 6 each |
| `blast_radius.rs` | 5 |
| `verdict.rs` | 4 |
| `sensitive_projection.rs`, `lib.rs`, `select_writes.rs` | 2, 1, 1 |

## Highest risk first, for B4

1. **Environment defaults are not pinned.** Deleting `human_approve_ddl`,
   `agent_allow_ddl` or `mask_agent_results` from `EnvPolicy::prod_defaults`, or
   `agent_writes`, `human_approve_writes`, `human_approve_ddl` and
   `blast_radius_max_rows` from `local_defaults`, goes unnoticed. A test should
   assert the documented default for each environment.
2. **`StatementClass::is_write` can return a constant** (`true` or `false`) with no
   test failing, and the audit operation class arms in `audit.rs` can be removed.
3. **Combinators in the decision path:** `authorize_with_bound` (four `&&` to `||`),
   `evaluate_with_effects` (five `||` to `&&`), `evaluate_categorical_decisions`,
   `evaluate_human_dangerous_effects`, `PolicyGuard::should_mask -> true`.
4. **Audit failure handling:** `AuditState::disable_after_audit_failure` replaced
   with a no-op, and the arms of `sanitized_transport_error` (authentication,
   cancelled, timeout, TLS, connection, unsupported).
5. **Session batching:** `PolicySession::finish` (`||` to `&&`, `uncertain` field
   removed), `close`, `statement`, `note_statement`.
6. **Dialect selection** in `classify.rs` and `blast_radius.rs`: deleting the
   `postgres`, `mysql`, `sqlite` or `mssql` arm.
7. **Catalog pass-through in `guard/connection.rs`:** replacing the table, view,
   column, index and foreign key listings with an empty result is not noticed.
   These may be covered by app or driver tests outside this crate.
8. **Transaction control** (`mysql_implicit_transaction_statement`,
   `hides_transaction_control`), `withhold_panic_messages`, `Principal::label`.

## Next

- B4 triages the table above: add a test, mark equivalent, or record that another
  crate covers it.
- Run the same command on `tablepro-core` (values and export) and the transport
  and storage crates.
