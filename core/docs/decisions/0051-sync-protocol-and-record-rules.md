# 0051: Sync protocol and record rules

- **Status**: Accepted; amends 0044 and 0047
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
- A new device gets nothing personal until another device or the recovery key approves it, and the server enforces that (0053).
- Content edits revive a deleted record. Placement changes never do.
- The server detects a restore from Postgres's system identifier and timeline and opens a new epoch itself. It refuses `/v2/sync` only when it cannot run that check. The version check carries the epoch.
- The facade lives until fewer than 2% of Team Library devices run older builds for 30 days. Team connection keys are not frozen meanwhile.
- A self-hosted `personalSync` switch (0055).

## Decision

`/v2/sync` serves records from one table, `sync_records`, in the scopes `sync_scopes` holds. Every write is conditional on an opaque change tag that carries the epoch, the version and a random write tag, so no stale base matches after a restore, and a push names the epoch it was built in. Each change answers on its own. Kinds are open except a reserved set: `key.*`, `secret_envelope`, `history_entry` and the three library kinds. The server reads no field but a key version and the keys the facade projects, and verifies the signatures on the account logs. Content edits revive a deleted record; placement edits never do. The server checks the database's identity before it serves on any connection, and a restore opens a new epoch whose cut tells each device which of its writes the server lost. Past grace every sync feature is pull-only. The library's tables move into the store in one expand release behind views, and the facade keeps its documented behavior until the maintainer's 2% threshold.

## Scopes and records

**`sync_scopes`**: `id`, `type` (`personal`, `history` or `team`), `account_id` or `team_id`, `min_key_version`, `purges_at`, `created_at`.

- One personal and one history scope per account, one scope per team.
- A scope's horizon is its highest committed revision, read through the (`scope_id`, `revision`) index, so every write path keeps it, the facade's included. It replaces the library's maximum over three tables.
- Writers lock the scope's row. The personal and history scopes of an account lock under the account hold, a team's under the team hold.
- `min_key_version` is the floor that removals raise (0053). The personal and history scopes of an account move together.
- On the wire a scope is `personal`, `history` or the team's TypeID (`team_...`), as the facade names teams.
- A scope is created by its first write, under its owner's lock. Before that, `GET /v2/sync/scopes` lists it with a horizon of 0, and a pull answers an empty page with no cursor.

**Epochs** are install-wide, as the facade's are.

- `sync_epochs`: `id`, a random UUID, never a counter, since a restore would issue a counter again; `start_revision`, where the epoch moved the revision sequence; `started_at`; and why it began. Within the lineage a database holds, each epoch's `start_revision` is above the one before, which gives the order.
- `sync_epoch_cuts`: per epoch and scope, `kept_revision`, the highest revision of the epoch before it that the scope still held when it began. A scope with no row kept nothing.
- The current epoch is the last of the lineage. A write records it as its `written_epoch`, and a record shows it as `epoch`.

**`sync_records`**: `scope_id`, `kind`, `record_id`, `id`, `version`, `revision`, `written_epoch`, `write_tag`, `fields` (jsonb), `deleted_at`, `deleted_reason`, `created_by`, `created_at`, `updated_by`, `updated_device`, `updated_via`, `updated_at`.

- The key is (`scope_id`, `kind`, `record_id`), with an index on (`scope_id`, `revision`).
- `id` is a uuidv7, unique: `/v1` names connections by it and the portal pages by it.
- `version` goes up by one with every write, through either path. `revision` comes from one sequence, `library_revision` until R2 renames it `sync_revision`.
- `written_epoch` is the epoch current at the write, and `write_tag` is 16 bytes from the OS's CSPRNG drawn by each write.
- `deleted_reason` is `user` or `policy`. `updated_device` references `devices` and is set null when the device goes.

### Kinds

- **Syntax.** Lowercase ASCII letters, digits and `_`, starting with a letter, with at most one `.` between two such parts, 1 to 64 bytes.
- **Record ids.** 1 to 255 UTF-16 code units with no control character, plus the grammar 0052 gives the kind.
- **Reserved:** every `key.*` kind, `secret_envelope`, `history_entry`, `library_connection`, `library_folder` and `library_query`. Any other kind that passes the syntax is an ordinary kind in the personal and team scopes, so a new data kind still needs no server release.

