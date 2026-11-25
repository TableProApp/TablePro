# Formal model of the sync keys

Tamarin theories for the flows and claims of [ADR 0053](../../decisions/0053-end-to-end-keys-under-the-recovery-key.md), Formal model and review, under the attacker of [the sync threat model](../sync-threat-model.md).

- Every theory models 0053 at `10cd539da7` (#4485), the text frozen for G0 round 4.
- A flag named `OLD...` or `ASKSIGNED` models the text before G0 round 1 (`e8879f95ee`), where the model found the attack that the fix closes. `NOCOMMIT` and `LATEVIEW` show why the comparison needs its commitment and its timing.

## Running

- **Prover:** Tamarin 1.12.0 with Maude 3.5.1, from the Homebrew tap: `brew install tamarin-prover/tap/tamarin-prover`, which installs Maude with it.
- **All runs:** `./run.sh`. It proves one lemma per prover run, each under a time limit (`-t`, default 1200 s), several at once (`-j`, default 4), and compares each result with `runs.txt`. It exits 1 when a result differs from the one expected.
- **Some runs:** `./run.sh team-keys` or `./run.sh identity_continuity` keeps the lines of `runs.txt` that contain a filter.
- **One lemma by hand:** `tamarin-prover team-keys.spthy --prove=no_tk_to_revoked_sk -D=PERHOLDER`. Add `--interactive` to browse a trace.

A timeout is a timeout, never a pass.

## Theories

| Theory | 0053 sections | Flags |
|---|---|---|
| `recovery.spthy` | The recovery key and the recovery blob; Flows: Genesis, Recovery with the recovery key | |
| `replace-recovery.spthy` | Identity log, `replace`, a replaced key never decides; Flows: Replace Recovery Key | `OLDREPLACE`: Replace keeps IK and AK |
| `sas-commitment.spthy` | Comparing keys: the exchange, when each side fixes its view | `NOCOMMIT`: no commitment; `LATEVIEW`: the initiator reads its heads after its reveal |
| `device-approval.spthy` | Comparing keys: device approval; Flows: Approving a device; Stale or missing state (re-pin by comparison) | |
| `member-confirmation.spthy` | Comparing keys: member confirmation and the QR code; Flows: Confirming a member | |
| `device-removal.spthy` | Device log, the device set, descendants; Flows: Removing a lost device; ending an account fork | `OLDLEAVE`: a rotate names only holders in the set |
| `identity-heads.spthy` | Identity log: `dh` never goes back; the reset's holder | `OLDDH`: `dh` may go back |
| `log-chain.spthy` | Rollback and forks; Restore; Stale or missing state (the anchored re-pin) | |
| `server-enforcement.spthy` | Server enforcement (D8), Key objects as records, Rows and the veto (a row removal only locks); Flows: Reset and the `fresh` reset, the delay, and the cancel by any holder the logs list | `OLDRESET`: a reset applies at once |
| `team-keys.spthy` | Team log: holder-signed statements, voided grants, revocations that stay, `key`; member bundles, the member's own check; Flows: Removing a member, Rotation pending | `ASKSIGNED`: team statements signed with the account-wide ASK |
| `team-signers.spthy` | Team log: `signer_add`, `signer_remove`, `approve`, k = min(2, n), the time-locked removal and its cancel from any listed holder, voided cancels, a reset's suspension, `reroot` | |
| `team-fork.spthy` | Ending a team fork: k at the fork point, signers neither branch removes, no dropped cancel or revocation | |
| `waits.spthy` | Waits on the server's clock, `after`, time receipts, rotating the receipt key, Restore | |
| `envelopes.spthy` | Envelopes: the counter, the writer signature, Accepting an envelope; Floors | `OLDCOUNTER`: one counter across versions, compared alone |

## Attacker

- **Network and malicious server.** Every theory but `server-enforcement.spthy` gives the attacker the network (Dolev-Yao): it reads every record and statement, drops, delays, replays and reorders them, and writes its own. That is a server with full control of delivery and storage.
- **Honest server.** `server-enforcement.spthy` models the server's own checks. The server is honest, clients reach it over TLS, and the attacker sends its own requests.
- **Device compromise.** Rules reveal a holder's keys and what it holds: `Compromise`, `Reveal_Holder`, `StealMemberDevice`, `StealSignerDevice`, `StealHolder`.
- **Recovery key.** `RevealS`, `RevealIK`, `RevealOldS` and `RevealCurrentS` give the attacker S or IK.
- **IdP or session compromise.** In `server-enforcement.spthy` the attacker holds a bearer token for every account and may start any genesis while an account has none (trust on first use).
- **Malicious members and signers.** Attacker accounts confirmed or added by a stolen signer holder, and in `team-signers.spthy` a signer the attacker holds from the start.

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
  - `team-signers` has two signers, A honest and B held by the attacker, and the accounts A adds. A reset of A, real or made up, suspends A and changes nothing else.
  - The comparison's commitment covers the initiator's message in `sas-commitment` and `device-approval`. In `member-confirmation` it covers the session's team and member, and the team head stays in each side's view.
  - A comparison's floors follow from the signed removals its heads cover, so the agreement on heads covers them.

## Results

RESULTS

## Falsified claims and the spec changes they imply

Rows 1 to 8 were found on the text before G0 round 1 (`e8879f95ee`), and each flag keeps the trace. Rows 1 and 2 show the commitment and its timing are needed. Rows 9 and 10 still fail as first worded, so 0053 now claims the view-relative form, and the threat model lists the split view behind each.

| # | Claim | Theory, flag | Trace | Spec change, now in 0053 |
|---|---|---|---|---|
| 1 | The words leave the attacker one guess | `sas-commitment`, `NOCOMMIT` | R takes the attacker's message, and the attacker answers I with a second preimage of R's words | The commitment before the words (Comparing keys) |
| 2 | The same, when a side reads its view late | `sas-commitment`, `LATEVIEW` | I reads its heads after its reveal, and the server picks heads whose words match R's | Each side fixes its `ctx` before it publishes its random value, and the commitment covers I's message |
| 3 | No reset takes effect without S | `server-enforcement`, `OLDRESET` | A stolen holder in the set signs a reset under a new IK and endorses it. The honest server takes it at once, and S no longer opens the account | A reset stays pending 7 days, and any holder or S cancels it |
| 4 | A removed holder cannot endorse a reset | `identity-heads`, `OLDDH` | After the rotate that removes X, the server serves a reset X endorsed that names an older `dh`, where X was in the set | An identity statement's `dh` never goes back |
| 5 | Removing a stolen device removes the holders it approved | `device-removal`, `OLDLEAVE` | The thief approves its own holder, then signs the stolen holder out. No rotate can name a holder that left, so the planted holder gets every later AK | A rotate may name a holder that left, and its descendants go with it |
| 6 | No account a removed holder confirmed receives a later TK | `team-keys`, `ASKSIGNED` | The thief signs `confirm` for a puppet with the account's ASK. After the removal, G seals the next TK to the puppet's SK | Team statements are signed by one holder and are void once a rotate names it |
| 7 | An old S after a replace extends no log | `replace-recovery`, `OLDREPLACE` | Replace kept IK, so the old blob still gives the IK in force, and the old RK wrap gives the AK | Replace rotates IK, SK and AK, and the new IK endorses it |
| 8 | A removed holder cannot pin an envelope counter | `envelopes`, `OLDCOUNTER` | Before C sees the removal, the thief writes under version 1 with a huge counter. Honest writes under version 2 have lower counters, and C refuses them for good | Counters restart at each version and compare as (`kv`, `n`); envelopes carry a writer signature |
| 9 | No TK is sealed to a revoked SK | `team-keys` | The server withholds the member's `rotate` from G's copy of the bundle, and G seals the next TK to the old SK, which the thief of the member's device holds | 0053 claims the view-relative form: no TK to an SK the signer verified as revoked. The member refuses a TK sealed to an SK it replaced and raises an alarm |
| 10 | An old S after a replace extends no log | `replace-recovery` | The server withholds the person's `replace` from C and serves a competing one, signed by the old IK and endorsed by an IK the attacker made. C sees one branch and follows it | 0053 claims it for a client that verified the `replace`, and a replaced key never decides, fork endings included |

## Ambiguities in the ADR text

- **Resolved.** When each side fixes its view in a comparison (row 2). Whether a rotate takes effect at its `dh` or at the next statement: the model reads "at its `dh`", which 0053 states. Whether a client checks a cross-referenced `dh` or `ih` hash against its own log: 0053 now makes a differing hash a fork.
- **Not modeled.** These flows are outside the theories, and G0 weighs them by text:
  - ending a fork with burned versions, and the comparison that ends a fork with an identity change on a branch, beyond the rule that a replaced key never decides (`replace-recovery`) and the rotate that names the dropped branch's holders (`device-removal`);
  - the no-holder reset's step-up and its deletion at `activate`, beyond the delay and cancel in `server-enforcement`;
  - a suspended signer's `signer_add` under its new IK, and the person signing voided grants again, beyond what `team-signers` and `team-keys` model;
  - the server's side of a restore (epochs and refill), beyond the client's refusal of a shorter log and its republish in `log-chain`.
