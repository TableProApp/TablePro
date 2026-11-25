# Formal model of the sync keys

**Superseded 2026-11-25: the design moved to the 1Password/Bitwarden model (ADR 0056). These theories model the earlier 0053 and are kept for the record.**

Tamarin theories for the flows and claims of [ADR 0053](../../decisions/0053-end-to-end-keys-under-the-recovery-key.md), Formal model and review, under the attacker of [the sync threat model](../sync-threat-model.md).

- Every theory models 0053 on main at `9bdaa24f8a`, the text G0 round 6 reviews (its 0053 is #4502's `81ae48462f`): forks are equivocation only and freeze a generation, a new generation leaves one, nothing is voided, `revoke_add` undoes what removed holders alone added, versions step by one.
- **Runs behind the Results:** `r6` and `r7`, at 0053 `81ae48462f`, which main's `9bdaa24f8a` carries unchanged. `r7` reran every lemma of a theory changed after `r6` started, and `r6` holds the rest.
- **Flags that model older text.** A flag named `OLD...` models the text before G0 round 1 (`e8879f95ee`), where the model found the attack that the fix closes. `NOCOMMIT` and `LATEVIEW` show why the comparison needs its commitment and its timing. `UNCHECKED` drops three checks of `team-signers`, so its 2-step lemmas are shown not to be vacuous.
- **Flags that speed a search.** `EXEC`, `CANCELS` and `NOCOLLISION` leave out rules an exists-trace lemma does not use; a trace found without them exists with them. `NOINSET` and `NOCUT` drop a restriction for an all-traces lemma that does not rest on it; a lemma that holds on more runs holds on fewer.

## Running

- **Prover:** Tamarin 1.12.0 with Maude 3.5.1, from the Homebrew tap: `brew install tamarin-prover/tap/tamarin-prover`, which installs Maude with it.
- **All runs:** `./run.sh`. It proves one lemma per prover run, under a time limit (`-t`, default 1200 s) and a heap cap (`-m`, default 3G, with `+RTS -N2`), one at a time unless `-j` says otherwise, and compares each result with `runs.txt`. It exits 1 when a result differs from the one expected. Set `RUN_BEFORE_PROOF` to a command that waits for free memory to run it on a busy machine.
- **Some runs:** `./run.sh team-keys` or `./run.sh no_rollback` keeps the lines of `runs.txt` that contain a filter.
- **One lemma by hand:** `tamarin-prover team-keys.spthy --prove=no_tk_to_revoked_sk +RTS -M3G -N2 -RTS`. Add `-D=OLDRESET` for a flag, and `--interactive` to browse a trace.

A timeout, an out-of-memory stop or a stop by signal is never a pass. Every theory has an executability lemma, so a pass is not vacuous.

## Theories

| Theory | 0053 sections | Flags |
|---|---|---|
| `recovery.spthy` | The recovery key and the recovery blob; Flows: Genesis, Recovery with the recovery key | |
| `replace-recovery.spthy` | Identity log, `replace`, a replaced key never decides; Flows: Replace Recovery Key | `OLDREPLACE`: Replace keeps IK and AK |
| `sas-commitment.spthy` | Comparing keys: the exchange, when each side fixes its view | `NOCOMMIT`: no commitment; `LATEVIEW`: the initiator reads its heads after its reveal |
| `device-approval.spthy` | Comparing keys: device approval; Flows: Approving a device; Stale or missing state (re-pin by comparison) | |
| `member-confirmation.spthy` | Comparing keys: member confirmation and the QR code; Flows: Confirming a member | `NOCOLLISION` |
| `device-removal.spthy` | Device log, the device set, descendants; Flows: Removing a lost device, including a holder that signed out | `OLDLEAVE`: a rotate names only holders in the set; `NOINSET` |
| `identity-heads.spthy` | Identity log: `dh` never goes back; the reset's holder | `OLDDH`: `dh` may go back |
| `log-chain.spthy` | Rollback and forks: a fork freezes the log; Restore; Stale or missing state (the anchored re-pin) | |
| `generations.spthy` | Rollback and forks: a fork is two statements at one position, one statement per position, a new generation with S | |
| `versions.spthy` | Keys and Logs: versions step by exactly one; Floors and the current version: no `kv` above it | |
| `server-enforcement.spthy` | Server enforcement (D8), Key objects as records, Rows and the veto (a row removal only locks); Flows: Reset and the `fresh` reset, the delay, and the cancel by any holder the logs list | `OLDRESET`: a reset applies at once; `EXEC`, `CANCELS`, `NOCUT` |
| `team-keys.spthy` | Team log: holder-signed statements that stay valid after a removal, `remove_member`, `key`; member bundles, the member's own check; Flows: Removing a member, Rotation pending | `EXEC` |
| `team-signers.spthy` | Team log: `signer_add`, `signer_remove`, `approve`, k = min(2, n), the time-locked removal and its cancel from a pinned holder, the sole owner after a reset, `reroot` | `UNCHECKED` |
| `revoke-add.spthy` | Team log: `revoke_add` and statements under IK; the removal sheet | |
| `team-positions.spthy` | Team log: references move forward along the team log | |
| `waits.spthy` | Waits on the server's clock, `after`, time receipts with their epoch, rotating the receipt key, Restore | |
| `envelopes.spthy` | Envelopes: the counter, the writer signature, Accepting an envelope; Floors | `OLDCOUNTER`: one counter across versions, compared alone |

## Attacker

- **Network and malicious server.** Every theory but `server-enforcement.spthy` gives the attacker the network (Dolev-Yao): it reads every record and statement, drops, delays, replays and reorders them, and writes its own. That is a server with full control of delivery and storage.
- **Honest server.** `server-enforcement.spthy` models the server's own checks. The server is honest, clients reach it over TLS, and the attacker sends its own requests.
- **Device compromise.** Rules reveal a holder's keys and what it holds: `Compromise`, `Reveal_Holder`, `StealMemberDevice`, `StealSignerDevice`, `StealHolder`.
- **Recovery key.** `RevealS`, `RevealIK`, `RevealOldS` and `RevealCurrentS` give the attacker S or IK.
- **Signing keys.** `StealLogKey` and `StealChainKey` give a log's signing key, which is what a fork needs. `LeakReceiptKey` gives the server's receipt key.
- **IdP or session compromise.** In `server-enforcement.spthy` the attacker holds a bearer token for every account and may start any genesis while an account has none (trust on first use).
- **Malicious members and signers.** Attacker accounts confirmed or added by a stolen signer holder, and in `team-signers.spthy` a signer the attacker holds from the start and a reset of the other signer's account that the server made up.

## How the model abstracts the ADR

- **Primitives.**
  - AES-256-GCM is `senc`, and opening is pattern matching on it, which models an authenticated cipher.
  - HPKE base mode is `aenc` to a public key: anyone can seal, and nothing authenticates the sender.
  - HKDF, `kid` and SHA-256 are one-way functions. Ed25519 is the `signing` builtin.
  - `LP` encoding, JWS framing, base64url and padding are not modeled. The vectors in 0053 cover them.
- **Short authenticated strings.**
  - The words are `sas(h(...))`. `spre(known, target)` lets the attacker compute a second preimage for any one input it controls, once it knows every other input and the words it must match.
  - This gives the attacker more than a 2^64.6 search. The single guess per session that remains is outside a symbolic model.
- **Comparisons elsewhere.** `device-removal`, `server-enforcement` and `team-keys` treat a finished comparison as authentic. `device-approval` and `member-confirmation` prove it.
- **Lineage.** "Every holder they approved, directly or not" is a lineage term: a holder approved by H has H's lineage inside its own. A rotate that names H takes out every holder whose lineage contains H's.
- **Logs.**
  - `recovery`, `device-approval` and `member-confirmation` keep heads as hashes of the statements.
  - `device-removal` uses the order in which the removing holder takes statements; the hash chain and the `ih` rule make that order the log's.
  - `server-enforcement` names each new head with a fresh value.
  - `identity-heads` uses two ordered device heads, and `log-chain` numbers a log's statements.
- **Time.** `waits.spthy` counts days on the server's clock and checks the 7-day waits against the recorded times, receipts and restores. The other theories have no clock: there a reset or a time-locked removal completes at any time after its start unless its veto came first.
- **Scope.**
  - One holder removes devices, one envelope of one record carries counters, and key versions are 1 and 2.
  - `team-signers` has two signers, A honest and B held by the attacker, and the accounts A adds. A reset of A, real or made up, suspends A, and its reset account may start A's removal, which A's pinned holder can cancel.
  - `versions` has one key chain; the other theories make each new key fresh, so a version number adds nothing there.
  - `prev_at` is not modeled apart from the hash chain that carries it in `log-chain`.
  - The comparison's commitment covers the initiator's message in `sas-commitment` and `device-approval`. In `member-confirmation` it covers the session's team and member, and the team head stays in each side's view.
  - A comparison's floors follow from the signed removals its heads cover, so the agreement on heads covers them.

## Results

The runs stopped when the design moved to ADR 0056, so the table is partial. Times are seconds on a shared Mac, one proof at a time under a 3 GB heap. "stopped" is a proof ended by signal, by the memory watchdog or by hand to rerun it under a flag; "not run" was queued when the work stopped. Neither is a pass.

| Claim | Theory, flag | Lemma | Result | Time |
|---|---|---|---|---|
| 1. Secrecy of AK and TK versions after a removal, against a removed holder working with the server, except to accounts it confirmed or added that the person has not revoked yet | `device-removal`, `NOINSET` | `attacker_approvals_descend_from_stolen` | not run | - |
|  | `device-removal`, `NOINSET` | `ak_after_removal_secret` | not run | - |
|  | `team-keys` | `tk_reaches_only_sealed_sks` | stopped | 206s |
|  | `team-keys` | `removed_member_gets_no_new_tk` | verified | 0s |
|  | `team-keys`, `EXEC` | `removal_keeps_past_statements` | not run | - |
| 2. Authenticity of IK on recovery | `recovery` | `recovery_ik_authentic` | verified | 8s |
|  | `recovery` | `recovery_open_ik_authentic` | verified | 7s |
|  | `recovery` | `ik_rk_secret` | verified | 7s |
|  | `recovery` | `ak_secret` | verified | 7s |
|  | `recovery` | `ak_after_recovery_rotate_secret` | verified | 10s |
| 3. No TK version sealed to an SK the sealing signer has verified as revoked (the stronger form fails) | `team-keys` | `no_tk_to_sk_the_signer_saw_revoked` | verified | 1s |
|  | `team-keys` | `member_never_uses_tk_sealed_to_its_replaced_sk` | verified | 0s |
|  | `team-keys`, `EXEC` | `member_alarms_on_tk_sealed_to_its_replaced_sk` | not run | - |
|  | `team-keys`, `EXEC` | `no_tk_to_revoked_sk` | not run | - |
| 4. Injective agreement on device approval and member confirmation, each view fixed before its random value | `sas-commitment` | `commitment_leaves_one_guess` | verified | 0s |
|  | `sas-commitment` | `comparison_agreement` | verified | 1s |
|  | `sas-commitment`, `NOCOMMIT` | `comparison_agreement` | falsified | 1s |
|  | `sas-commitment`, `LATEVIEW` | `comparison_agreement` | falsified | 2s |
|  | `device-approval` | `commitment_leaves_one_guess` | verified | 4s |
|  | `device-approval` | `approver_agreement_injective` | verified | 5s |
|  | `device-approval` | `new_holder_agreement_injective` | verified | 5s |
|  | `device-approval` | `approved_ak_secret` | verified | 6s |
|  | `member-confirmation` | `commitment_leaves_one_guess` | verified | 16s |
|  | `member-confirmation` | `signer_agreement_injective` | verified | 17s |
|  | `member-confirmation` | `member_agreement` | verified | 8s |
|  | `member-confirmation` | `tk_secret` | verified | 25s |
| 5. Refusal of rollback through chained heads, re-pin included | `log-chain` | `appended_seq_grows` | verified | 0s |
|  | `log-chain` | `appended_once_per_seq` | verified | 0s |
|  | `log-chain` | `heads_are_the_signers` | verified | 1s |
|  | `log-chain` | `no_rollback` | verified | 2s |
| 6. No holder a removed holder approved, directly or not, receives a later key version | `device-removal`, `NOINSET` | `ak_after_removal_secret` | not run | - |
|  | `device-removal` | `can_remove_stolen_holder_after_it_signed_out` | verified | 2s |
|  | `device-removal`, `OLDLEAVE` | `can_remove_stolen_holder_after_it_signed_out` | falsified | 0s |
| 7. A fork freezes its generation; only two signed statements served as applied make one; a server without a key cannot fork a log one holder writes | `log-chain` | `fork_freezes_the_log` | verified | 1s |
|  | `log-chain` | `no_false_fork_alarm` | verified | 0s |
|  | `generations` | `fork_freezes_the_generation` | not run | - |
|  | `generations` | `fork_needs_two_signers_or_a_key` | not run | - |
| 8. A person with S leaves a fork through a new generation; no IK a client saw replaced starts one | `generations` | `new_generation_with_s_executable` | stopped | 206s |
|  | `generations` | `only_s_starts_a_generation` | not run | - |
|  | `replace-recovery` | `replaced_ik_starts_no_generation` | not run | - |
|  | `replace-recovery`, `OLDREPLACE` | `replaced_ik_starts_no_generation` | not run | - |
| 9. A revoke_add takes effect only for an addition the account's own removed holders alone brought to k | `revoke-add` | `revoke_add_only_for_removed_holders_alone` | not run | - |
|  | `revoke-add` | `no_revoke_add_of_what_another_signer_approved` | not run | - |
|  | `revoke-add` | `revoke_add_needs_s` | not run | - |
| Team-log references move forward by position | `team-positions` | `old_head_refused_after_a_newer_one` | not run | - |
|  | `team-positions` | `old_head_taken_before_a_newer_one` | not run | - |
| 10. Removal never changes past statements, so one head replays one state | `team-keys`, `EXEC` | `removal_keeps_past_statements` | not run | - |
|  | `team-keys` | `removal_stays_when_its_signer_is_removed` | verified | 10s |
| 11. Every version is exactly one above the last; no kv above the current version | `versions` | `versions_step_by_one` | verified | 1s |
|  | `versions` | `no_version_skipped` | verified | 0s |
|  | `versions` | `no_kv_above_the_current_version` | verified | 1s |
| 12. No reset takes effect without S, or without the full delay with no cancel; removing rows keeps the cancel | `server-enforcement` | `reset_needs_s_or_full_delay` | not run | - |
|  | `server-enforcement`, `CANCELS` | `row_removal_keeps_the_cancel` | not run | - |
|  | `server-enforcement`, `CANCELS` | `stolen_holder_reset_cancelled` | not run | - |
|  | `server-enforcement`, `OLDRESET` | `reset_needs_s_or_full_delay` | not run | - |
|  | `identity-heads` | `removed_holder_cannot_endorse_a_reset` | verified | 0s |
|  | `identity-heads`, `OLDDH` | `removed_holder_cannot_endorse_a_reset` | falsified | 1s |
| 13. No time-locked removal completes after a pinned holder's cancel, or within 7 days by the recorded times | `team-signers` | `cancel_ends_a_removal_for_good` | verified | 0s |
|  | `team-signers`, `UNCHECKED` | `cancel_ends_a_removal_for_good` | not run | - |
|  | `waits` | `waits_never_shortened` | verified | 17s |
|  | `waits` | `receipt_keys_chain_to_the_pin` | verified | 0s |
|  | `waits` | `no_false_receipt_alarm` | stopped | 506s |
| 14. k = min(2, n) to add a signer or remove another, unless an uncancelled time lock ran; no re-root while a signer is left | `team-signers` | `no_signer_added_alone` | verified | 0s |
|  | `team-signers` | `no_signer_removed_by_one_other` | verified | 1s |
|  | `team-signers` | `no_reroot_while_a_signer_is_left` | verified | 0s |
|  | `team-signers`, `UNCHECKED` | `no_reroot_while_a_signer_is_left` | not run | - |
| 15. No removed member receives a TK version after the device that removed it is removed | `team-keys` | `removal_stays_when_its_signer_is_removed` | verified | 10s |
| 16. An old S after a replace extends no log a client that verified the replace follows | `replace-recovery` | `old_recovery_key_extends_no_log_after_the_replace` | verified | 3s |
|  | `replace-recovery` | `old_recovery_key_gives_no_identity` | verified | 2s |
|  | `replace-recovery` | `old_recovery_key_gives_no_account_key` | verified | 2s |
|  | `replace-recovery` | `old_recovery_key_extends_no_log` | falsified | 3s |
|  | `replace-recovery`, `OLDREPLACE` | `old_recovery_key_extends_no_log_after_the_replace` | falsified | 2s |
| 17. The old signer's veto holds against a removal its own reset account starts | `team-signers` | `old_signers_veto_holds_against_its_reset_account` | verified | 1s |
|  | `team-signers` | `reset_holder_cannot_cancel` | verified | 0s |
|  | `team-signers`, `UNCHECKED` | `reset_holder_cannot_cancel` | not run | - |
|  | `team-signers` | `cancel_ends_a_removal_for_good` | verified | 0s |
| 18. No reset a server made up lowers k or opens a reroot | `team-signers` | `reset_removes_no_signer` | verified | 0s |
|  | `team-signers` | `no_reroot_while_a_signer_is_left` | verified | 0s |
| 19. A removed holder cannot pin an envelope counter past the next version | `envelopes` | `stolen_holder_cannot_pin_the_counter` | verified | 2s |
|  | `envelopes` | `no_superseded_envelope` | verified | 1s |
|  | `envelopes` | `nothing_from_the_removed_holder_after_removal` | verified | 1s |
|  | `envelopes`, `OLDCOUNTER` | `stolen_holder_cannot_pin_the_counter` | falsified | 2s |
| D8. A phished session writes no key object and no envelope | `server-enforcement` | `members_are_honest_or_a_break_in` | not run | - |
|  | `server-enforcement` | `write_needs_approved_holder` | not run | - |
| Executability: an honest run exists in each theory | `recovery` | `recovery_executable` | verified | 16s |
|  | `replace-recovery` | `replace_executable` | verified | 3s |
|  | `sas-commitment` | `exchange_executable` | verified | 1s |
|  | `device-approval` | `approval_executable` | verified | 11s |
|  | `member-confirmation`, `NOCOLLISION` | `words_executable` | not run | - |
|  | `member-confirmation`, `NOCOLLISION` | `qr_executable` | not run | - |
|  | `device-removal` | `removal_executable` | verified | 10s |
|  | `identity-heads` | `reset_executable` | verified | 1s |
|  | `log-chain` | `chain_executable` | verified | 6s |
|  | `log-chain` | `repin_executable` | verified | 2s |
|  | `log-chain` | `fork_executable` | verified | 24s |
|  | `versions` | `versions_executable` | verified | 0s |
|  | `server-enforcement`, `EXEC` | `enforcement_executable` | not run | - |
|  | `team-keys`, `EXEC` | `team_executable` | not run | - |
|  | `generations` | `fork_by_two_holders_executable` | verified | 9s |
|  | `revoke-add` | `revoke_add_executable` | not run | - |
|  | `team-positions` | `positions_executable` | not run | - |
|  | `team-signers` | `reroot_executable` | not run | - |
|  | `team-signers` | `signers_executable` | verified | 2s |
|  | `team-signers` | `timelock_cancelled` | verified | 0s |
|  | `waits` | `wait_executable` | verified | 2s |
|  | `waits` | `restore_executable` | verified | 2s |
|  | `waits` | `receipt_alarm_executable` | verified | 26s |
|  | `envelopes` | `envelopes_executable` | verified | 13s |

## Falsified claims and the spec changes they imply

Rows 1 to 8 were found on the text before G0 round 1 (`e8879f95ee`), and each flag but row 6's keeps the trace. Rows 1 and 2 show the commitment and its timing are needed. Rows 9 and 10 still fail as first worded, so 0053 now claims the view-relative form, and the threat model lists the split view behind each.

| # | Claim | Theory, flag | Trace | Spec change, now in 0053 |
|---|---|---|---|---|
| 1 | The words leave the attacker one guess | `sas-commitment`, `NOCOMMIT` | R takes the attacker's message, and the attacker answers I with a second preimage of R's words | The commitment before the words (Comparing keys) |
| 2 | The same, when a side reads its view late | `sas-commitment`, `LATEVIEW` | I reads its heads after its reveal, and the server picks heads whose words match R's | Each side fixes its `ctx` before it publishes its random value, and the commitment covers I's message |
| 3 | No reset takes effect without S | `server-enforcement`, `OLDRESET` | A stolen holder in the set signs a reset under a new IK and endorses it. The honest server takes it at once, and S no longer opens the account | A reset stays pending 7 days, and any holder or S cancels it |
| 4 | A removed holder cannot endorse a reset | `identity-heads`, `OLDDH` | After the rotate that removes X, the server serves a reset X endorsed that names an older `dh`, where X was in the set | An identity statement's `dh` never goes back |
| 5 | Removing a stolen device removes the holders it approved | `device-removal`, `OLDLEAVE` | The thief approves its own holder, then signs the stolen holder out. No rotate can name a holder that left, so the planted holder gets every later AK | A rotate may name a holder that left, and its descendants go with it |
| 6 | No account a removed holder confirmed receives a later TK | `team-keys`, before round 1 | The thief signs `confirm` for a puppet with the account's ASK. After the removal, G seals the next TK to the puppet's SK | Round 1 voided what the removed holder signed. Round 5 dropped voiding: team statements are signed by one holder, stay valid, and the removal flow lists them for the person to revoke. `removal_keeps_past_statements` shows the puppet stays until that `remove_member` |
| 7 | An old S after a replace extends no log | `replace-recovery`, `OLDREPLACE` | Replace kept IK, so the old blob still gives the IK in force, and the old RK wrap gives the AK | Replace rotates IK, SK and AK, and the new IK endorses it |
| 8 | A removed holder cannot pin an envelope counter | `envelopes`, `OLDCOUNTER` | Before C sees the removal, the thief writes under version 1 with a huge counter. Honest writes under version 2 have lower counters, and C refuses them for good | Counters restart at each version and compare as (`kv`, `n`); envelopes carry a writer signature |
| 9 | No TK is sealed to a revoked SK | `team-keys` | The server withholds the member's `rotate` from G's copy of the bundle, and G seals the next TK to the old SK, which the thief of the member's device holds | 0053 claims the view-relative form: no TK to an SK the signer verified as revoked. The member refuses a TK sealed to an SK it replaced and raises an alarm |
| 10 | An old S after a replace extends no log | `replace-recovery` | The server withholds the person's `replace` from C and serves a competing one, signed by the old IK and endorsed by an IK the attacker made. C sees one branch and follows it | 0053 claims it for a client that verified the `replace`, and a replaced key never decides, fork endings included |

## Ambiguities in the ADR text

- **Resolved.** When each side fixes its view in a comparison (row 2). Whether a rotate takes effect at its `dh` or at the next statement: the model reads "at its `dh`", which 0053 states. Whether a client checks a cross-referenced `dh` or `ih` hash against its own log: a differing hash is a fork, and a fork freezes the log.
- **An assumption the model makes explicit.** The honest server's waits rest on the secrecy of its receipt key: with it, anyone who can republish after a restore can backdate a start. `waits_never_shortened` holds unless that key leaks.
- **Not modeled.** These flows are outside the theories, and G0 weighs them by text:
  - the no-holder reset's step-up and its deletion at `activate`, beyond the delay and cancel in `server-enforcement`;
  - a suspended signer's `signer_add` under its new IK, and the removal sheet beyond `revoke_add` and `remove_member`;
  - a new generation without S, which is a reset under its 7-day veto as `server-enforcement` models it, and a team's new team after a team fork;
  - `prev_at` and the hold on a completion seen with its start, beyond the waits in `waits` and the chain in `log-chain`;
  - the server's side of a restore (epochs and refill), beyond the client's refusal of a shorter log and its republish in `log-chain`, and the receipts in `waits`.
