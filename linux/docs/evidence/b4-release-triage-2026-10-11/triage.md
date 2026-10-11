# Focused B4 release triage, 2026-10-11

Source reviewed: BookiE `fork/linux` at `63f6d2eb320e309f2663f257fbddf7f4e54a37ee`.
Pending fixes are separate PRs, not properties of this baseline. This is a
bounded source/test review of security-relevant mutation survivors, not a new
full mutation run, hosted acceptance or a power-loss experiment.

| Boundary | Disposition | Evidence and next proof |
| --- | --- | --- |
| Masking unknown sources | Confirmed product defect, fixed in pending #537 | Native PostgreSQL guard test `an_agent_cannot_expose_sensitive_sources_through_renamed_or_record_projections` asserts redaction and a visible ordinary column. A follow-up `array_agg(c.*)` cast-to-text case failed on #537's first head with the synthetic sensitive value visible; its revised code passes that native case. Retest the exact final head on Forgejo |
| `should_mask` replaced with constant true | Overmasking test gap, not equivalent behaviour | This removes the human/agent distinction and can hide ordinary human values. It does not demonstrate disclosure. Keep in TEST-2; existing guard transparency tests establish ordinary guarded reads, but this review did not rerun that mutant |
| `ClientHandler::check_server_key` replaced with true/false | Trust bypass or availability change; fixture outside ordinary unit coverage | Ignored Docker `agent_auth` tests cover `declining_a_built_in_host_key_does_not_learn_it`, `a_two_hop_chain_reaches_the_final_host`, `cancelling_while_trusting_the_second_hop_does_not_learn_its_host_key`, and `a_changed_key_on_the_second_hop_is_reported_as_a_host_key_mismatch`. They belong to `scripts/test-ssh.sh`. Require this layer on the candidate; this review does not claim those mutants were caught |
| Hop password/passphrase selection | Ignored Secret Service coverage explains an ordinary-unit blind spot | `isolated-tests.json` registers per-hop password/passphrase tests, missing-jump-secret refusal and legacy refusal. Run `scripts/test-secret-service.sh` in its private keyring. No desktop keyring probe or root-secret fallback is authorized |
| Bundle credential rollback | Pure rollback and real keyring proof have different scope | `connection_bundle_secret_transaction::tests::a_later_secret_write_failure_restores_values_replaced_earlier` checks replacement restoration after a later write fails. Isolated bundle tests check per-hop collection, replacement refusal and rollback deletion. Keyring adapter no-op survivors need that tier, not only the fake store; installed bundle audit remains B4-22 |
| Public `disable_after_audit_failure` replaced with no-op | Missing direct public-entry assertion | The existing policy state test called `disable_globally`, while the app calls the public entry. #538 updates the generation/global-lockdown assertion to exercise that public method. Journal failure must disable existing and replacement generations |
| Journal creation/parent sync no-ops | Durability proof gap; not equivalent | Source calls `sync_data` on durable append and synchronizes created files/parents. Recovery tests prove reopen and incomplete-write handling, not persistence across power loss. Track fault injection for file/directory sync under TEST-2; do not describe reopen tests as crash-durability qualification |

The mutation reports remain dated measurements. Several name `origin/linux`
from their producer's checkout; that remote name is not the unrelated `origin`
configured in this B4 checkout. Use the recorded source SHA, where present,
and `fork/linux` for current work. Reports without an exact source hash cannot
establish exact-candidate mutation coverage.

This triage finds no basis for reopening merged SSH, transport or bundle
implementations wholesale. The demonstrated masking and terminal-audit defects
need the focused fixes; fixture and durability gaps retain their explicit
acceptance or backlog boundaries.