| Kind | Scopes | Who writes | Server rule |
| --- | --- | --- | --- |
| `connection`, `group`, `tag`, `ssh_profile`, `credential_profile`, `saved_query`, `saved_query_folder`, `favourite_table`, `favourite_database`, `table_folder`, `table_folder_item`, `macos_settings`, `ios_settings`, `linux_settings`, `windows_settings`, and `connection_project` once #4376 ships | personal | The account's approved key holders | Patch and delete |
| `library_connection`, `library_folder`, `library_query` | team | Owner, admin, editor | Patch and delete, also through the facade. The keys the facade projects are checked. Tombstones keep their fields until `/v1` sunsets |
| `secret_envelope` | personal, team | Personal: approved key holders. Team: owner, admin, editor, from an approved key holder | Patch and delete, written whole. `kv` is checked against the floor |
| `history_entry` | history | Approved key holders | Created once; a delete tombstones it. `kv` is checked against the floor |
| `key.identity`, `key.device` | personal | The signers 0053 names | Create only. Each append is verified, and the server derives the account's device set from the two logs |
| `key.recovery` | personal | The account's approved key holders, and the genesis | Create only. Its hash must be the blob an identity statement names |
| `key.request` | personal | Any key holder of the account, approved or not | Create only, bound to the DPoP key that writes it, purged once it expires |
| `key.sas` | personal, team | The party of each step | Create only, purged once its session expires |
| `key.wrap`, `key.ring` | personal, team | Personal: the account's approved key holders. Team: the signer 0053 names | Written whole; only that writer replaces one |
| `key.team` | team | Owner, admin | Create only. Each append is verified against the signer's verified identity log |
| `key.member` | team | The member it names, in any role | Create only, writer-bound to that account, and byte for byte the account's `key.identity` record at that `seq` |
| Any other kind | personal, team | Personal: approved key holders. Team: owner, admin, editor | Patch and delete |

- A reserved kind in a scope the table does not give it is rejected with `kind_not_in_scope`. The history scope takes only `history_entry`.
- **What the server reads.**
  - `kv`, the key version on `secret_envelope` and `history_entry`.
  - Key-object fields, only as 0053's Key objects table lists: it verifies each account and team log append, checks a `key.recovery` blob's hash and a `key.member` copy's bytes, binds a `key.request` to its writer's DPoP key, and checks who writes a wrap or a ring.
  - While the facade lives, the keys it projects from a library record into typed columns: a folder's and a query's, checked after the patch as `ParseData` checks them today (required names and query text, client ids, an int32 `sort_order`), else `bad_value`. Other keys of a library record stay unread.
  - No other field of any kind.

### Limits

- 1 MiB a record, measured as the library measures, on `fields` encoded without HTML escaping. A record over it stays on its device and is listed with a notice.
- 4 MiB a body and 500 changes a push. Clients split pushes by bytes as well as by count.
- A page stops at `limit` records, at most 500, or at 4 MiB of records, whichever comes first, and always holds one record.
- JSON at most 32 levels deep, no NUL character anywhere, and no JSON null in stored fields (a null in a patch removes the member, RFC 7396).
- Each scope advertises `quota`, null today. A create past a quota would be rejected `quota_exceeded`, which clients handle from the start, so a later quota needs no app release.
- The SaaS's nginx lets 5 MiB through on `/v2/sync/scopes/*/changes`.

## Protocol

Under `/v2`, OAuth scope `app`, with clients generated from the OpenAPI document. Errors are RFC 9457 problem details.

### `GET /v2/sync/scopes`

- **The epoch:** `epoch`, the current epoch's id.
- **Per scope:** `id`, `type`, `team` for a team scope, `role`, `horizon`, `epochs` (the lineage, oldest first, each epoch's id with the scope's `kept_revision`, 0 when it has no cut), `writable` (false past grace or after a lapse), the policies that apply to it, `quota`, and, for the personal and history scopes when the request carries a DPoP proof, `approved`.
- **For the server:** `limits`, `server_version`, `capabilities`, `idempotency_retention` (86,400 seconds) and `poll_interval` (60 seconds).
- **ETag.** A strong ETag over the whole body: the SHA-256 of its bytes, base64url, quoted (RFC 9110 section 8.8.3), with `Cache-Control: private, max-age=<poll_interval>` (RFC 9111). `If-None-Match` answers 304. A role change, a new team, a policy or a limit shows on the next poll.

