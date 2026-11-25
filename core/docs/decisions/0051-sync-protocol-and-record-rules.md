# 0051: Sync protocol and record rules

- **Status**: Accepted; amends 0044, 0047 and 0055
- **Date**: 2026-11-25

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) puts personal, history and team scopes in one record store behind `/v2/sync`. Read against the code and the shipped clients before any of it is built, it leaves gaps the server cannot be built around:

- **Key objects have no home.** 0044 defines the end-to-end keys, not where the server keeps them or which writes it allows.
- **A restore issues versions again.** A point-in-time restore rolls `version` and `revision` back. A device that missed the runbook's `sync new-epoch` holds a `base_version` the server later gives to other content, so its patch applies with no merge, and its cursor skips writes. Self-hosted DBAs restore with their own tools.
- **Edit against deletion.** 0044 lets a deletion win. The Mac already creates a record again when a push it holds an edit for meets `unknownItem` (`SyncRecordEdit.swift`), and an integer `sort_order` renumber is an edit to every sibling, so a reorder brings deleted siblings back.
- **The facade.** Shipped 0.88 and 0.89 Macs read the library through `/v2/teams/{id}/library/changes` (`internal/library/adapter/http/v2.go` in tablepro-cloud). `/v1` publish walks a deleted folder's `parent_client_id` (`internal/library/usecase/legacy.go`), so library tombstones keep their data.
- **Smaller contradictions.**
  - 256 KiB a record is below CloudKit's 1 MiB, so a move from iCloud would drop records.
  - The scopes ETag covers epochs, horizons and policies only, so a 304 hides a role change or a new team.
  - Past grace, the server (`LapsedFeature`) and 0047 keep only `team_library`, while 0044 says pulls keep working.
  - Nothing keeps `history_entry` out of a team scope.
  - Rate limits count only per refresh token family, 120 a minute (`internal/platform/apiauth/apiauth.go`).

On 2026-11-25 the maintainer decided:

- `service_sync` goes to SaaS Pro on every cycle, Lifetime included, and to Team, history included. No quota until usage is measured. A lapse is pull-only, and the data stays.
- A new device gets nothing personal until another device or the recovery key approves it, and the server enforces that ([0056](0056-end-to-end-keys-per-account-and-device.md)).
- Content edits revive a deleted record. Placement changes never do.
- The server detects a restore from Postgres's system identifier and timeline and opens a new epoch itself. It refuses `/v2/sync` only when it cannot run that check. The version check carries the epoch.
- The facade lives until fewer than 2% of Team Library devices run older builds for 30 days. Team connection keys are not frozen meanwhile.
- A self-hosted `personalSync` switch ([0055](0055-managed-policies-for-the-sync-provider-and-tablepro-app-traffic.md)).

## Decision

`/v2/sync` serves records from one table, `sync_records`, in the scopes `sync_scopes` holds. Every write is conditional on an opaque change tag that carries the epoch, the version and a random write tag, so no stale base matches after a restore, and a push names the epoch it was built in. Each change answers on its own. Kinds are open except a reserved set: `key.*`, `secret_envelope`, `history_entry` and the three team library kinds. The server reads no field but a key version, the key-object fields 0056 names and the keys the facade projects, and verifies the Ed25519 signatures on key objects. Content edits revive a deleted record; placement edits never do. The server checks the database's identity before it serves on any connection, and a restore opens a new epoch whose cut tells each device which of its writes the server lost. Past grace every sync feature is pull-only. The library's tables move into the store in one expand release behind views, and the facade keeps its documented behavior until the maintainer's 2% threshold.

## Scopes and records

**`sync_scopes`**: `id`, `type` (`personal`, `history` or `team`), `account_id` or `team_id`, `rotation_due`, `purges_at`, `created_at`.

- One personal and one history scope per account, one scope per team.
- A scope's horizon is its highest committed revision, read through the (`scope_id`, `revision`) index, so every write path keeps it, the facade's included. It replaces the library's maximum over three tables.
- Writers lock the scope's row. The personal and history scopes of an account lock under the account hold, a team's under the team hold.
- **Current versions.** An account's current `av` is that of its newest `key.account` record with no hold (Resets). A scope key's current version is its newest `key.version` record: in the personal scope for the `personal` and `history` purposes, in a team scope for `team` (0056). Each steps by exactly one, which the server checks and refuses with `bad_statement`.
- **Envelopes and history** are written under the current version only: a `secret_envelope`'s `kv` must equal its scope key's current version, and a `history_entry`'s the current `history` version. Below it is `key_version_stale`, above it `key_version_unknown`.
- `rotation_due` is set on a team scope when a member is removed or a holder's account keys change, and cleared when the team's next version applies (Teams).
- On the wire a scope is `personal`, `history` or the team's TypeID (`team_...`), as the facade names teams.
- A scope is created by its first write, under its owner's lock. Before that, `GET /v2/sync/scopes` lists it with a horizon of 0, and a pull answers an empty page with no cursor.

**Epochs** are install-wide, as the facade's are.

- `sync_epochs`: `id`, a random UUID, never a counter, since a restore would issue a counter again; `start_revision`, where the epoch moved the revision sequence; `started_at`; and why it began. Within the lineage a database holds, each epoch's `start_revision` is above the one before, which gives the order.
- `sync_epoch_cuts`: per epoch and scope, `kept_revision`, the highest revision of the epoch before it that the scope still held when it began. A scope with no row kept nothing.
- The current epoch is the last of the lineage. A write records it as its `written_epoch`, and a record shows it as `epoch`.

**`sync_records`**: `scope_id`, `kind`, `record_id`, `id`, `version`, `revision`, `written_epoch`, `write_tag`, `fields` (jsonb), `held_until`, `deleted_at`, `deleted_reason`, `created_by`, `created_at`, `updated_by`, `updated_device`, `updated_via`, `updated_at`.

- The key is (`scope_id`, `kind`, `record_id`), with an index on (`scope_id`, `revision`).
- `id` is a uuidv7, unique: `/v1` names connections by it and the portal pages by it.
- `created_at` is when the server first took the record, which the wire shows as `taken_at` (Pull).
- `held_until` is set only on the records of a pending reset (Resets).
- `version` goes up by one with every write, through either path. `revision` comes from one sequence, `library_revision` until R2 renames it `sync_revision`.
- `written_epoch` is the epoch current at the write, and `write_tag` is 16 bytes from the OS's CSPRNG drawn by each write.
- `deleted_reason` is `user` or `policy`. `updated_device` references `devices` and is set null when the device goes.

### Kinds

