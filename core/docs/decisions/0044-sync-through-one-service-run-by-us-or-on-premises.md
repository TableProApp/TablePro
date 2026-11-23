# 0044: Sync goes through one TablePro service, run by us or entirely on a customer's servers

- **Status**: Accepted; the license types and the calls to tablepro.app amended by 0045
- **Date**: 2026-11-24

## Context

Phase 7 of `ROADMAP.md` (D-01) adds a TablePro sync service on every platform, with iCloud kept beside it on macOS. T-01 asks for the data model, field-by-field conflict rules, end-to-end secrets with key recovery, whether query history syncs, and iCloud beside the service. On 2026-11-24 the maintainer decided that one sync service in tablepro-cloud runs as our SaaS and ships to customers as a self-hosted deploy, with no enterprise fork. macOS ships first, after a preview, and iOS, Linux and Windows follow as each is ready. Everything syncs, passwords end to end encrypted and query history included, and an admin can turn password or history sync off.

What exists today:

- **Four record shapes.**
  - The Mac and iOS sync 12 CloudKit record types through Swift (`SyncRecordType.swift`), with field-by-field rebase on a refused push (`SyncRecordEdit`).
  - Settings go up one record per category. Most categories merge per option; keyboard, AI and each theme (`theme.<id>`) go up whole (`SyncRecordMapper.swift:509-516`).
  - Linux and Windows keep the core's storage documents and sync nothing.
  - In Team Library, a connection is opaque JSON on the server. Folders and queries are typed columns, and other members of their data are dropped (`internal/library/domain/data.go:17-30`, migration 00007).
  - The `.tablepro` bundle v2 is an export format with no ids, versions or tombstones.
- **Team Library** (`internal/library` in tablepro-cloud) already has the shape a sync log needs: one revision sequence taken under a lock, a cursor pull with snapshot paging, `base_version` concurrency and tombstones. It is team-only, with three fixed kinds. An upsert replaces the whole item, and one whose `base_version` is a tombstone's version restores it (`domain/item.go`, `Upserted`; `domain/edit.go`, `Judge`). One refused change refuses the whole push (`v2.go`). A retry after a lost reply conflicts with its own write, since `Judge` treats only a repeated delete as unchanged.
- **The core's merge** rebases CloudKit pulls three way only for group fields and a connection's placement (`group_id`, `sort_order`, `is_favorite`). A connection's name takes the server's value (`core/crates/storage/src/cloudkit/merge.rs:9-50`).
- **The Mac does not link the core yet.** Slice 1a of [0010](0010-macos-on-the-core.md) shipped; 1b, 2 and 3 have not, no iOS slice is built, and no slice moves accounts. The core has no model for SSH profiles, credential profiles or table folders, and saved queries use `i64` ids.
- **Accounts** ([0016](0016-tablepro-accounts.md)). Release builds of every app use tablepro.app. A non-empty `entitlement_keys` list in the FFI's `AccountConfig` replaces the release keys in any build. Neither verifier checks the entitlement's `iss` or `typ`. The Apple app keeps one refresh token under a fixed key. iOS has no account, and the server has no iOS OAuth client or device platform (`internal/device/domain/device.go`).
- **The server** is private with no license file, so it is proprietary. Every module is always wired (`cmd/tablepro-cloud/modules.go`).
  - It needs Polar to boot and mails through SES.
  - It trusts Cloudflare headers: `CF-Connecting-IP` for rate limits, `CF-IPCountry` for sessions (`internal/platform/session/session.go:137`).
  - It reads keys only from `$CREDENTIALS_DIRECTORY` (`internal/platform/keys/keys.go`).
  - It keys accounts by a unique email, with outside identities only from Apple, GitHub and Google (migration 00002).
  - The issuer and audiences are constants.
  - Migrations use Postgres 18's `uuidv7()`. zitadel/oidc v3.51.16 has no RFC 9207 support.

## Decision

Team Library's store becomes one record store with personal, history and team scopes, reached through `/v2/sync`. The same tablepro-cloud binary runs it as our SaaS and, under a self-hosted profile, entirely on a customer's servers: their IdP, their Postgres and an offline TablePro license, with no call to tablepro.app. One Rust crate, `tablepro-sync`, is the client for all four apps. macOS and iOS reach it, and the account stack, through TableProFFI. macOS ships first, then iOS, Linux and Windows as each is ready. Passwords and other secrets sync end to end encrypted. Every key object is signed back to a key the person or their teammates confirmed, so a server cannot substitute keys. An internal adversarial security review of the scheme gates the first self-hosted release. Query history syncs, encrypted the same way, and the server keeps it until the person deletes it. On a self-hosted install the admin can turn password or history sync off, and the server enforces it. On macOS and iOS each device picks Off, iCloud or TablePro Sync for personal data.

## How it works

### Hosting