### Pull: `GET /v2/sync/scopes/{scope}/changes?cursor=&limit=`

- **Without a cursor:** a snapshot of the records up to a high-water mark, in pages, then the changes after it in revision order. Both carry tombstones, so a device tells a deletion and a policy tombstone from a record the server never had. A record written after the mark leaves the snapshot and comes as a change.
- **History scope:** the snapshot pages newest first. Each page answers `cursor`, for older entries, and `changes_cursor`, for the changes after the mark. A client takes what its window holds, follows `changes_cursor`, and keeps `cursor` to page back on demand.
- **Each record:** `kind`, `record_id`, `version`, `revision`, `epoch`, `change_tag`, `deleted`, `deleted_reason`, `updated_at`, `updated_by`, `updated_device`, and `fields`, which a tombstone never carries. A team record adds `updated_by_name` under the facade's rule, for the caller's role at that request: a name, else an address for an owner or admin, else nothing.
- **The cursor** is opaque. It carries the scope, the epoch, the position, the snapshot's mark, and whether it was issued before the key holder was approved. It grants nothing: each request checks access itself.
- **422 `cursor_expired`:** a malformed cursor, one from another scope or epoch, one past the horizon, or a pre-approval cursor from an approved holder. The client takes a snapshot, and refills when the epoch changed (Restore).
- A cursor of the current epoch past the horizon means the database lost writes and nothing detected it. The server also logs and audits `sync.restore_suspected` for the operator.

### Push: `POST /v2/sync/scopes/{scope}/changes`

```json
{
  "epoch": "<the epoch the client holds>",
  "changes": [
    { "kind": "connection", "record_id": "<id>", "op": "patch", "base_tag": "<change tag>", "patch": { } }
  ]
}
```

- 1 to 500 changes, each record named once, with an `Idempotency-Key`.
- **Epoch.** Another epoch than the current one refuses the whole push with 422 `epoch_changed`, so a device that missed a new epoch refills before any of its writes apply.
- **Patch.** The RFC 7396 merge patch from the client's base to its record. It applies only when `base_tag` equals the stored record's change tag. No `base_tag` creates the record, and conflicts when the record exists, tombstone included; a create-only key kind answers `create_only` instead. An empty patch writes nothing.
- **Delete.** On the stored tag it tombstones the record. A delete of a record that is absent or already a tombstone answers `applied` and writes nothing.
- **Revive.** A patch on a tombstone's tag revives it, the patch applied to the tombstone's fields (none, outside the library kinds). Clients send one only where the conflict rules say an edit wins.
- **Outcomes.** The changes are judged in the order sent, in one transaction, and each answers on its own. An applied change commits whatever the others answer.
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
| `role` | The caller's role does not write this kind |
| `policy` | An install or team policy turns the kind off (Policies) |
| `create_only` | A patch of `history_entry`, or a patch, a delete or a second create of a create-only key kind |
| `writer_bound` | The record id names another account or DPoP key |
| `bad_statement` | A `key.identity`, `key.device` or `key.team` append that does not verify, a genesis or reset the account's state does not allow, a `key.member` that does not copy its identity record, or a `key.recovery` whose hash no identity statement names |
| `key_version_stale` | `kv` below the scope's floor |
| `quota_exceeded` | A create past the scope's quota; none today |

### Whole-request refusals

