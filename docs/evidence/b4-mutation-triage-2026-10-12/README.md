# B4 bounded mutation triage

The initial masking and SSH mutation probes ran on 2026-10-12 in branch `b4/durable-audit-sync-triage` after merging `linux` at `3f7791d576cb7edac7732c263035f4da6ba52092`. `linux` then advanced to `eff1a52d019b34b6b68e1c5e149cf2083389f6bf`; after that merge, the bundle rollback mutants and unmutated cleanup selectors passed on branch commit `1d40fbedb25add03ef1233575774fd04a1de00f5`. The intervening `linux` change was outside the B4 source trees. The maintainer-designated TEST-15 candidate was `bbdc39a430ede9382bc5dfa7164e51a065e2bd88`; B4 policy, SSH, storage, transport, MCP, agent and driver source trees match that candidate. This is not a claim that the full repository tree is identical.

## Results

| Area | Mutation or check | Result |
| --- | --- | --- |
| Masking | Force `PolicyGuard::should_mask` to return true | Killed by the human-visibility transparency regression. See [log](masking-should-mask-mutant.txt). |
| Masking | Remove the derived-table sensitivity guard | Killed by the new `a_wildcard_over_a_derived_table_keeps_unrelated_columns_visible` regression. See [log](masking-projection-mutants.txt). |
| Masking | Split underscore identifiers by changing the underscore comparison | Killed by `a_sensitive_identifier_with_underscores_keeps_its_full_name`. See [log](masking-projection-mutants.txt). |
| Host-key refusal | Reject every host key | Killed by the valid two-hop SSH fixture. See [log](host-key-reject-all-mutant.txt). |
| Host-key refusal | Accept every key in `check_server_key` | The existing decline test still passes. This mutation is redundant at the authentication boundary: `connect_and_auth` checks the recorded unknown-key outcome before authentication. The handshake return value alone does not grant a session. See [log](host-key-accept-all-mutant.txt) and the source trace recorded there. |
| Per-hop secrets | Return an empty saved password for every SSH hop | Killed by `password_auth_uses_the_secret_bound_to_each_hop`. |
| Per-hop secrets | Omit every saved private-key passphrase | Killed by `private_key_passphrases_use_the_secret_bound_to_each_hop`. |
| Bundle rollback | Make the bundle storage adapter a no-op | Killed by `rolling_back_a_bundle_import_removes_its_per_hop_credentials`, which requires the imported secret to exist before cleanup. This alone did not mutate the rollback path. |
| Bundle rollback | Make legacy credential deletion a no-op, then make per-hop password deletion a no-op | Both mutations are killed by their cleanup selectors after a successful store. Both selectors pass on unmutated source. See [log](bundle-rollback-mutants.txt). |
| Durable audit | Skip parent sync, invert the created-file guard, or skip parent-directory sync | All three mutations were killed by the new `durable_creation_propagates_parent_sync_failure` regression. See [log](durable-parent-sync-mutation.txt). |

The two new regressions pass without mutations. The mutation runs are targeted probes, not a full mutation campaign. The host-key accept-all result is not treated as a killed mutant; it identifies an equivalent mutation for the tested externally visible authentication flow. The bundle adapter no-op probe is retained as supporting evidence, but the explicit cleanup mutants above provide the rollback-path proof.

## Remaining acceptance

This evidence does not close frozen-candidate or installed Arch/Hyprland acceptance for AUD-2, B4-7, B4-16 or B4-22. It also does not replace the maintainer's Forgejo driver and PostgreSQL release layers, nightly, or power-loss testing. The six TEST-15 selectors and their independent state/request-count evidence are recorded separately in [the candidate manifest](../test15-bbdc39a/manifest.json).
