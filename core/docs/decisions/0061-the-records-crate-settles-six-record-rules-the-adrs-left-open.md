# 0061: The records crate settles six record rules the ADRs left open

- **Status**: Accepted; amends 0044, 0051, 0054 and 0056; driver names on the wire amended by 0075
- **Date**: 2026-11-26

## Context

`tablepro-records` (#4518) had to give every synced field a wire name, a class and a size rule. In six places the ADRs say nothing or say less than the code needs. 0044, 0051, 0054 and 0056 are Accepted, so the readings go here, and those ADRs change only their Status lines.

## Decision

1. **The first envelope row's destination** ([0056](0056-end-to-end-keys-per-account-and-device.md), Envelopes and history). A connection has no single SSH route field, so `dest` for `password` and `ssl_key_passphrase` binds the SSH host fields, each `jump_hosts` entry's host, port, user and key path, `ssh_profile_id` and the published `ssh_route`, beside the fields the row names. It also binds `additional_fields` and `network_options`, which can send a connection somewhere else. The TLS client key path stays out: it names a file on each device and does not change where the secret goes.
2. **Approval-required AI options** ([0044](0044-sync-through-one-service-run-by-us-or-on-premises.md), Fields a pull applies only with approval). Beyond `includeSchema`, `includeQueryResults` and `defaultConnectionPolicy`, these wait for the person too: `includeCurrentQuery`, `maxSchemaTables`, `chatMode`, `enabled`, `inlineSuggestionsEnabled`, `useAppleIntelligence`, `telemetryEnabled` and `maxToolRoundtrips`. Each can widen what leaves the device.
3. **`colorTag`** ([0054](0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md), The CloudKit transport). The core writes the colour's name there, as 0054 says, though today's Mac never wrote it. Older builds that read the field get the colour.
4. **Personal wire names and values** (0054 and [0051](0051-sync-protocol-and-record-rules.md), What syncs). A personal kind's wire field is its CloudKit field name in snake_case, with the CloudKit value, so a move from iCloud maps each field one to one. Fields only the core has, `auth_mode`, `network_options`, `ssl_config.server_name` and `passphrase_stored`, sync on TablePro Sync only, since iCloud gains no field. A connection's credential profile link becomes a TablePro Sync field and is approval-required, where the Mac keeps it device-only today: it decides which credentials a connection sends.
5. **JSON depth** (0051, Limits). The 32-level limit counts the `fields` object as level 1, on the client and on the server, so one record is taken or refused the same way on both.
6. **Settings of iOS, Linux and Windows** (0051, Kinds). No `ios_settings`, `linux_settings` or `windows_settings` category syncs until an ADR names it, and their registries are empty. 0044's registry starts empty, and an option nobody has classed would count as approval-required anyway.

## Consequences

- `tablepro-records`, the server's depth check and every client follow these rules.
- A person approves more AI setting changes, and a change of a connection's credential profile, on each device.
- The three platforms sync no settings until their own ADR.