| Status | Code | When |
| --- | --- | --- |
| 401 | `use_dpop_nonce` | The server asks for its `DPoP-Nonce` (RFC 9449 section 9) |
| 403 | `feature_required` | A push without `service_sync` (personal, history) or `team_library` (team) |
| 403 | `seat_required` | A team call without a seat |
| 403 | `license_expired` | A push past `grace_until` |
| 403 | `device_not_approved` | A missing or invalid DPoP proof where one is required, or one from a key outside the writer's device set, beyond the writes allowed before approval; a pre-approval call on the history scope |
| 403 | `interactive_sign_in_required` | A personal or history call, or a key-object or envelope write, on a token from a license-key exchange rather than an interactive sign-in |
| 404 | `not_found` | A scope the account cannot reach |
| 409 | `idempotency_in_progress` | The same key while its first request runs |
| 422 | `validation_failed` | A malformed body, a missing `Idempotency-Key`, or a record named twice |
| 422 | `cursor_expired` | Pull, above |
| 422 | `epoch_changed` | Push, above |
| 422 | `idempotency_mismatch` | The same key with another body |
| 429 | `rate_limited` | With `Retry-After` |
| 503 | `restore_check_unavailable` | The restore check cannot run (Restore) |

A role that writes nothing gets `role` per change rather than a whole refusal, since every member writes its own `key.member` and `key.sas` steps.

### Change tags

`change_tag` is base64url without padding (RFC 4648 section 5) of 41 bytes:

| Bytes | Field |
| --- | --- |
| 1 | Format, `0x01` |
| 16 | `written_epoch` |
| 8 | `version`, unsigned big-endian |
| 16 | `write_tag` |

- Clients keep it and send it back as `base_tag`. They never parse it.
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

## Device approval on the wire

0053 holds the keys, the logs and the checks. On the wire:

- **DPoP.** Every call on a personal or history scope, and every write of a key kind or a `secret_envelope` in any scope, carries a `DPoP` proof (RFC 9449 section 4) beside `Authorization: Bearer`. 0053 gives the proof's fields and time windows. The `jti` store is `sync_dpop_jti`, shared by every task, and the server may ask for its `DPoP-Nonce` (401 `use_dpop_nonce`).
- **Approved** means the proof's key is a holder in the writing account's device set, on the device row of the token's sign-in. The set is what the verified logs give, less the holders of device rows an admin removed and every holder those approved. In a team scope it is the writing member's own set. Anything else is 403 `device_not_approved`.
- **Before approval** a holder:
  - reads from the personal scope only `key.identity`, `key.device`, `key.recovery`, its own `key.request` and the `key.sas` steps of that request. Its cursor records that, so after approval it gets `cursor_expired` and takes the whole scope;
  - writes only its `key.request` and that request's `reveal` step, an `add` with method `recovery` that verifies under the current identity key and names its own DPoP key, and, while the account has no identity log or an empty device set, the genesis or reset records that name itself. The first enrollment is trust on first use. Any other change refuses the push with 403 `device_not_approved`;
  - gets 403 `device_not_approved` on the history scope.
- **Team scopes** take the bearer and the seat for reads and for writes of the library and other plaintext kinds. Key-object and envelope writes there need the DPoP proof above, and team secrets need the sharing key 0053 gives only to approved holders.
- **Interactive sign-in.** A token from the legacy license-key exchange (`auth_method` `license_key`, 0047) never reaches a personal or history scope and never writes a key object or an envelope, since a shared key would let its holders claim an account's identity before its owner enrolls. They get 403 `interactive_sign_in_required`, as team management already refuses them.
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
- **`secret_envelope`:** conditional on its change tag like every record, and written whole, since ciphertext does not merge. On a conflict the device pulls the key objects first, then pushes its envelope again on the stored tag under the newest key version, so the later pusher wins. This replaces 0044's unconditional last-pusher-wins.
- **`history_entry`:** created once, never patched. A delete is a tombstone. It is revived only over a policy tombstone.
- **`key.*`:** create only, except wraps and rings, which their writer replaces whole. Two writers of one log position are serialized by `create_only`, and the loser reads the log and builds on it (0053).

### Tombstones

- A tombstone keeps its ids, version, revision, change tag and writer, and is kept for good, as migration 00010 decided.
- Its fields are cleared, except on the library kinds, which keep theirs until `/v1` sunsets for its parent walk. `/v2/sync` never sends a tombstone's fields.
- `deleted_reason` is `user` for a client's delete and `policy` for a policy's, which has no writer. A device keeps its local copy on a policy tombstone.

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