- **Fully on-premises.** A self-hosted deploy holds accounts, sign-in, teams, records, the audit log and the license. Nothing in it calls tablepro.app at runtime: no license check, no token trust, no push relay. It works with no egress and can run air-gapped.
- **One binary, two profiles.** `PROFILE=saas|selfhosted`, read by `config.Load`, picks a fixed module set and the environment it requires, and the start fails fast as today. No build tags, no `ee/`, no second repository, no per-module switches.
  - Self-hosted runs identity (OIDC sign-in only), oauth, team, device, audit, licensing (from the license file) and sync.
  - It leaves out billing, redeem, education, newsletter, campaign, stats, analytics, etl, the legacy v1 adapter, share links, the staff admin app and impersonation, SES, Turnstile, PostHog, Crisp and the watchdog.
  - The entitlement `iss` and the access token `aud` come from the configured API origin. The entitlement `aud` stays `tablepro-app`. Problem `type` URIs stay `https://api.tablepro.app/problems/...`. They are identifiers (RFC 9457), fixed in the OpenAPI document both clients are generated from.
  - **Client address.** The self-hosted profile must state one of three modes, and a missing setting fails the start: `none` (the socket peer), X-Forwarded-For with trusted CIDRs (chi's `ClientIPFromXFF`), or a single-IP header with trusted CIDRs (chi's `ClientIPFromHeader`). Without it, every client behind a load balancer would share one rate-limit bucket. SaaS keeps `CF-Connecting-IP`. A session's country comes from `CF-IPCountry` only under the SaaS profile; a self-hosted session records none.
  - `tablepro-cloud bootstrap` creates the install's first team and prints a one-time owner claim code that expires within an hour. The first OIDC sign-in that redeems it becomes the owner of the install and of that team. The install's owner and admins create more teams in the portal, and whoever creates a team owns it. `tablepro-cloud license install` loads the license into the database. Each of these steps is audited.
- **Packaging.**
  - One multi-arch OCI image on a base pinned by digest, in a public registry. Anyone can pull it; the license is the gate.
  - It is signed with cosign under the key in Licensing, Key custody. The key's fingerprint is published in the subscription terms and in the docs repository, not only beside the image, so an air-gapped site verifies offline.
  - An SBOM (SPDX) and SLSA provenance are attached to the image digest with `cosign attest`. Third-party notices ship in the image.
  - Two reference deploys. tablepro-cloud's `docs/design` holds their files:
    - Compose: `migrate up`, then `serve`.
    - ECS on Fargate with RDS for PostgreSQL 18: `migrate up` as a non-essential init container that the app container depends on, with secrets injected by ECS from Secrets Manager.
  - Both shape the binary: keys come from the environment when `$CREDENTIALS_DIRECTORY` is unset, since ECS injects secrets as environment values. A `tablepro-cloud healthcheck` command serves the shell-less image, and the server limits request bodies itself, since no nginx sits in front.
  - Production uses the customer's Postgres 18. One instance; high availability is the database's.
- **Releases and upgrades.**
  - Releases are cut from the commits the SaaS runs, with semver tags. The current and the previous minor get security fixes through a release branch.
  - An upgrade goes one minor at a time, or with the old task stopped first, since expand then contract only promises that the previous release runs on the new schema (`docs/design/operations.md`).
  - Migrations are forward-only. Going back means restoring the pre-upgrade snapshot.
  - Security advisories go on a public page and to each customer's security contact, as `SECURITY.md` states. `tablepro-cloud version` prints the running version.

### Operations

- JSON logs on stdout, plus `/healthz` and `/readyz`. An operator alerts on log events: a failed job, a failed migration, the license expiry window. The team portal also shows the expiry. No metrics endpoint until a buyer asks.
- `/v2/sync` has per-account and per-device rate limits. Clients back off exponentially with jitter on 429 and 503, and honor `Retry-After`.

### Data model

