# Focused B4 release triage, 2026-10-11

Source reviewed: BookiE `fork/linux` at `63f6d2eb320e309f2663f257fbddf7f4e54a37ee`.
Pending fixes are separate PRs, not properties of this baseline. This is a
bounded source/test review of security-relevant mutation survivors, not a new
full mutation run, hosted acceptance or a power-loss experiment. The
[manifest](manifest.json) records the original baseline commands and paired
reproduction logs. The later current-tip closeout checks are in the
[B4 closeout manifest](../b4-closeout-2026-10-11/manifest.json).

| Boundary | Disposition | Evidence and next proof |
| --- | --- | --- |
| Masking unknown sources | Confirmed product defect, fixed and merged in #537 | Native PostgreSQL test `an_agent_cannot_expose_sensitive_sources_through_renamed_or_record_projections` covers renamed, record and `array_agg(c.*)` casts. Dedicated `an_agent_cannot_expose_sensitive_json_through_an_outer_alias` pins the exact named outer-projection leak from the archived review. Both the new outer-alias test and the human-visibility test pass locally on the B4 branch based on `b1206e9aa`; exact frozen-candidate PostgreSQL release acceptance remains |
| `should_mask` replaced with constant true | Overmasking test gap, not equivalent behaviour | This removes the human/agent distinction and can hide ordinary human values. The new `a_human_guard_preserves_results_that_agent_masking_would_hide` regression asserts that a human still receives ordinary guarded results. The mutant itself was not run on the current branch |
| `ClientHandler::check_server_key` replaced with true/false | Trust bypass or availability change; fixture outside ordinary unit coverage | Ignored Docker `agent_auth` tests cover `declining_a_built_in_host_key_does_not_learn_it`, `a_two_hop_chain_reaches_the_final_host`, `cancelling_while_trusting_the_second_hop_does_not_learn_its_host_key`, and `a_changed_key_on_the_second_hop_is_reported_as_a_host_key_mismatch`. They belong to `scripts/test-ssh.sh`. All four named Docker scenarios passed locally on `53b0f1abb`, whose SSH source matches this baseline. Require this layer again on the candidate; no claim that these mutants were rerun |
| Hop password/passphrase selection | Ignored Secret Service coverage explains an ordinary-unit blind spot | `isolated-tests.json` registers per-hop password/passphrase tests, missing-jump-secret refusal and legacy refusal. All 14 isolated Secret Service cases passed on `53b0f1abb`. Rerun the tier on the candidate; no desktop keyring probe or root-secret fallback is authorized |
| Bundle credential rollback | Pure rollback and real keyring proof have different scope | `connection_bundle_secret_transaction::tests::a_later_secret_write_failure_restores_values_replaced_earlier` checks replacement restoration after a later write fails. Isolated bundle tests check per-hop collection, replacement refusal and rollback deletion. The real isolated keyring tier also passed locally. Adapter no-op mutants were not rerun; installed bundle audit remains B4-22 |
| Public `disable_after_audit_failure` replaced with no-op | Confirmed test gap, fixed and merged in #538 | The generation/global-lockdown regression now exercises the public method; a temporary no-op mutation failed it. Denied session COMMIT and writes also produce a terminal outcome before returning |
| Durable append data-sync failure | Missing failure-path assertion, now covered on the B4 branch | `durable_append_fails_when_data_sync_fails` injects an I/O error at the sync boundary and requires the append to return an error. It proves failure propagation, not physical persistence across power loss |
| Journal creation/parent sync no-ops | Durability proof gap remains | Source synchronizes newly created files and their parent directory. Recovery tests prove reopen and incomplete-write handling; no power-loss experiment proves persistence and parent-sync fault injection remains for post-0.2.0 TEST-2. Do not describe reopen tests as crash-durability qualification |

The mutation reports remain dated measurements. Several name `origin/linux`
from their producer's checkout; that remote name is not the unrelated `origin`
configured in this B4 checkout. Use the recorded source SHA, where present,
and `fork/linux` for current work. Reports without an exact source hash cannot
establish exact-candidate mutation coverage.

This triage finds no basis for reopening merged SSH, transport or bundle
implementations wholesale. The three demonstrated defects are fixed in #537,
#538 and #539. Existing host-key, per-hop secret, and bundle rollback tests
remain the targeted checks; the two additional local regressions pin human
visibility and durable append sync failure. Fixture, installed acceptance and
power-loss gaps retain their explicit boundaries.

## Frozen-candidate check, 2026-10-12

The maintainer designated BookiE `linux` SHA
`bbdc39a430ede9382bc5dfa7164e51a065e2bd88` as the frozen candidate. On that
exact checkout, the named outer-alias and human-visibility regressions passed.
`scripts/test-ssh.sh` passed 10 built-in SSH and 12 system OpenSSH tests;
`scripts/test-secret-service.sh` passed all 14 isolated keyring tests,
including per-hop password/passphrase selection and bundle credential rollback.
The pure bundle replacement rollback and injected durable append sync failure
tests each passed. All six focused TEST-15 lost-ack selectors passed, and the
AUD-11 policy target passed 232 tests. Exact commands and logs are in the
[candidate manifest](../test15-bbdc39a/manifest.json).

This is local Docker/Secret Service evidence. It does not establish Forgejo
acceptance, the nightly, installed Arch/Hyprland behavior or persistence across
power loss. AUD-9 remains OPEN only for the exact-head Forgejo PostgreSQL
release acceptance; the policy and mutation triage found no new product-code
change to make.