- `personalSync` off keeps the `key.*` kinds, since team secrets and device approval rest on the account's identity, device log and sharing key.
- When a switch turns off, a job tombstones the records it covers with `deleted_reason: policy` and no writer. Devices keep their copies.
- `GET /v2/sync/scopes` gives each scope the policies that apply to it. Clients stop pushing what is off and shape their UI with it; the server enforces.
- **Back on:** devices push their local copies as patches on the policy tombstones' tags. The first revives each record and the rest merge.
- A SaaS team's `password_sync` defaults on, follows the `public_links_disabled` pattern, and is set by owners and admins. Every change of any switch is audited.

## Gates

| | Personal, history | Team |
| --- | --- | --- |
| Feature | `service_sync`: SaaS Pro on every cycle, Lifetime included, and Team; self-hosted from the license | `team_library` and a seat |
| Pull | The scope's account, from an approved key holder; before approval, the key kinds Device approval lists | A seat |
| Push | The feature, an approved key holder, the policies, within grace | The feature, the role per kind, the policies, within grace |
| Past grace or after a lapse | Pull-only | Pull-only |

- **Roles in a team scope.** Owners and admins write every kind. Editors write every kind except the signer kinds: `key.team`, and team wraps and rings. Members write only their own `key.member` and their `key.sas` steps. Every seat reads. Key-object and envelope writes also need an approved key holder (Device approval on the wire).
- The server checks the gates on every call. The app's gate only shapes the UI.
- **Pull-only, in both deploys.** Past `grace_until` on a self-hosted install, and once a SaaS plan stops granting the feature, a scope that exists keeps answering pulls, and pushes get `license_expired` or `feature_required`. `LapsedFeature` in tablepro-cloud and `KEPT_PAST_GRACE` in `tablepro-account` become that state for `service_sync` and `team_library` alike. This amends 0047's Expiry line, which kept only `team_library`.
- The facade keeps its own gates, `team_library` on pulls included.

## What syncs

0044's lists stand, with these rules for fields and runs it left open:

- **History.** Every run the app records becomes an entry, whatever started it. Rewind and plan snapshots stay on the device, and so does the history of a Local only connection.
- **Scripts.** Pre-connect and post-connect scripts and beancount ledger plugins are approval-required in the personal scope and still ask at connect. A team scope drops them on pull, as it drops startup SQL.
- **External Clients.** A connection's External Clients level ([0036](0036-mcp-and-the-command-line-through-the-ffi.md)) syncs, and a looser value is approval-required.
- **Column layouts** (`columnLayout.<key>` in a settings kind) sync as inert.
- **Wire schemas.** Each kind has an explicit wire schema in `tablepro-records`, and every key in it passes the server's secret rule, so no field the apps keep is refused for its name.

## The library moves in

**R1, one expand migration.**

1. New tables: `sync_scopes`, `sync_records`, `sync_idempotency`, `sync_dpop_jti`, `sync_install` and `install_policies`, and `teams.password_sync`, default true.
2. Every library row goes into `sync_records` as a `library_*` record with its `id`, `revision`, `version`, writers and `updated_via`, a random write tag and the current epoch as its written epoch.
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
  - a whole-push 422 on a bad change;
  - 403 `feature_required`, `library_write_forbidden` and `license_expired`;
  - any 422 on a pull meaning a new snapshot;
  - its sequence-gap epoch.
- A facade write sets the keys it carries and keeps every other key, for all three kinds. For a connection those are the bundle keys of `ExportableConnection`; for folders and queries, the keys above. Team records can therefore gain fields while 0.88 and 0.89 are in use, and no key is frozen.
- **Retirement.** A daily job works out, per install, the share of devices that read a team library in the last 30 days on a build without the core client, from `devices.app_version`. Once it stays under 2% for 30 days, the facade answers 410 with an update message. The portal shows the share.
- When the facade retires, the sequence-gap epoch tables go. When `/v1` sunsets, library tombstones lose their fields.

## Lifecycle and audit