- `sync_scopes`: id, type (`personal`, `history` or `team`), the account or team, `epoch`, and `epoch_revision` (the scope's highest revision when its epoch began).
- `sync_records`: scope, kind, record id, `version`, `revision`, `fields` (jsonb), `deleted_at`, `updated_by`, `updated_device`, `updated_at`. The key is (scope, kind, record id), with an index on (scope, revision). Revisions come from one sequence taken under a lock on the scope row, as the library takes them.
- **Record ids.** A record id is the identifier a CloudKit record name carries after its type prefix. For most kinds that is the entity's UUID. A favourite, which has no id ([0017](0017-favourites.md)), uses the sync id the Mac derives from what it names, and settings use the category (`editor`, `keyboard`, `theme.<id>`). When the prefix plus the id passes 255 UTF-16 code units, the id is `sha256-` followed by the digest, exactly as `SyncRecordType.recordName(for:)` computes it. So a move from iCloud keeps every id.
- **Kinds and fields.**
  - A kind's fields are the core model's (`SavedConnection` and its peers), not the CloudKit fields and not the bundle. Enums are strings, each record carries `schema_version`, and `fields` holds no JSON null: an absent field is unset.
  - Settings are one kind per platform (`macos_settings`, `ios_settings`, `linux_settings`, `windows_settings`), one record per category holding that category's JSON options. A theme is a `theme.<id>` record of that kind, as on iCloud today.
  - A settings category can embed a database name, which on SQLite is a file path (`SyncRecordType.swift:35-40`). Its id is therefore as readable to the operator as a connection definition.
- **Tombstones.** A tombstone keeps its ids, version, revision and writer, and its fields are cleared. Tombstones are kept, as migration 00010 decided.
- **Server checks.** The server reads no kind's fields. It checks:
  - the kind's syntax;
  - the sizes: 256 KiB a record, 4 MiB a body, 500 changes a push and 500 records a page;
  - the JSON depth;
  - the role in the scope;
  - the install's policy;
  - the secret-key refusal of `domain/data.go`.

  A new kind needs no server release. Clients check a `credentialReference`'s kind on pull; the server does not.
- **The library moves in.**
  - The three library tables become team scopes with their revisions, so existing cursors stay valid.
  - A connection's payload becomes its fields.
  - A folder's columns become the keys `name`, `parent_client_id` and `sort_order`. A query's become `name`, `query`, `keyword`, `folder_client_id`, `connection_client_id` and `sort_order`. These are the keys the `/v2` library API already uses (`v2.go:65`).
  - `/v2/teams/{id}/library/changes` stays as a facade with its documented behavior, since `/v2` only grows. A folder or query keeps only those keys, and other members are dropped. An upsert whose `base_version` is a tombstone's version restores the item, which is also the `/v2/sync` rule (Conflict rules).
- **Deletion and export.**
  - Deleting an account deletes its personal and history scopes with their envelopes, and clears `updated_by` and `updated_device` on its team records, tombstones included.
  - A self-hosted member removal deletes that person's personal and history scopes 30 days later.
  - A person exports with the apps' existing export, run on a device, where secrets are readable.
  - An operator exports with `pg_dump`. Nothing more is built.

### Protocol

Under `/v2`, OAuth scope `app`, clients generated from the OpenAPI document as in 0016. Errors are RFC 9457 problem details; a 429 carries `Retry-After`.

- **`GET /v2/sync/scopes`** lists the scopes the account reads. For each, it gives the role, the epoch and the horizon, which is the scope's highest revision. It also gives the limits, the server version, the server's capabilities, the idempotency key retention, the poll interval and the install's policies. Its `ETag` covers the epochs, horizons and policies, with `Cache-Control: private, max-age=<interval>` (RFC 9111), so an idle poll is a 304.
- **`GET /v2/sync/scopes/{id}/changes?cursor=&limit=`** pulls as the library does: without a cursor, a paged snapshot up to a high-water mark, then changes in revision order, tombstones included. The cursor is opaque and carries the scope's epoch. A malformed cursor, one from another epoch, or one past the horizon gets 422 `cursor_expired`. The client then takes a fresh snapshot and lays its dirty set over it. A new epoch also refills the server (Restore).
- **`POST /v2/sync/scopes/{id}/changes`** carries up to 500 `{kind, record_id, op: patch|delete, base_version, patch}`.
  - `patch` is the RFC 7396 merge patch from the client's base to its record, applied only when `base_version` is the stored version. An empty patch never leaves the client.
  - Each change answers `applied` (with its version), `conflict` (with the stored record) or `rejected` (with a code such as `secret_key`, `too_large`, `bad_kind`, `policy`).
  - Only a malformed or unauthorized request refuses the whole push.
- **Idempotency.**
  - A push carries an `Idempotency-Key` (draft-ietf-httpapi-idempotency-key-header).
  - On every request, replays included, the server authenticates and checks the role in the scope before it looks up a stored answer.
  - It stores the answer under (account, scope, key) with the request's hash, for the retention that `GET /v2/sync/scopes` advertises (24 hours). The same key and body get the stored answer, another body gets 422, and a concurrent retry gets 409.
  - A client whose batch is older than the retention pulls first. The version and `updated_device` show whether its write applied, and the client rebuilds the batch under a new key.
- **Freshness is polling.** A pull runs at launch, on foreground, when the network returns, after a push, and every advertised interval: 60 seconds in the foreground by default.
- **Version skew.** `/v2` only grows, and capabilities name optional features. There is no separate protocol number. Clients keep fields and kinds they do not know and move past them. Each app release states the oldest server minor it supports, at least the two the support window covers. Below that, the app says the server is too old.
- **Restore.**
  - A point-in-time restore rolls the revision sequence back and loses every write after the restore point.
  - The restore runbook runs `tablepro-cloud sync new-epoch`. It gives every scope a new epoch and records the scope's highest revision as `epoch_revision`.
  - A client that meets a new epoch takes the snapshot. It then pushes, as patches on the snapshot's versions, every record whose base copy carries a revision above `epoch_revision`, deletions included, along with its dirty set. Then it adopts the epoch. Devices refill what the server lost, and equal values from two devices are no conflict, as a CloudKit client re-uploads after losing a zone.
  - Nothing detects a restore on its own. The horizon check catches one whose runbook step was missed, since old cursors are past the restored horizon, until new writes pass them.
  - Shipped Macs on the library facade only resnapshot, so a write acknowledged to them after the restore point is lost.

### Conflict rules

The client merges; the server only versions. `cloudkit::merge` covers group fields and connection placement today. T-03 generalizes it to field maps for every kind, so CloudKit and the service share one merge.

| Kind | Scope | Rule |
| --- | --- | --- |
| connection, group, tag, ssh_profile, credential_profile, saved_query, saved_query_folder, favourite_table, favourite_database, table_folder, table_folder_item | personal | Three way per field. A field changed on one side takes that side. Changed on both, the pushing device wins, as `SyncRecordEdit` does. A deletion wins from either side. |
| group parent | personal | As above. A move that would close a cycle keeps the server's parent (0010). |
| sort order | personal, team | An integer `sort_order`. A new sibling takes a free value between its neighbours; any other change renumbers the list (0010). |
| `<platform>_settings` | personal | One record per category. Options merge three way, lists of objects by `id`. Keyboard, AI and `theme.<id>` go whole: a shortcut must stay unique, the active AI provider must be one of the providers, and a theme is one design. The core does the option merge. The host's adapter names the whole categories and keeps the Mac's slash command collision rename. |
| library connection, folder, query | team | The same field merge. A field both sides changed to different values opens Keep Mine, Keep Theirs or Decide Later; equal values are no conflict. An edit on a version older than a tombstone is a conflict. A push on the tombstone's version restores the record, which is how Keep Mine answers a deletion. The facade has the same rule. |
| history_entry | history | Created once, never patched. A delete is a tombstone. |
| secret_envelope | personal, team | Written whole; the last pusher wins. Ciphertext does not merge. |

### What syncs

- **Personal scope:** the twelve kinds the Mac syncs through iCloud, under the names above, and `secret_envelope`. A platform with no UI for a kind still stores it and sends it back unchanged.
- **History scope:** one per account. Each run the app records becomes one `history_entry`, whose fields are an envelope under the account key, since history holds literal SQL with data values. Pushes are batched, never one per run.
  - The server keeps every entry until the person deletes it, with no retention limit. A device's own history limit prunes only its local copy and pushes no deletion.
- **Team scope:** the library's connection, folder and query, and the team's `secret_envelope`. Team Catalog stays a shared folder, such as a Git repository or a shared drive, and is not a service kind; Team Library is how the service shares.
- **Settings** sync between devices of one platform. An option crosses platforms only once two platforms share it, through a registry in the core that starts empty.
- **Never:** per-device view state (sort mode, the Recent switch, the recent count), `passwordSource` commands and files, tunnel commands, and any secret outside an envelope.

### Policies

- **Self-hosted:** two install-wide settings, `passwordSync` and `historySync`, on by default. The install's owner or an admin sets them in the portal, and each change is audited.
  - Off, the server answers a push of `secret_envelope` or `history_entry` with `rejected` (`policy`) in every scope, and tombstones the existing ones.
  - Devices keep what they hold locally, so a password stays usable on each device that has it.
- **SaaS:** a team's `passwordSync` governs `secret_envelope` in that team's scope only. Personal and history scopes belong to their account, and no team governs them, since one account can be in several teams.
- The client reads the policies from `GET /v2/sync/scopes` and only shapes its UI with them.

### Fields a pull applies only with approval

A sync server, ours or a customer's, must not be able to run anything on a device, weaken its protections, or send its secrets or data elsewhere. Every field of every kind, settings options included, has one of three classes in the core:

- **Inert:** applied on pull.
- **Approval-required:** a pulled change waits for the person on each device, in a consent model that moves from the Mac's `EnvVarReferenceConsent` into the core. This class covers:
  - any destination of a stored secret: engine, host, port, user, database, SSH route, TLS mode, CA and certificate paths, and an AI provider's type and endpoint;
  - a lower safe mode level, and a looser AI policy or AI rules;
  - startup SQL;
  - AI tool allowlists;
  - AI context options that send more: `includeSchema`, `includeQueryResults`, `defaultConnectionPolicy`.
- **Device-only:** never pushed.

A field with no class counts as approval-required, and a core test fails when a model field has none.

In the team scope, startup SQL and tunnel commands are dropped on pull, as Team Library drops them today (`TeamLibraryItem.swift:218`). AI tool allowlists are dropped too, since the bundle format Team Library carries has never held them. Other approval-required fields wait for approval, as in the personal scope.

Values a device moves into the service with count as approved on that device.

### Secrets

- **Device stores.** Each device keeps its private keys and readable secrets in its own store: the Keychain (this device only), Credential Manager, the Secret Service. A secret reaches the server only inside a `secret_envelope`. The server keeps refusing secret-named keys, and clients strip them before a push.
- **Typed references** sync as data in `credentialReference`: a 1Password `op://` reference, Vault KV, a Vault database role, AWS Secrets Manager, or an environment variable name. Never a command or a file. The type moves from `PasswordSource.swift` into the core. A device checks the reference kind on pull. It resolves a reference with its own person's identity, after the person approves the pair (reference, destination). A platform that cannot resolve a kind asks for the password.
- **Algorithms**, once in the core for all four apps:
  - HPKE (RFC 9180) base mode with DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM, from `rustls::crypto::aws_lc_rs::hpke`, which runs the RFC 9180 vectors.
  - Items under AES-256-GCM, and signatures with Ed25519, both from aws-lc-rs.
  - Base mode does not authenticate the sender, so every key object is signed.
- **Keys:**
  - Each device has an HPKE key pair and an Ed25519 signing key pair. Their private halves stay in the device store and never sync.
  - Each account has an identity key pair (Ed25519) and a sharing key pair (HPKE). Their private halves are kept under the account key.
  - The account key is versioned and sealed to each device on the account's device list and to the recovery key.
  - Each team has a versioned team key, sealed to each confirmed member's sharing key.
  - The recovery key is a random seed the person writes down. RFC 9180 `DeriveKeyPair` gives its HPKE key pair.
  - No key is derived from a password, so key custody does not depend on sign-in.
- **Trust chain:**
  - The account's identity key signs its device list and its sharing public key.
  - A device pins its account's identity public key when it is approved. It accepts a sealed account key only when that key unlocks the pinned identity key.
  - Members pin each other's identity keys when they are confirmed. The owner signs the team's admin list, and an admin's identity key signs each team key version.
  - A client refuses any key object whose signature does not chain to a pinned identity key. "Never encrypt under a key version lower than the highest seen" counts only signed versions.
  - This follows Matrix cross-signing.
- **Comparing keys.** Two fingerprints, each a SHA-256 digest of a fixed label and the keys involved, shown as at least 64 bits of words as Bitwarden's fingerprint phrase is:
  - A new device is approved from a device already on the list, or with the recovery key, and requests expire. Both devices show a fingerprint over the account id, the identity public key and the new device's public keys.
  - A member is confirmed by comparing, out of band, a fingerprint over the team id and both accounts' identity public keys.
  - At 64 bits, a server cannot search for a key pair whose fingerprint matches.
- **Envelope.** A `secret_envelope` record per (record, secret kind) carries the format version, the suite ids, the key version, `enc` and the padded ciphertext. Its associated data binds scope, record, secret kind, key version and destination, so a server that rewrites a host makes decryption fail.
- **Removing a device.** Remove Device is available from another device on the list.
  - It revokes that device's refresh token family at once and takes it off the signed device list.
  - Every key the device held is rotated: a new account key version, new identity and sharing key pairs, and a new version of each team key the account holds. The new keys are sealed to the remaining devices, the recovery key and the members, and personal envelopes are re-encrypted.
  - Teammates see that the person's identity key changed and confirm it again, as Signal shows a changed safety number.
  - An admin can also remove a device. The tokens and the list entry go at once and the team keys rotate. The account's own keys rotate on the person's next approved device or at recovery.
  - The app lists the database credentials to rotate.
- **Removing a member** makes a new, signed version of each team key, sealed to the remaining members, and re-encrypts the team's envelopes. The app lists the database credentials to rotate.
- **Recovery.** A person who loses every device and the recovery key loses their personal secrets. Team secrets come back once an admin seals the team key to their new keys.
- **iCloud Keychain.** With TablePro Sync and password sync on, a secret is a device-only Keychain item plus its envelope. iCloud Keychain sync applies only with the iCloud provider, or when password sync is off. A managed device turns it off with `ICloudSyncAllowed`.
- **Release gate.** A threat model and an internal adversarial security review cover the key hierarchy, the signed objects and their checks, the fingerprints, device and member removal, and the envelope. The review is a Codex review plus independent Claude reviewers, run with the RFC 9180 vectors and our own known-answer vectors (Tests). The threat model names three attacks: a server that seals keys it knows, swaps public keys, or replays old key versions. The review passing gates the first self-hosted release.

### Sign-in and SSO

- **The server signs people in through the customer's IdP:** OIDC authorization code with PKCE through coreos/go-oidc, requesting a refresh token (`offline_access`).
  - A self-hosted identity is keyed by (`iss`, `sub`), the only stable identifier OpenID Connect Core section 5.7 grants. `account_identities` gains the provider `oidc` and stores the issuer.
  - Email is contact data only. It never links an identity and never grants a role.
  - The first sign-in creates the account and takes a seat while one is free. The IdP's assignment decides who may sign in.
  - An optional group claim maps to the install's admin role, matched by group id and never by display name. It is checked on every sign-in and every upstream revalidation, so leaving the group removes admin.
  - A SAML or LDAP directory goes through a broker the customer runs, such as Keycloak or Dex.
- **Deprovisioning.**
  - The server stores the IdP's refresh token under the existing `crypt` keyring, as the Apple column is stored. It checks the token upstream when an app refreshes, at most once per `UPSTREAM_REVALIDATE` (1 hour by default). A failure revokes the token family.
  - With access tokens at 15 minutes, access ends about 75 minutes after an IdP disable.
  - A session lasts at most `SESSION_MAX_AGE`: 7 days by default, and one working day when the IdP returns no refresh token, since nothing then checks the person upstream.
  - A removal by the owner or an admin revokes at once.
  - A member whose upstream check failed keeps their seat until an admin removes them, and the portal lists such members.
  - Data already on a device stays there.
- **Step-up.** A role change or a removal in the portal asks the IdP again with `max_age=0` and checks `auth_time`. A license install is the operator's CLI command, audited.
- **The apps' flow does not change:** the browser, the static public clients and their redirects (RFC 8252). tablepro-cloud adds `tablepro-ios` with the custom scheme, and the device platform `ios`. A client reports its own platform, so the platform never decides what counts against a limit.
- **Discovery and mix-up.**
  - The server serves RFC 9728 metadata, which points the app to OIDC discovery. It adds the RFC 9207 `iss` to authorization responses, and the apps compare that `iss` with the server they chose, as RFC 9700 section 4.4 requires once a client can reach more than one server.
  - RFC 9207 support, with `authorization_response_iss_parameter_supported` in the metadata, is contributed to zitadel/oidc. A pinned release that has it gates the first self-hosted release.
- **One server per install.** Switching is a sign-out and a sign-in. Tokens are keyed by server: the core's `sign_in_key` already does this, and the Mac and iOS use it through the account slice.

### Licensing

- **The self-hosted server** ships as a binary under commercial subscription terms, with its notices, SBOM and provenance.
- **The license** is a JWS compact JWT with `typ` `license+jwt`, signed with EdDSA over Ed25519 (RFC 7515, 7519, 8037) through go-jose, with an opaque signer that calls AWS KMS.
  - It is verified offline against TablePro license keys compiled into the server and the apps, picked by `kid` (the RFC 7638 thumbprint).
  - Claims: `iss`; `aud` `["tablepro-cloud", "tablepro-app"]`; `sub` (the license id, which our records map to the customer); `iat`; `nbf`; `exp`; `jti`; `license_type` (`trial` or `paid`); `seats`; `features`; and `origin`, the customer's https API origin, which must equal the configured one.
  - No customer name and no device count.
- **Key custody.** The license signing key and the cosign key are two AWS KMS keys, each used for nothing else. The SaaS's role cannot sign with either.
  - The license key has the spec `ECC_NIST_EDWARDS25519` and signs with `ED25519_SHA_512` over the raw JWS signing input, which KMS takes up to 4096 bytes. KMS signs Ed25519, so the license stays EdDSA.
  - The cosign key is `ECC_NIST_P256` (ECDSA P-256), since sigstore's AWS KMS signer, which cosign uses, offers RSA and the NIST curves but not Ed25519.
  - Our admin records a license request, audited, and a person signs it.
  - Every app and server build carries two license public keys, current and next, so the key can rotate, plus a list of revoked `kid` values that ships with updates.
- **Seats** are a hard cap, pooled across every team on the install: an account takes one seat however many teams it is in. A self-hosted license has no device cap: seats are the unit, and every device, iOS included, is on the device list for approval and removal. On the SaaS, an iOS device counts toward the account's 3-device cap like any other.
- **Expiry** shows a banner 30 days ahead and gives 30 days' grace. After that, a push is refused with `license_expired`. Pulls and administration keep working, so each device can still export, and nothing is deleted.
- **A trial** is the same file with `license_type: trial`; the paid file replaces it in place. No phone-home, online activation or usage report.
- **Features.** A new code, `service_sync`, gates personal and history sync on the service in both deploys. `team_library` and a seat gate the team scope. A seat carries the Pro features too, as a Team seat does. The server checks them on every sync call; the app's gate only shapes the UI. iOS verifies no entitlement, as today.
- **How an app trusts a customer's server.**
  - Release keys stay compiled in. Configuration says only where the server is, never which key to trust.
  - After sign-in, the app reads the license from `GET /v2/license`, verifies it with a license key it ships, and checks `typ`, `aud`, `origin` and `exp`.
  - It then fetches the origin's JWKS (RFC 7517) over TLS. It accepts entitlements signed by those keys whose `typ` is `entitlement+jwt` and whose `iss` is the server's, with features cut to the license's.
  - License keys and entitlement keys are separate sets.
  - The Go and Rust verifiers check `typ`, `iss` and `aud`, with `iss` required (RFC 8725 section 3.11). The SaaS sets `typ` on entitlements before any app requires it.
  - The FFI's `entitlement_keys` override builds only in debug builds.

### App configuration

One set of policy names on every platform. A value counts only when the OS marks it as managed.

| Key | Effect |
| --- | --- |
| `AccountServerURL` | The company server, an https URL |
| `AllowOtherAccountServers` | `false` hides tablepro.app and manual entry |
| `UsageDataAllowed` | `false` turns usage data off and locks the switch |
| `PluginCatalogAllowed` | `false` stops requests to the plugin registry |
| `UpdateChecksAllowed` | `false` stops update checks on Linux and Windows; macOS keeps its Sparkle keys |
| `ICloudSyncAllowed` | `false` hides the iCloud provider and iCloud Keychain sync on macOS and iOS |

| Platform | Channel | Managed when |
| --- | --- | --- |
| macOS | A configuration profile for `com.TablePro`, keys `com.TablePro.policy.<key>` beside `ManagedPolicy` | `objectIsForced(forKey:)` |
| iOS | `com.apple.configuration.managed`, with an AppConfig specfile | Always; only the OS writes it |
| Windows | `HKLM\SOFTWARE\Policies\TablePro\TablePro`, then its `HKCU` mirror, with ADMX and ADML that use text boxes | The value is under `Policies` |
| Linux | `/etc/tablepro/policy.json` | The file and `/etc/tablepro` are owned by uid 0 and writable by neither group nor others, and the file opens with `O_NOFOLLOW`. Otherwise it is ignored and the reason logged. |
| Linux Flatpak | The same file through the unmaintained extension `app.tablepro.TablePro.Policy` (version `1`, `no-autodownload`), mounted at `/app/etc/tablepro`. The admin links `/var/lib/flatpak/extension/app.tablepro.TablePro.Policy/<arch>/1` to `/etc/tablepro`, as Chromium on Flathub takes policies; Firefox's `org.mozilla.firefox.systemconfig` works the same way | As above, except that the owner must not be the person's uid, since a root-owned file shows as the overflow uid inside the sandbox. Flatpak looks in `$XDG_DATA_HOME/flatpak/extension` first, so a person's own copy hides the system one; the rule refuses that copy and the reason is logged |

- The core picks the server: a forced value, else the person's choice, else production. It requires https, with http only for loopback in development builds, and runs the discovery. Each host only reads its channel and passes the raw values in.
- TLS uses the OS trust store on every platform. The Flatpak build is tested in its sandbox with an enterprise root before release.
- The sign-in sheet keeps Sign In for tablepro.app and adds Use a Company Server, with one URL field. Account settings show the server's host and, when forced, that the organization manages it.

### iCloud beside the service

- Each Mac or iPhone picks one provider for personal data: Off, iCloud or TablePro Sync. Never two, since two masters echo each other's writes. Team scopes always use the service.
- **The move, per device:**
  - A last iCloud pull, then the CloudKit engine stops.
  - Every local record, settings and themes included, goes to the personal scope as a create with `base_version` 0 under its existing record id. A second device that moves later meets the same ids, gets conflicts and merges field by field, so nothing duplicates.
  - Each Keychain secret the device holds is sealed into an envelope, and its Keychain item becomes device-only.
  - The iCloud zone stays for a move back; deleting it is a separate action.
- A Mac moves to the service only once the service carries all twelve kinds, so a move drops nothing.

### The client in the core

- `core/crates/sync` (`tablepro-sync`) depends on `storage` and `account`. It keeps its state in its own SQLite file through sqlx:
  - per scope, the cursor and epoch;
  - the base copy of each record with its version and revision;
  - the dirty ids;
  - the batch in flight with its idempotency key and age;
  - open team conflicts, pending approvals, and pinned identity keys.
- **Writes and crashes.** The store is JSON documents and its own databases (`storage/src/paths.rs`), so it shares no transaction with the sync file.
  - A local edit marks the record dirty in the sync file before it writes the store. A crash between the two leaves a mark with no change, and the client drops its empty patch.
  - A pull writes the store, then the bases, then the cursor, so a crash replays it with no effect.
  - Both windows have tests.
- The offline queue is the dirty set and the base copies, not a log of operations. A push reads each record when it builds the batch.
- Each kind has a `RecordAdapter` over its core store. Settings, which each platform keeps its own way, take an adapter the host implements.
- The transport is a progenitor client generated from `/v2`, with tokens from `tablepro-account` and the device from `/v2/devices`.
- The FFI gives a `SyncService` and a callback for status, changed kinds, team conflicts, approvals and device requests. Swift calls it through TableProFFI; there is no Swift client for the service.
- The Mac uses it after the account slice, slices 1b, 2 and 3 of 0010, and a slice for SSH profiles, credential profiles, favourites and table folders. iOS uses it after its XCFramework slices.

### Tests

- Shared JSON fixtures for the field merge, run by both the CloudKit path and the service path. They check that two devices converge through a rebasing server, that unknown fields survive, and that settings categories merge per option or whole.
- Contract tests for the Go server and the Rust client from the OpenAPI document.
- Facade fixtures recorded from the shipped Mac client: kept and dropped folder and query keys, and the restore on a tombstone's version.
- Known-answer vectors for the envelope and the signatures (AAD binding, key version, signed device list) beside the RFC 9180 vectors. Tests that a client refuses an unsigned or wrongly chained key object, a substituted sharing key, and a fingerprint mismatch.
- The field class test, and approval tests for each approval-required class.
- Tests for both crash windows: the dirty mark and the pull order.
- In tablepro-cloud CI: an upgrade from N-1 to N with the old task running, and a restore plus new epoch with two clients refilling.

## Out of scope

- An enterprise fork, an `ee/` split, edition builds, a library-only service, or a hybrid split.
- CRDTs, hybrid logical clocks, device clocks, or a merge of SQL text.
- SSE, WebSocket, gRPC, APNs or FCM from any sync server, and a push path only the SaaS has.
- A table per kind, merge code in Go, per-record access rules, record sharing outside teams, or a server check of reference kinds.
- An admin reading a member's history, server-side history search, or history in a team scope.
- A Swift client for the service or for accounts, and CKSyncEngine, which needs macOS 14 while the app supports 13.0.
- SAML, LDAP or SCIM in tablepro-cloud, WorkOS in the self-hosted deploy, Dynamic Client Registration, discovery of a server by email domain, and linking identities by email.
- A local patch of zitadel/oidc, and a parser for RFC 7239 `Forwarded`.
- A policy, configuration or environment value in a release build that adds entitlement keys, license keys, client ids or redirects.
- Certificate pinning, an app CA store or a self-signed switch.
- Custom crypto, RSA, a master password or SRP, a key server, admin escrow of personal secrets, server-side secret-manager access, MLS, per-item keys, or a browser client.
- A third-party audit of the end-to-end scheme.
- Phone-home licensing, online activation, telemetry from a self-hosted server, obfuscation, seat true-up, a server self-updater, Helm, an operator, or clustering before a buyer needs one.
- A metrics endpoint before a buyer asks, and mail from the self-hosted deploy before a flow needs it.

## Consequences

- **Phase 7 changes.** It runs now as its own lane, ahead of the D-06 order. T-05 folds into the first self-hosted release, and T-06 adds query history. T-04 to T-08 gain iOS boxes, and an iOS account item is added.
- **0010 gains two slices.**
  - An account slice, ordered before the macOS preview. Through it, the Mac and iOS use `tablepro-account` via TableProFFI, and the Swift account code is deleted.
  - A slice for SSH profiles, credential profiles, favourites and table folders.
- **Release order.** macOS ships first, after a preview. Its date rests on the Mac's slices of 0010 and the security review. iOS, Linux and Windows follow as each is ready, and Windows D-04 gates only the Windows release.
- **This amends 0016.** Release builds take their server from policy or the person, admit a server's keys only through a license, and check `iss` and `typ`.
- **Shipped Macs** push the team kinds through the facade by rebuilding each item from their own models, so those kinds' fields stay as they are until T-08 moves the Mac onto the core client.
- **Per-device passwords** remain only where password sync is off. A person approves on each device any approval-required change made on another, their own edits included.
- **Teammates confirm a person's identity key again** after that person removes a device or recovers.
- **A modified server holding a valid license** can give out more seats than it carries. The subscription terms cover that, as for every offline license.
- **A removed member** keeps what their devices already hold. Only rotating a database password revokes what they read.
- **On the SaaS,** connection definitions and settings ids are readable by us; secrets and history are not. A customer who will not allow that hosts the service.
- **Docs to update:**
  - In tablepro-cloud: `product.md`, `SECURITY.md` and the design docs.
  - Also `monetization-roadmap.md`. Its line 72 sells Team and Enterprise as services on our servers, and its R4 Enterprise items (domain sign-in, SAML and SCIM through WorkOS) sit behind our OAuth server. A self-hosted deploy sells a proprietary server under a license file, and WorkOS stays on the SaaS.
  - The docs site.
  - None of them says a third party verified the end-to-end scheme.

## Alternatives considered

- **Hybrid: the customer hosts the records, accounts and licensing stay on tablepro.app.**
  - Every sign-in and refresh needs tablepro.app, so no air gap.
  - Identities and audit stay with us. The customer's IdP works only through SSO on our SaaS.
  - The in-process team, seat and feature checks become a versioned contract between deploys, with per-customer audiences (RFC 8707). Staging hybrid first builds that contract and then throws it away.
- **An open-source server, AGPL or open core.** It publishes SaaS-only code, needs a CLA, and lets anyone remove the license check. No buyer asks for the source.
- **A second protocol beside Team Library.** Two logs, two cursors and two conflict engines per team, for nothing the library lacks.
- **Whole-record upserts and no idempotency key.** A lost reply followed by another device's edit of the same field makes the retry overwrite the newer value. An older client that drops a field it does not know erases it.
- **An SSE or long-poll stream.** It needs long-lived connections through customer proxies that must not buffer, and fan-out across instances, for records that change rarely. The capabilities answer can add one later.
- **Purging tombstones behind a cursor floor.** A purged tombstone lets a late create, such as a move from iCloud, bring a deleted record back, and the rows are small.
- **Startup SQL never syncs.** iCloud carries it today, so a move to the service would lose it. Approval keeps it without trusting the server.
- **A sync or account client in Swift until the Mac reaches the core.** A second home for the merge, the protocol and the server trust, which 0010 exists to end.
- **Per-device secrets first, E2E later.** It misses the scope decided on 2026-11-24 and makes customers move their secrets twice.
- **HPKE without signed key objects.** A server could seal keys it knows or swap public keys. Scarlata, Torrisi, Backendal and Paterson found this class of attack in four password managers that claim the server cannot read their vaults (ePrint 2026/058).
- **A short code from the new public key.** About 2^20 tries let a server find a key with a matching six-digit code. A commitment protocol (Matrix SAS) needs a round trip the fingerprint does not.
- **The license at `/.well-known/tablepro-license`.** The URI is unregistered (RFC 8615) and public. The app needs the license only to trust entitlements, which come after sign-in anyway.
- **The server's key named in the license (RFC 7800 `cnf`).** Every key rotation would need a new license, and a trial could not be issued before the install.
- **Email codes and passkeys on the self-hosted deploy.** An SMTP adapter and a second set of accounts beside the IdP the customer already runs.
- **Team policies over personal scopes on the SaaS.** One account can be in several teams, so any team's admin could refuse or delete that person's own data.
- **`--filesystem=host-etc` for the Flatpak's policy.** It exposes the host's whole `/etc`, at `/run/host/etc`, to read one file. Granting `/etc/tablepro` alone does nothing, since Flatpak reserves `/etc`, and Flathub never grants `finish-args-reserved-etc`. The extension adds no permission.
- **Cross-platform settings from the start.** The platforms share no option today, so the registry would only map names nobody shares.