- **Syntax.** Lowercase ASCII letters, digits and `_`, starting with a letter, with at most one `.` between two such parts, 1 to 64 bytes.
- **Record ids.** Valid UTF-8 without U+0000, 1 to 255 UTF-16 code units, compared as bytes and never normalized or case-folded, plus the form 0052 gives the kind.
- **Reserved:** every `key.*` kind, `secret_envelope`, `history_entry`, and the team library kinds `library_connection`, `library_folder` and `library_query`. Their names say what they are in every scope, so a personal `connection`, under the core model's schema, never shares a name with a team library item, under the bundle's. Any other kind that passes the syntax is ordinary in the personal and team scopes, so a new data kind still needs no server release.

| Kind | Scopes | Who writes | Server rule |
| --- | --- | --- | --- |
| `connection`, `group`, `tag`, `ssh_profile`, `credential_profile`, `saved_query`, `saved_query_folder`, `favourite_table`, `favourite_database`, `table_folder`, `table_folder_item`, `macos_settings`, `ios_settings`, `linux_settings`, `windows_settings`, `connection_project` (#4376's connection projects, on iCloud and TablePro Sync alike) | personal | The account's approved devices | Patch and delete |
| `library_connection`, `library_folder`, `library_query` | team | Owner, admin, editor | Patch and delete, also through the facade. Ids keep the case the library stored, lower case from shipped Macs (0052). No two ids of one kind in a team may match once lower-cased. The keys the facade projects are checked. Tombstones keep their fields until `/v1` sunsets |
| `secret_envelope` | personal, team | Personal: approved devices. Team: owner, admin, editor, from an approved device | Patch and delete, written whole. `kv` is the scope key's current version. Refused while the team is `rotation_due` |
| `history_entry` | history | Approved devices | Created once; a delete tombstones it. `kv` is the current `history` version |
| `key.account` | personal | A genesis, a rotation or a reset (Change sets) | Create only. Its signature under the IK the change calls for, and an `av` one above the current. A reset's is held 7 days |
| `key.device` | personal | An approved device, or a genesis, rotation or reset change set | Create only. Its signature under ASK at its `av`, for a device row of the account |
| `key.recovery` | personal | With its `key.account` | Create only. A certificate exists at its `av` |
| `key.cancel` | personal | A device certified at the current `av`, or any device of the account carrying an IK signature | Each cancel replaces the last. It names the pending reset's new IK, and an IK signature it carries verifies |
| `key.request` | personal | The requesting device, approved or not | Create only, bound to the DPoP key that writes it, purged once it expires |
| `key.sas` | personal | The step's device | Create only, purged with its request |
| `key.version` | personal, team | Personal: approved devices. Team: as Roles in a team scope says | Create only. Its signature under the signer's ASK at its current `av`, and a version one above the current |
| `key.wrap`, `key.ring` | personal, team | The signer 0056 names, from an approved device. In a team, a first wrap to an account only from an owner or admin | Written whole; only that writer replaces one. A wrap's signature and recipient as 0056 checks them |
| `key.member` | team | The member it names, in any role | Create only, writer-bound to that account, and a byte-for-byte copy of that account's `key.account` at the same `av` |
| Any other kind | personal, team | Personal: approved devices. Team: owner, admin, editor | Patch and delete |

- A reserved kind in a scope the table does not give it is rejected with `kind_not_in_scope`. The history scope takes only `history_entry`.
- **Writer binding.** The server checks a key kind's writer as 0052's ids and 0056's table bind it, and refuses a mismatch with `writer_bound`:

  | Kind | Bound to | Check |
  | --- | --- | --- |
  | `key.account`, `key.device`, `key.recovery`, `key.cancel`, `key.member`, and a personal `key.version`, `key.wrap` or `key.ring` | The account the id names | The id's account or owner part equals, as bytes, the caller's account id in upper case |
  | A team `key.version`, `key.wrap` or `key.ring` | Its signer: the version record's, the wrap's wrapper, the ring's version's | The caller's account is that signer |
  | `key.request` | Its device | Its DSK is the proof's DPoP key |
  | `key.sas` | The step's device | A `nonce` step's DSK is the caller's DPoP key, and a `reveal` step comes from the request's device |

  A republishing push (Republishing) skips the binding to a signer and to the account a `key.member` names, since its uploader need not be the signer. A `key.request` whose `exp` has passed, or lies more than 600 seconds after its `iat`, is `bad_statement`. A second `key.request` from a device whose first is still open is `request_pending`.
- **What the server reads.**
  - `kv`, the key version in a `secret_envelope`'s and a `history_entry`'s clear fields.
  - Key-object fields, only as 0056's table lists: it verifies the Ed25519 signature of each certificate, cancel, version record and wrap under the signer and `av` the object names, checks that versions step by one, checks a `key.recovery`'s certificate and a `key.member` copy's bytes, binds a `key.request` to its writer's DPoP key, and checks who writes each kind.
  - While the facade lives, the keys it projects from a team library record into typed columns: a folder's and a query's, checked after the patch as `ParseData` checks them today (required names and query text, client ids, an int32 `sort_order`), else `bad_value`. Other keys of a team library record stay unread.
  - No other field of any kind.

### Limits

- 1 MiB a record, measured as the library measures, on `fields` encoded without HTML escaping. A record over it stays on its device and is listed with a notice.
- 4 MiB a body and 500 changes a push. Clients split pushes by bytes as well as by count. A change set (Change sets) goes up in one push.
- A page stops at `limit` records, at most 500, or at 4 MiB of records, whichever comes first, and always holds one record.
- JSON at most 32 levels deep, no NUL character anywhere, and no JSON null in stored fields (a null in a patch removes the member, RFC 7396).
- Each scope advertises `quota`, null today. A create past a quota would be rejected `quota_exceeded`, which clients handle from the start, so a later quota needs no app release.
- The SaaS's nginx lets 5 MiB through on `/v2/sync/scopes/*/changes`.

## Protocol

Under `/v2`, OAuth scope `app`, with clients generated from the OpenAPI document. Errors are RFC 9457 problem details.

### `GET /v2/sync/scopes`

- **The epoch:** `epoch`, the current epoch's id.
- **Per scope:** `id`, `type`, `team` for a team scope, `role`, `horizon`, `epochs` (the lineage, oldest first, each epoch's id with the scope's `kept_revision`, 0 when it has no cut), `writable` (false past grace or after a lapse, when only key-object writes are taken), `policies` (Policies), `quota`, for a team scope `rotation_due` (Teams), and, for the personal and history scopes when the request carries a DPoP proof, `approved`.
- **For the server:** `limits`, `server_version`, `capabilities`, `idempotency_retention` (86,400 seconds) and `poll_interval` (60 seconds).
- **ETag.** A strong ETag over the whole body: the SHA-256 of its bytes, base64url, quoted (RFC 9110 section 8.8.3), with `Cache-Control: private, max-age=<poll_interval>` (RFC 9111). `If-None-Match` answers 304. A role change, a new team, a policy or a limit shows on the next poll.

### Pull: `GET /v2/sync/scopes/{scope}/changes?cursor=&limit=`

- **Without a cursor:** a snapshot of the records up to a high-water mark, in pages, then the changes after it in revision order. Both carry tombstones, so a device tells a deletion and a policy tombstone from a record the server never had. A record written after the mark leaves the snapshot and comes as a change.
- **History scope:** the snapshot pages newest first. Each page answers `cursor`, for older entries, and `changes_cursor`, for the changes after the mark. A client takes what its window holds, follows `changes_cursor`, and keeps `cursor` to page back on demand.
- **Each record:** `kind`, `record_id`, `version`, `revision`, `epoch`, `change_tag`, `deleted`, `deleted_reason`, `updated_at`, `taken_at`, `held_until` on a pending reset's records, `updated_by`, `updated_device`, and `fields`, which a tombstone carries only as Tombstones says. A team record adds `updated_by_name` under the facade's rule, for the caller's role at that request: a name, else an address for an owner or admin, else nothing.
- **`taken_at`** is the server's time when it first took the record, as a JSON integer of microseconds since the Unix epoch in UTC, the precision Postgres keeps, and it never changes. A pending reset's 7 days count from it (Resets).
- **The cursor** is opaque. It carries the scope, the epoch, the position, the snapshot's mark, and whether it was issued before the device was approved. It grants nothing: each request checks access itself.
- **422 `cursor_expired`:** a malformed cursor, one from another scope or epoch, one past the horizon, or a pre-approval cursor from an approved device. The client takes a snapshot, and refills when the epoch changed (Restore).
- A cursor of the current epoch past the horizon means the database lost writes and nothing detected it. The server also logs and audits `sync.restore_suspected` for the operator.

### Push: `POST /v2/sync/scopes/{scope}/changes`

```json
{
  "epoch": "<the epoch the client holds>",
  "republish": false,
  "changes": [
    { "kind": "connection", "record_id": "<id>", "op": "patch", "base_tag": "<change tag>", "patch": { } }
  ]
}
```

- 1 to 500 changes, each record named once, with an `Idempotency-Key`.
- **Epoch.** Another epoch than the current one refuses the whole push with 422 `epoch_changed`, so a device that missed a new epoch refills before any of its writes apply.
- **`republish`**, true only on a push that republishes key objects after a new epoch (Republishing). Such a push holds key objects only.
- **Patch.** The RFC 7396 merge patch from the client's base to its record. It applies only when `base_tag` equals the stored record's change tag. No `base_tag` creates the record, and conflicts when the record exists, tombstone included; a create-only key kind answers `create_only` instead. An empty patch writes nothing.
- **Delete.** On the stored tag it tombstones the record. A delete of a record that is absent or already a tombstone answers `applied` and writes nothing.
- **Revive.** A patch on a tombstone's tag revives it, the patch applied to the tombstone's fields (none, outside the team library kinds). Clients send one only where the conflict rules say an edit wins.
- **Outcomes.** The changes are judged in the order sent, in one transaction, and each answers on its own. An applied change commits whatever the others answer, except in a change set (Change sets), which applies whole or not at all.
  - `applied`, with the new `change_tag`, `version` and `revision`;
  - `conflict`, with the stored record's change tag, version, revision and epoch, and whether it is a tombstone, or nothing when the server has no such record. The device pulls the record and merges;
  - `rejected`, with a code.
- **The answer** carries no fields and no writer names, so it stays small and reads the same for every role.

| Rejected code | When |
| --- | --- |
| `bad_kind` | The kind fails the syntax |
| `bad_record_id` | The record id fails the syntax or its kind's grammar |
| `bad_value` | JSON deeper than 32 levels, or a NUL character |
| `secret_key` | A key the secret rule refuses, at any depth (`SecretKey` in tablepro-cloud), in every kind |
| `too_large` | Over 1 MiB once the patch applies |
| `kind_not_in_scope` | A reserved kind outside the scopes the table gives it |
| `role` | The caller's role does not write this kind, or this team key object (Roles in a team scope) |
| `policy` | An install or team policy turns the kind off (Policies) |
| `create_only` | A patch of a `history_entry` other than a revival over a policy tombstone, a patch, a delete or a second create of a create-only key kind, or a republished key object whose bytes differ from the stored one |
| `writer_bound` | A key kind whose writer the binding above does not admit |
| `request_pending` | A second `key.request` from a device whose first is still open |
| `id_case_collision` | A create of a team library kind whose id matches another record of that kind in the team once both are lower-cased, tombstones included. Checked under the team lock |
| `bad_statement` | A key object that fails the server's checks (0056, What the server stores and checks): a signature that does not verify under the signer and `av` it names, an `av` or version that is not one above the current, a genesis while the account has a `key.account`, a reset while another is pending, a `key.recovery` with no certificate at its `av`, a `key.cancel` that names no pending reset's new IK, a wrap whose recipient is not certified or on the roster at the `av` it names, a `key.member` that is not a byte-for-byte copy of its account's `key.account`, or a `key.request` whose `exp` has passed or lies more than 600 seconds after its `iat` |
| `key_version_stale` | `kv` below the scope key's current version |
| `key_version_unknown` | `kv` above the scope key's current version |
| `rotation_due` | A team `secret_envelope` while the team is `rotation_due` (Teams) |
| `quota_exceeded` | A create past the scope's quota; none today |

### Whole-request refusals

| Status | Code | When |
| --- | --- | --- |
| 401 | `use_dpop_nonce` | The server asks for its `DPoP-Nonce` (RFC 9449 section 9) |
| 403 | `feature_required` | A data push to the personal or history scope without `service_sync`, a key-object write without `service_sync` or a seat in a team with `team_library`, or a team push without `team_library`, except key-object writes in a scope that exists after a lapse (Gates) |
| 403 | `seat_required` | A team call without a seat |
| 403 | `license_expired` | A push past `grace_until` that holds anything but key-object writes (Gates) |
| 403 | `device_removed` | A call from a device whose row was removed (Lifecycle and audit). The device locks: it stops syncing, keeps its keys and cancels nothing (0056) |
| 403 | `step_up_required` | A reset from a sign-in with no approved device, or a device row removal from the apps, on a sign-in whose IdP authentication is more than 300 seconds old |
| 403 | `device_not_approved` | A missing or invalid DPoP proof where one is required, or one from a device that is not approved, beyond the reads and writes allowed before approval; a pre-approval call on the history scope |
| 403 | `interactive_sign_in_required` | A personal or history call, or a key-object or envelope write, on a token from a license-key exchange rather than an interactive sign-in |
| 404 | `not_found` | A scope the account cannot reach |
| 409 | `idempotency_in_progress` | The same key while its first request runs |
| 422 | `validation_failed` | A malformed body, a missing `Idempotency-Key`, or a record named twice |
| 422 | `cursor_expired` | Pull, above |
| 422 | `epoch_changed` | Push, above |
| 422 | `idempotency_mismatch` | The same key with another body |
| 429 | `rate_limited` | With `Retry-After` |
| 503 | `restore_check_unavailable` | The restore check cannot run (Restore) |

A role that writes nothing gets `role` per change rather than a whole refusal, since every member writes its own `key.member`.

### Change tags

`change_tag` is base64url without padding (RFC 4648 section 5) of 41 bytes:

| Bytes | Field |
| --- | --- |
| 1 | Format, `0x01` |
| 16 | `written_epoch` |
| 8 | `version`, unsigned big-endian |
| 16 | `write_tag` |

- Clients keep it and send it back as `base_tag`. They never parse it.
- It is the service's tag. The CloudKit change tag a move marker keeps (0054) is another value, held in an inert field the server never reads.
- The server compares it with the stored record's byte for byte. A base from a history the database lost carries random bytes the restored database never had, so it never matches, even when its version comes back.
- The facade keeps comparing `version` until it retires. Its writes draw a new write tag like any other.

### Idempotency

- `Idempotency-Key` (draft-ietf-httpapi-idempotency-key-header) is required on every push: 1 to 255 visible ASCII characters, a UUIDv4 per batch from our clients. The draft has expired, so the semantics are ours and the OpenAPI document states them.
- On every request, replays included, the server authenticates, checks the DPoP proof, the gates and the role before it looks up a stored answer.
- A push that applied at least one change stores, under (account, scope, key) with the SHA-256 of the body and in the same transaction as the writes, the outcomes of the changes it applied. A replay answers those from the store and judges the others again, since they wrote nothing. A push that applied nothing stores nothing, so conflicts and rejections cost no storage, and stored outcomes grow only with the writes themselves.
- The same key and body get the stored answer, another body gets 422 `idempotency_mismatch`, and a retry while the first runs gets 409 `idempotency_in_progress`.
- Answers are kept 24 hours, as advertised, and a daily job prunes them. A client whose batch is older pulls first: its diff against the new bases drops what applied, and it pushes the rest under a new key.

### Rate limits

- 120 requests a minute per sign-in, its refresh token family, and 600 a minute per account across its sign-ins, over all of `/v2`.
- A 429 carries `Retry-After` (RFC 6585). Clients back off exponentially with jitter on 429 and 503 and honor `Retry-After`.
- A device approval polls every 1 to 2 seconds while its sheet is open, inside these limits.

## Keys on the wire

0056 holds the keys, the key objects and the checks. On the wire:

- **DPoP.** Every call on a personal or history scope, and every write of a key kind or a `secret_envelope` in any scope, carries a `DPoP` proof (RFC 9449 section 4.2) beside `Authorization: Bearer`, signed with the device's DSK:
  - `typ` `dpop+jwt`, the DSK's `alg`, and `jwk` with the DSK's public key;
  - `jti`, `htm`, `htu` (no query or fragment), `iat`, and `ath`, the base64url SHA-256 of the access token;
  - `nonce` once the server has sent one.

  The server checks the proof as RFC 9449 section 4.3 lists. `iat` is at most 300 seconds old and at most 60 seconds ahead. Each `jti` is kept, hashed, for 360 seconds in `sync_dpop_jti`, shared by every task (RFC 9449 section 11.1). On clock skew the server asks for its `DPoP-Nonce` (401 `use_dpop_nonce`). This is a profile of RFC 9449: the proof rides beside a bearer token that is not bound to its key, which RFC 9449 section 7 does not cover, and the key binding in check 12 of section 4.3 becomes the approval rule below. The server takes a proof only on these calls, never in place of the bearer, and the Go and Rust sides test it against 0056's vectors.
- **Approved** means the proof's key is the DSK of a device certified at the account's current `av`, on the device row of the token's sign-in, with neither the row removed nor the certificate revoked (0056). In a team scope it is the writing member's own device. A device whose row was removed gets 403 `device_removed`; any other key gets 403 `device_not_approved`.
- **Before approval** a signed-in device:
  - reads only the key kinds of the personal scope, which hold public keys and ciphertext and no plaintext record, so a recovery can open the scope keys it carries forward. Its cursor records that, so after approval it gets `cursor_expired` and takes the whole scope;
  - writes only its `key.request` and that request's `reveal` step, a genesis while the account has no `key.account`, a rotation change set whose `key.account` IK signs, a reset after a step-up, and a `key.cancel` that IK signs. Any other change refuses the push with 403 `device_not_approved`;
  - gets 403 `device_not_approved` on the history scope.
- **Team scopes** take the bearer and the seat for reads and for writes of the library and other plaintext kinds. Key-object and envelope writes there need the DPoP proof above, and team secrets need the account keys, which 0056 gives only to approved devices.
- **Sign Out** revokes the device's own certificate when online: the app sends a DPoP-proved revoke for its own device before it revokes its sign-in, and the server marks the certificate revoked, past grace too. Nothing rotates (0056).
- **Change sets.** A genesis, a rotation and a reset each go up as one push that holds only that change's key objects, as 0056's Account flows list them, and the server applies it whole or not at all. Inside one, the current `av` is the one the set introduces, and IK's signature on its `key.account` authorizes the rest.
  - A genesis applies only while the account has no `key.account` record, from any interactive sign-in: trust on first use. The server keeps an account's newest `key.account` while the account exists (Lifecycle and audit), so once a genesis applies, no later one can.
  - A rotation's `key.account` verifies under the current IK, or, for a replace, under the new IK with the current IK's endorsement. Once it applies, only the devices it certifies are approved.
  - When a rotation or a reset applies, the server marks `rotation_due` each team where the account holds a team key (Teams).
- **Resets.** A reset starts from an approved device, or from a sign-in with no approved device whose IdP authentication is at most 300 seconds old, else 403 `step_up_required`. The app signs in again with `max_age=0`, as the portal's step-up does (0044).
  - Its change set, the `key.account` at `av + 1` under the new IK with the reset mark, the device's own `key.device` and the new `key.recovery`, is held: the server stores each with `held_until` 7 days after its `taken_at`, and the account's current `av` does not move. Pulls serve the held records, so every device shows the reset, and so do the portal and, on the SaaS, an email.
  - At most one reset is pending per account. A second is `bad_statement`.
  - A `key.cancel` at the reset's `av`, naming its new IK, cancels it, from a device certified at the current `av`, or from any device of the account when it carries the IK signature 0056 gives. A device whose row was removed cannot cancel. The server deletes the reset's held records, so a later attempt can take that `av`, and keeps the cancel until the next cancel replaces it. A cancel names one reset's IK, so it never applies to a later one.
  - A rotation while a reset is pending carries that reset's cancel first, in the same change set, since both take `av + 1`.
  - After 7 days with no cancel the server applies it: the records lose `held_until`, their `av` becomes current, and only the resetting device is approved. When that device was not approved as it started the reset, the server deletes at that moment every other record of the account's personal and history scopes (0056), key objects included, so its personal and history keys start again at version 1. The device then writes its scope keys like any approved device.
  - A held reset that comes back through republishing is held 7 days from when the server takes it again, so a restore never shortens the wait.
- **Teams.** Owners and admins manage membership behind the portal's step-up (0044). The server checks 0056's rules on the team's key objects:
  - **Holders.** An account holds a version of the team key at a given `av` when it signed that version's record, or a wrap of that version that a holder signed names it, at an `av` with no reset of the account between it and the given one. A new write is checked at the signer's current `av`, a republished one at the `av` it names.
  - **Versions.** Version 1, and a restart once no member on the roster holds the current version, come only from an owner. Any other version comes from a holder of the version before it. Else `role`.
  - **Confirming.** A wrap to an account that holds no earlier version comes only from an owner or admin, else `role`. The server wraps no key and confirms no member by itself.
  - **`rotation_due`** is set when a member is removed and when a holder's account keys change (Change sets), shown in the scopes body, and cleared when the team's next `key.version` applies. While it is set, team envelopes are refused with `rotation_due`, and apps hold them in their queue.
- **Republishing.** After a new epoch, an approved device of the account, and in a team an approved device of a member, republishes the key objects it holds, byte for byte, whoever signed them, oldest version first, in pushes with `republish` true (0056, Republishing).
  - The server checks each signature under the signer and the `av` the object names, against the certificates it holds, the version step, and that a team version's signer held the version before it at the `av` the record names, or is an owner of the team, as a restart's signer is.
  - It skips the checks against the current `av`, the roster and the role a first wrap needs, and the writer binding to a signer, since those depended on the moment the object was made and no receipt proves it. A republishing push therefore lets no member but a holder or an owner bring in a team version, and clients still check every object (0056).
  - An object identical, byte for byte, to the stored one answers `applied` and writes nothing, so two devices that republish the same objects both succeed. A different one answers `create_only`.
- **Interactive sign-in.** A token from the legacy license-key exchange (`auth_method` `license_key`, 0047) never reaches a personal or history scope and never writes a key object or an envelope, a genesis included, since a shared key would let its holders claim an account's identity before its owner enrolls. They get 403 `interactive_sign_in_required`, as team management already refuses them.
- Access tokens stay bearer tokens; binding them to the DPoP key at the token endpoint comes later.

## Conflict rules

The client merges; the server only versions. This amends 0044's table:

- **Edit against deletion.** When one side deleted a record and the other changed it:
  - a change to a content field revives the record with that change;
  - a change only to placement fields (`sort_order`, the parent or group, `is_favorite`, a folder or table folder membership) never revives it, and the deletion stands.
  - `tablepro-records` marks each field of each kind as content or placement. A field with no mark counts as content, and a test fails on it.
  - The rule holds in the personal scope on both providers: 0054 applies it to CloudKit's `unknownItem`, which ends the shipped resurrection on reorder.
  - In a team scope a content edit against a deletion still opens Keep Mine, which revives, or Keep Theirs. A placement-only edit lets the deletion stand without asking.
- **Other personal fields:** three way per field. A field changed on both sides takes the pushing device's value, as `SyncRecordEdit` does. A move that would close a cycle keeps the server's parent ([0010](0010-macos-on-the-core.md)).
- **`sort_order`:** an integer, as 0010 has it. A renumber is a placement change.
- **Settings:** as 0044 has them.
- **`secret_envelope`:** conditional on its change tag like every record, and written whole, since ciphertext does not merge. Removing a secret deletes its envelope (0056). On a conflict the device pulls the key objects first, then pushes its envelope again on the stored tag under the newest key version, so the later pusher wins. This replaces 0044's unconditional last-pusher-wins.
- **`history_entry`:** created once, never patched. A delete is a tombstone, and a `user` tombstone is final. A policy tombstone is revived by a patch on its tag that carries the whole entry, encrypted at push time under the newest key version like any history push (0056), so the current version rule applies as to any write.
- **`key.*`:** create only, except wraps and rings, which their writer replaces whole, and `key.cancel`, which the next cancel replaces. Two devices that write one version are serialized by create-only: the second gets `create_only`, pulls, and rotates again only if a rotation is still due (0056).

### Tombstones

- A tombstone keeps its ids, version, revision, change tag and writer, and is kept for good, as migration 00010 decided.
- Its fields are cleared, except on the team library kinds, which keep theirs until `/v1` sunsets for its parent walk. `/v2/sync` sends no tombstone's fields.
- **`deleted_reason`**, on every tombstone on the wire:
  - `user`: a client deleted the record. A device deletes its copy, under the conflict rules.
  - `policy`: a policy job tombstoned it, with no writer. A device that pulls it keeps its local copy, whenever it pulls it and whatever policy state it last read, and does not push that kind while the switch stays off. It is no deletion for the rule that a `user` tombstone of a history entry is final (Conflict rules): a device refuses a history id that comes back only after a `user` tombstone.

## Restore

- **New epoch.** `sync new-epoch`, in one transaction for both profiles, audited:
  - adds a `sync_epochs` row with a new random id, and a `sync_epoch_cuts` row with each scope's horizon;
  - moves the revision sequence 2^40 past the database's highest revision, as the facade's epoch does today, which keeps the facade's raw-revision cursors apart; `/v2/sync` compares revisions only within one epoch;
  - adds the facade's `library_epochs` row while the facade lives.
- **Detection.** `sync_install` holds `pg_control_system().system_identifier` and `pg_control_checkpoint().timeline_id`.
  - At `serve` start, before it reports ready and under an advisory lock, the server reads both. No row: it stores them. The same: nothing. Different: it runs the new epoch, audits `sync.restore_detected` and stores the new values, in the same transaction.
  - Every new database connection compares the same values before it serves a request, and waits on the lock while an epoch opens. A database restored behind a running server's address arrives only on new connections, so no request runs on it before its epoch.
  - Archive recovery always starts a new timeline, and a dump restored into a new cluster has a new system identifier ([PostgreSQL, continuous archiving](https://www.postgresql.org/docs/current/continuous-archiving.html)). A promoted standby also starts a timeline, and `pg_upgrade` builds a new cluster: each opens an epoch that costs every device one refill and loses nothing.
  - When the server's role cannot run those functions, `/v2/sync` answers 503 `restore_check_unavailable`, and the log names the grant tablepro-cloud's `operations.md` gives. The facade keeps serving; its restores rest on the runbook, as today.
- **Lost writes.** A device keeps the lineage it last read from the scopes body. Against the server's lineage:
  - the **cut** is the first epoch the server lists after the newest epoch the two lineages share;
  - a base whose `epoch` the server does not list is lost, since its epoch began after the restore point;
  - a base written in the shared epoch is lost when its revision is above the cut's `kept_revision`;
  - a base written in an older epoch survived, since the device refilled it when that epoch ended;
  - a snapshot copy written in the cut's epoch or a later one was written after the recovery.

  Each base is judged against the cut that ended its own history, however many epochs the device missed. A restore that lost epoch rows changes nothing, since no revision is compared across epochs.
- **Refill.** A device that meets a new epoch, through `epoch_changed`, `cursor_expired` or the scopes body, takes the snapshot. Then, for each record its state holds:
  - the snapshot has the same change tag: nothing beyond its own edits;
  - its base is lost and the snapshot copy was not written after the recovery: it pushes its local copy, a deletion included, on the snapshot copy's tag, tombstone or not, or as a create when the snapshot lacks the record;
  - otherwise, a copy another device wrote after the recovery included, the conflict rules apply.
  - Key objects go first: the device republishes the ones it holds (Republishing) before it pushes any other record, so its envelopes meet the scope key versions they were written under.

  It then adopts the epoch. Equal values from two devices are no conflict.
- **Not detected:** a storage snapshot or an in-place `pg_restore` that keeps both values. Pushes stay safe, since no stale tag matches. A device whose cursor new writes passed misses them until the operator runs `sync new-epoch`, which both runbooks require after every restore.

## Policies

The switches are 0044's `passwordSync` and `historySync` and 0055's `personalSync`, on a self-hosted install, all on by default, plus the SaaS team's `password_sync`. Their wire:

| Off | Rejected with `policy` and tombstoned |
| --- | --- |
| `passwordSync` | `secret_envelope` in every scope |
| `historySync` | `history_entry` |
| `personalSync` | Every kind in the personal scope except `key.*`, and `history_entry` |
| A SaaS team's `password_sync` | `secret_envelope` in that team's scope |

- `personalSync` off neither rejects nor tombstones any `key.*` kind, since team secrets and device approval rest on the account's keys and device certificates (0056). Key objects sync whatever personal provider the device uses, so Team Library's envelopes keep working on an install that serves only Team Library. This amends 0055's Off line, which tombstoned every personal and history record.
- When a switch turns off, a job tombstones the records it covers with `deleted_reason: policy` and no writer. Devices keep their copies (Tombstones).
- **`policies` in the scopes body:** the switches that apply to each scope, as booleans, true when on. The personal scope has `personal_sync` and `password_sync`, the history scope `personal_sync` and `history_sync`, and a team scope `password_sync`, the install's and the team's together. Clients stop pushing what is off and shape their UI with it; the server enforces.
- **No provider change.** `personal_sync` false makes TablePro Sync unavailable for personal data on that server, so a device on it stops syncing personal data there, while its key objects keep syncing for Team Library. Neither it, a `policy` answer nor a policy tombstone moves a device to another provider; only the device's own managed policy or the person does (0055).
- **Back on:** devices push their local copies as patches on the policy tombstones' tags, an envelope sealed again and a history entry encrypted again under the newest key version (0056), so a rotation meanwhile holds. The first revives each record and the rest merge.
- A SaaS team's `password_sync` defaults on, follows the `public_links_disabled` pattern, and is set by owners and admins. Every change of any switch is audited.

## Gates

| | Personal, history | Team |
| --- | --- | --- |
| Feature | `service_sync`: SaaS Pro on every cycle, Lifetime included, and Team; self-hosted from the license. Key objects need `service_sync`, or a seat in a team with `team_library`, so a Team Library-only member still has the account keys its team envelopes rest on | `team_library` and a seat |
| Pull | The scope's account, from an approved device; before approval, the key kinds of the personal scope (Keys on the wire) | A seat |
| Push | The feature, an approved device, the policies, within grace | The feature, the role per kind, the policies, within grace |
| Past grace or after a lapse | Pulls, and key-object writes only | Pulls, and key-object writes only |

- **Roles in a team scope.** Every seat reads, and every member writes its own `key.member`. A holder of the current team key, whatever its role, writes the next `key.version`, its `key.ring`, and wraps to the other holders (Teams). Beyond that, owners and admins write every kind, except that version 1 and a restart of the team key come only from an owner, and a first wrap to an account, which confirms it, only from an owner or admin. Editors write the library, the other plaintext kinds and `secret_envelope`. Members write nothing else. Key-object and envelope writes also need an approved device (Keys on the wire), and team envelopes wait while the team is `rotation_due`.
- The server checks the gates on every call. The app's gate only shapes the UI.
- **Pull-only for data, in both deploys.** Past `grace_until` on a self-hosted install, and once a SaaS plan stops granting the feature, a scope that exists keeps answering pulls.
  - **Still taken** in a scope that exists, under every other rule (approval, role, writer binding, change sets): creates of every key kind, replacements of `key.wrap`, `key.ring` and `key.cancel`, in the personal and team scopes, and a device's revoke of its own certificate. That covers Sign Out, approving a device, removing a stolen one with its rotation, a recovery, a reset and its cancel, and a new team key after a member's removal. The maintainer decided this on 2026-11-25, so a lapsed account can still lock a lost device out.
  - **Refused:** a push that holds any other change, every data kind, `secret_envelope` and `history_entry` included, is refused whole with 403 `license_expired` past `grace_until`, or `feature_required` after a SaaS lapse.
  - `LapsedFeature` in tablepro-cloud and `KEPT_PAST_GRACE` in `tablepro-account` become that state for `service_sync` and `team_library` alike. This amends 0047's Expiry line, which kept only `team_library`.
- The facade keeps its own gates, `team_library` on pulls included.

## What syncs

0044's lists stand, with these rules for fields and runs it left open:

- **History.** Every run the app records becomes an entry, whatever started it. Rewind and plan snapshots stay on the device, and so does the history of a Local only connection.
- **Scripts.** Pre-connect and post-connect scripts and beancount ledger plugins are approval-required in the personal scope and still ask at connect. A team scope drops them on pull, as it drops startup SQL.
- **External Clients.** A connection's External Clients level ([0036](0036-mcp-and-the-command-line-through-the-ffi.md)) syncs, and a looser value is approval-required.
- **Column layouts** (`columnLayout.<key>` in a settings kind) sync as inert.
- **Wire schemas.** Each kind has an explicit wire schema in `tablepro-records`, and every key in it passes the server's secret rule, so no field the apps keep is refused for its name.
- **Move markers.** The move marker 0054 writes on a record moved from iCloud is an inert reserved field like any other: the server never reads it, clients patch around it, and a facade write keeps it.

## The library moves in

**R1, one expand migration.**

1. New tables: `sync_scopes`, `sync_records`, `sync_idempotency`, `sync_dpop_jti`, `sync_install` and `install_policies`, and `teams.password_sync`, default true.
2. Every library row goes into `sync_records` as a `library_connection`, `library_folder` or `library_query` record, for the facade's `connection`, `folder` and `query`, with its `client_id` as the record id, byte for byte in its stored case, its `id`, `revision`, `version`, writers and `updated_via`, a random write tag and the current epoch as its written epoch.
   - A folder's columns become `name`, `parent_client_id` and `sort_order`; a query's become `name`, `query`, `keyword`, `folder_client_id`, `connection_client_id` and `sort_order` (0044).
   - `library_epochs` and `library_epoch_horizons` become `sync_epochs` and `sync_epoch_cuts` rows with their ids, start revisions and team horizons. Without any, R1 adds a first epoch with `start_revision` 1.
3. The three tables are renamed aside, and views `library_connections`, `library_folders` and `library_queries` over `sync_records` take their names, with INSTEAD OF INSERT and UPDATE triggers.
   - The triggers map columns to `fields` and back, set `revision` on insert since a view has no default, draw a new write tag, keep every key the facade does not carry, and create the team's scope when it has none, under the team lock N-1 already holds. No other rule lives in PL/pgSQL. The horizon needs no trigger, since it is read from the records.
   - N-1's SQL runs unchanged on the views: `items.sql` uses no `ON CONFLICT` or `FOR UPDATE`, and sqlc spelled out every column.
   - The only foreign key into the library tables is `library_epoch_horizons` to `library_epochs`, so the renames break none.

- **Lock order.** N-1 holds the account, then the team row `for no key update`, and takes `nextval('library_revision')` in its `SET` before any trigger runs (`internal/library/usecase/service.go`, `items.sql`). Until R2, every team-scope write of N takes the same two locks in that order, then the `sync_scopes` row, and calls `nextval` only after them. Commit order then equals revision order per team for both releases, and no cursor skips.
- **Code.** N reads and writes only `sync_records`. `internal/sync` replaces `internal/library`, whose facade, portal library and `/v1` use cases become its adapters. Both profiles' module sets (`cmd/tablepro-cloud/modules.go`) name `sync` in its place.
- **R2, the next minor:** drop the views and the renamed tables, and rename the sequence `sync_revision`. A self-hosted install upgrades one minor at a time, so it always passes through R1.
- This is "Merge Tables" with a transition period (Ambler and Sadalage, *Refactoring Databases*), with views and INSTEAD OF triggers as the synchronization.

## The facade

- `/v2/teams/{id}/library/changes` keeps its documented behavior for shipped Macs:
  - the change and result shapes;
  - `applied` and `conflict` only, compared on `base_version`;
  - a whole-push 422 on a bad change, which now also covers a create whose client id matches another of that kind in the team once lower-cased (`id_case_collision` on `/v2/sync`);
  - 403 `feature_required`, `library_write_forbidden` and `license_expired`;
  - any 422 on a pull meaning a new snapshot;
  - its sequence-gap epoch.
- A facade write sets the keys it carries and keeps every other key, for all three kinds. For a connection those are the bundle keys of `ExportableConnection`; for folders and queries, the keys above. Team records can therefore gain fields while 0.88 and 0.89 are in use, and no key is frozen.
- **Retirement.** A daily job works out, per install, the share of devices that read a team library in the last 30 days on a build without the core client, from `devices.app_version`. Once it stays under 2% for 30 days, the facade answers 410 with an update message. The portal shows the share.
- When the facade retires, the sequence-gap epoch tables go. When `/v1` sunsets, library tombstones lose their fields.

## Lifecycle and audit

- **Account deletion** deletes its personal and history scopes with every record in them, envelopes and key objects included. It clears `updated_by` and `updated_device` on its team records, tombstones included.
- **A self-hosted member removal** sets `purges_at` 30 days out on that person's personal and history scopes. Restoring the member within that time clears it, and a job then deletes the scopes' records, key objects included, except the newest `key.account`. It holds only public keys, and a person who comes back then continues at the next `av` through a reset, never a second genesis, which would reuse `av`s that teammates pinned and `key.member` copies name.
- **A team its owner deletes** hides its scope at once. Restore and purge follow the team's (migration 00013).
- **Key objects.** The server purges `key.request` and `key.sas` records once they expire, deletes a cancelled reset's held records, and deletes each `key.recovery` older than the current `av` once a newer certificate applies (0056). When a reset started from a device that was not approved applies, and not before, it deletes every other record of the account's personal and history scopes (Resets).
- **Removals.** Removing a member from a team marks it `rotation_due`. A device row of an account with keys is removed one of two ways (0056, Removing a device):
  - **from the apps,** with a DPoP proof from an approved device and an IdP sign-in at most 300 seconds old, else `step_up_required`;
  - **from the portal,** by an install admin behind the portal's step-up (0044), since the browser holds no keys.

  Either way the server revokes the row's refresh token family and its certificate at once; the removal is audited, and every device of the account is told. Neither way changes keys: the account's keys rotate once the person types the recovery key on a device (0056), and the row's device gets `device_removed`.
- **Audit:**
  - team writes, as counts per push, `library.changed` as today, for both paths;
  - policy changes and policy tombstone runs, purges and their cancels, epochs, `sync.restore_detected` and `sync.restore_suspected`;
  - key events: a genesis, a rotation, a replace, a reset pending, cancelled and applied, a device approved, signed out and removed, a member confirmed and removed, a team key rotation and a team restart, which the portal also shows;
  - personal and history writes are not audited;
  - the portal gains an install audit page for the owner and admins, for events that belong to no team.

## Releases

- **iOS** reaches the server in two releases: the first reads an unknown device platform safely and adds the `tablepro-ios` client, and the next writes `ios`, which counts toward the SaaS 3-device cap.
- **Version skew** stays as 0044 has it. A server with no `/v2/sync` answers 404 to `GET /v2/sync/scopes`, and the app says the server is too old.
- **The first self-hosted release**, which 0044's gates name, is the first tablepro-cloud image whose `/v2/sync` carries end-to-end envelopes. The 0.1.x images are the preview.

## Tests

- **Upgrade:** N-1 writes through the facade while N writes `/v2/sync` on one team, concurrently, and no cursor skips. N-1 alone writes, then N snapshots and pulls. The migration keeps ids, revisions, versions and writers. N-1's queries run on the views.
- **Facade:** fixtures recorded from 0.88 and 0.89, kept and dropped keys included. `/v1` golden fixtures 046-065 and 089-093 stay unchanged.
- **Restore:** a dump into a new cluster, a point-in-time restore, and a storage snapshot that changes neither value, each with two clients that refill and converge. A restore, new writes, a failover, then a device offline through both refills its lost write. Two epochs seconds apart, then a restore of a backup older than both, and the device refills its writes from the lost epochs. A device that comes back after another refilled a record and then edited or deleted it keeps that edit or deletion. A database swapped behind a running server serves nothing before its epoch. A policy turned off and on across an epoch while a device is offline keeps that device's copies. Another device of the account republishes the certificate of a device approved after the backup, and two devices republishing the same key objects both succeed.
- **Protocol:** every outcome and refusal; stale tags across an epoch; pushes of 500 conflicts store nothing; idempotent replays, mismatches and concurrent retries; page caps by count and bytes; the history order and paging back; a 304 on an idle poll and a new ETag after a role, team or limit change; rate limits.
- **Past grace:** a Sign Out revoke, a rotation change set and a team key rotation are taken; a push with any data change, an envelope or a history entry is refused whole with `license_expired`, and with `feature_required` after a SaaS lapse.
- **History back on:** entries kept through `historySync` off revive over their policy tombstones under the newest key version, and a `user` tombstone stays final.
- **Gates and policies:** the gate matrix across free, Pro monthly, annual and Lifetime, Team, self-hosted with and without `service_sync`, and past grace; roles per kind; each switch off and on again; the policy tombstone job.
- **Approval:** DPoP with each field wrong, a replay, a key not certified at the current `av` and an expired `iat`; a team envelope or key-object write without an approved device; each check of 0056's table, passing and failing; an `av` or version that skips or repeats; an envelope `kv` below and above the current version; a team envelope while `rotation_due`, refused, and taken once the next version applies; a genesis, rotation or reset change set with one bad object, which applies nothing; a genesis while the account has a `key.account`; a second pending reset; a reset from a sign-in with no approved device and no fresh sign-in; a reset cancelled by a certified device and by an IK-signed cancel; a cancel replayed against a later reset at the same `av`, and one from a removed row's device, both refused; a rotation while a reset is pending, carrying its cancel; a reset applied after 7 days that approves only its device, and one started by a device that was not approved, which deletes the other personal and history records; a held reset republished after a restore, held 7 days again; a team version 1 or a restart from an admin, a restart while a holder is on the roster, a version from a member that holds no wrap of the current one, a version from the signer of the current one after that signer's reset, and a first wrap to an account from an editor, each refused; a sole holder's reset, after which an owner restarts the team; a version republished after a restore that also lost its signer's later reset, taken; republished objects taken whoever signed them, identical ones applied and different ones `create_only`; each row of the writer binding, and the binding to a signer skipped when republishing; a `key.member` that is not a byte-for-byte copy; a removed row's device getting `device_removed` for every call; a Sign Out revoke that leaves no rotation; a Team Library-only account creating its keys; what an unapproved device reads and writes; the cursor after approval; an idempotent replay after the caller's role changed; a license-key token that tries a genesis or reads a personal scope.
- **Merge:** shared fixtures for content against placement edits on a deletion, run by the CloudKit and the service paths.

## Consequences

- A new kind still needs no server release. Only reserved kinds carry rules.
- Shipped Macs see no change until the facade retires.
- Clients hold change tags, not versions, as the precondition of a write.
- An install whose Postgres role cannot read the control data needs a grant before `/v2/sync` serves.
- A failover or a major Postgres upgrade costs every device one refill.
- A restore that lost a rotation lets the server treat the devices it left out as approved again until a device of the account republishes the rotation. Clients keep the newest `av` they verified and refuse anything older (0056, Rollback).
- A snapshot carries every tombstone's ids, so a new device downloads them with the live records.
- The server reads key versions and verifies key-object signatures. The threat model lists what that tells it (0056).
- Past grace, apps keep pulling personal and history data as well as the team's, and write only key objects: a device still signs out, and a person can still remove a stolen device and rotate. A device approved then can only pull until the license is renewed.

## Alternatives considered

- **Versions as the precondition, with the restore runbook (0044).** A restore issues versions again, and a missed runbook step lets a stale patch apply with no merge.
- **Refuse `/v2/sync` on a detected restore until an operator runs `sync new-epoch`.** Safe, but a routine failover would stop every device until someone acts. The maintainer chose the automatic epoch.
- **Detection without change tags.** A storage snapshot keeps both values, so detection alone misses it.
- **A counter for the epoch.** A restore would issue the same epoch again.
- **Ordering epochs by revision ranges or by the clock.** A restore can lose an epoch's rows, and two epochs minutes apart can then overlap in either order.
- **One `epoch_revision` per scope (0044).** A device that missed two epochs would be judged against the newest cut, which can lie above its lost writes.
- **An identity check on a timer.** A restored database behind a running server would take writes until the next check, and those writes would lift the cut above the lost history.
- **Snapshots of live records only.** A device that missed a policy tombstone could not tell it from a deletion and would drop the copy it is meant to keep.
- **Endpoints of their own for key objects.** A second cursor and a second restore story beside the records.
- **A deletion that always wins, or an edit that always revives.** The first loses edits made offline; the second brings deleted siblings back on every reorder.
- **An ETag over epochs, horizons and policies only.** A 304 would hide a role change or a new team.
- **A per-device sequence for idempotency (Replicache).** Each device keeps a counter per scope that a reinstall or a restored device resets. A key with a stored answer needs nothing beyond the batch on the client.
- **Freezing team connection keys while the facade lives.** The facade keeping unknown keys already lets them grow.
- **Clearing library tombstones' fields now.** `/v1` publish still walks a deleted folder's parent.
- **A whole-request refusal for a scope a policy turns off.** One per-change `policy` serves all three switches and leaves pulls and the key kinds working.
- **256 KiB a record.** A move from iCloud, whose limit is 1 MiB, would drop records.