- **Account deletion** deletes its personal and history scopes with every record in them, envelopes and key objects included. It clears `updated_by` and `updated_device` on its team records, tombstones included.
- **A self-hosted member removal** sets `purges_at` 30 days out on that person's personal and history scopes. Restoring the member within that time clears it, and a job deletes the scopes that come due.
- **A team its owner deletes** hides its scope at once. Restore and purge follow the team's (migration 00013).
- **Key objects.** The server purges `key.request` and `key.sas` records once they expire. A reset of an account with no key holder left first deletes its personal and history records (0053).
- **Removals.** Removing a member from a team raises that team's floor. On a self-hosted install, an install admin can remove a device in the portal: that revokes its refresh token family, marks its key holders revoked and raises the person's floors (0053).
- **Audit:**
  - team writes, as counts per push, `library.changed` as today, for both paths;
  - policy changes and policy tombstone runs, purges and their cancels, epochs, `sync.restore_detected` and `sync.restore_suspected`;
  - key events: genesis, identity reset, device added, left and removed, member confirmed and removed, re-root;
  - personal and history writes are not audited;
  - the portal gains an install audit page for the owner and admins, for events that belong to no team.

## Releases

- **iOS** reaches the server in two releases: the first reads an unknown device platform safely and adds the `tablepro-ios` client, and the next writes `ios`, which counts toward the SaaS 3-device cap.
- **Version skew** stays as 0044 has it. A server with no `/v2/sync` answers 404 to `GET /v2/sync/scopes`, and the app says the server is too old.
- **The first self-hosted release**, which 0044's gates name, is the first tablepro-cloud image whose `/v2/sync` carries end-to-end envelopes. The 0.1.x images are the preview.

## Tests

- **Upgrade:** N-1 writes through the facade while N writes `/v2/sync` on one team, concurrently, and no cursor skips. N-1 alone writes, then N snapshots and pulls. The migration keeps ids, revisions, versions and writers. N-1's queries run on the views.
- **Facade:** fixtures recorded from 0.88 and 0.89, kept and dropped keys included. `/v1` golden fixtures 046-065 and 089-093 stay unchanged.
- **Restore:** a dump into a new cluster, a point-in-time restore, and a storage snapshot that changes neither value, each with two clients that refill and converge. A restore, new writes, a failover, then a device offline through both refills its lost write. Two epochs seconds apart, then a restore of a backup older than both, and the device refills its writes from the lost epochs. A device that comes back after another refilled a record and then edited or deleted it keeps that edit or deletion. A database swapped behind a running server serves nothing before its epoch. A policy turned off and on across an epoch while a device is offline keeps that device's copies.
- **Protocol:** every outcome and refusal; stale tags across an epoch; pushes of 500 conflicts store nothing; idempotent replays, mismatches and concurrent retries; page caps by count and bytes; the history order and paging back; a 304 on an idle poll and a new ETag after a role, team or limit change; rate limits.
- **Gates and policies:** the gate matrix across free, Pro monthly, annual and Lifetime, Team, self-hosted with and without `service_sync`, and past grace; roles per kind; each switch off and on again; the policy tombstone job.
- **Approval:** DPoP with each field wrong, a replay, a key outside the set and an expired `iat`; a team envelope or key-object write without an approved holder; a team statement, a member bundle and a recovery blob that do not match; what an unapproved holder sees and writes; the cursor after approval; an idempotent replay after the caller's role changed; a license-key token that tries a genesis or reads a personal scope.
- **Merge:** shared fixtures for content against placement edits on a deletion, run by the CloudKit and the service paths.

## Consequences

- A new kind still needs no server release. Only reserved kinds carry rules.
- Shipped Macs see no change until the facade retires.
- Clients hold change tags, not versions, as the precondition of a write.
- An install whose Postgres role cannot read the control data needs a grant before `/v2/sync` serves.
- A failover or a major Postgres upgrade costs every device one refill.
- A snapshot carries every tombstone's ids, so a new device downloads them with the live records.
- The server reads key versions and verifies log signatures. The threat model lists what that tells it (0053).
- Past grace, apps keep pulling personal and history data as well as the team's. Nothing is written then, key objects included: a device signs out without its `leave`, and a new device waits for a renewed license.

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
