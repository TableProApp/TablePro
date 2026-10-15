# PostgreSQL cache recovery regression (#900)

## Reproduction

On the unfixed driver, `application_errors_never_replay_nontransactional_effects` failed against PostgreSQL 16: six client requests advanced a sequence twelve times. The sequence is an independent oracle because its advancement survives the function exception and transaction rollback.

The fixture exercises ordinary and controlled queries, parameterized queries, ordinary and parameterized execution, and controlled parameterized execution. It includes arbitrary `0A000`, an application error with the cached-plan message, and an `XX000` application error with a type-cache message.

## Fix boundary

The driver keeps SQLx errors until retry selection, then maps them to the existing public error contract. Recovery requires server source-file/routine diagnostics for top-level cached-plan revalidation or parameter input-type lookup. Procedural error context refuses retry. Missing diagnostics refuse retry. A stream that has already yielded rows refuses retry. Metadata failures after statement execution cannot trigger replay.

The retry remains inside the same controlled driver operation and deadline. Dedicated sessions and transactions still use the single-attempt path. No policy or audit rules change.

PostgreSQL source references: [plan revalidation](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/utils/cache/plancache.c), [type input lookup](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/utils/cache/lsyscache.c), [protocol error diagnostics](https://www.postgresql.org/docs/current/protocol-error-fields.html).

## Validation

- Unfixed native regression: failed, observed 12 sequence advances instead of 6.
- Fixed native no-replay regression: passed.
- Existing SELECT-star-after-ALTER regression: passed.
- Existing parameter type-change recovery and warm-session enum DROP/CREATE cases: passed.
- Full local preflight, documentation links, issue ledger and ignored-test inventory checks: passed.
- A guarded query/execute regression is included in the existing release tier; the exact-head Forgejo result is recorded on the pull request before merge.

This does not qualify every PostgreSQL-compatible server. A server that omits or changes the verified diagnostics returns the error explicitly rather than receiving an automatic retry.

## Merged acceptance

[#921](https://github.com/cozyGarage/BookiE/pull/921) merged as `73ac5c6cf7e286ae80b64b3f4371524a81132587` and closed #900. Forgejo run 475 passed for `ae61021e2c5ad5be34131f3f7490d78659d8c789`. The subsequent linux merge left the PR's own `crates`/`scripts` diff byte-identical to that gated head (SHA-256 `592df06d9522baa4bc8eece42f58eb930c99a609592bfee987bbea3a50108409`). GitHub checks, CodeQL and SonarCloud passed at updated PR head `324a06c5629925b1b1804faf77bbbc072536fc9a` before merge.

The later linux sync floor failure is recorded in the [completion validation evidence](2026-10-15-postgres-completion-routing.md); it was not counted as a passing run.

Research catalogue case PG-15 is covered by `application_errors_never_replay_nontransactional_effects` and `guarded_application_error_does_not_replay_sequence_effects`. The final combined linux passed Forgejo run 496 after the completion follow-up merged.
