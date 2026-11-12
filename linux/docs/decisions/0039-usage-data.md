# 0039: Usage data through posthog-rs, on by default as on macOS

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

tablepro-cloud's `docs/design/clients.md` has the apps send usage events to PostHog directly, identify with the account's ID after a sign-in, reset on a sign-out, and keep a setting that also stops the identify. Linux follows its macOS Telemetry list, except `feature_gate_shown`, and macOS's `Telemetry.swift` is the reference for what it leaves open. It names posthog-rs 0.27 for Linux, with `flush()` before exit. On 2026-11-05 the maintainer decided that every TablePro app shares usage data by default, Linux included, as macOS 0.86.0 does, with no question at launch and a switch to turn it off. TablePro for Linux sent nothing of the kind before.

## Decision

`crates/app/src/services/telemetry.rs` sends the events through posthog-rs 0.27.0's blocking client, to the project key Meson passes as `-Dposthog_key`. Without a key, or while Share Usage Data is off, no client is made, so nothing is sent. The GSettings key `share-usage-data` is on by default. Preferences > General > Privacy, shown only in a build with a key, has the Share Usage Data switch, "Help improve TablePro with app activity and system information"; turning it off stops the events at once.

## How it works

- **Client.** posthog-rs without its default features: no async client, no error tracking. Its worker is a thread of its own with reqwest's blocking client, built off the GTK thread the first time Share Usage Data is on; what is captured before it exists waits for it. Each event is sent as it is captured (`flush_at` 1) and tried once, so one that fails is lost. The worker sends one request at a time, and a request times out after 5 seconds, which bounds the `flush()` the application's shutdown runs. An event captured while an earlier request waits for PostHog waits behind it; each event carries the turn of Share Usage Data it was captured in, and a `before_send` hook drops it as it leaves unless that turn still holds, so the switch going off meanwhile drops it even if it comes back on. Once the switch is off, only the request already on the wire can still reach PostHog. The host is PostHog's EU ingestion host.
- **Identity.** `telemetry.json` in the state directory keeps a random anonymous ID, the account PostHog knows the install as, the day `app_opened` last went out and the events sent once. While Share Usage Data is on, the person follows the account: `$identify` once a run while signed in, with the account's TypeID and `$anon_distinct_id`, the account from the entitlement's `sub` or, signed in without an entitlement, from `/v2/me`; and a reset, a new anonymous ID, once the account is gone. Before the account has restored at launch, neither happens. An anonymous event carries `$process_person_profile` false, as posthog-ios's `identifiedOnly` does on macOS.
- **Person properties**, in `$set` on `$identify`, with the keys macOS sets: `app_version`, `os_version` (the host's `PRETTY_NAME`), `architecture` (`arm64` or `x86_64` as macOS names them, so Rust's `aarch64` goes as `arm64`) and `locale`. Linux has no language setting, so `locale` is the interface's `LC_MESSAGES` locale without its codeset, such as `vi_VN`.
- **Events**: `app_opened` once per local day, 10 seconds after launch so restored sessions count and then each hour, with `database_types` and `connection_count` of the open connections; `connection_attempted` and `connection_succeeded` once per install with `database_type`, from a wrapper around the app's `Connector`; `first_query_executed` once per install with `database_type`, from the first editor run that succeeded, which the query history service sees whether or not the history is on; `upgrade_clicked` with `source` `app-settings`, the source macOS's Settings > Account sends, from Preferences > Account, and `app-ask` from the license ask's Buy a License; `support_ask_shown` with no properties each time the license ask shows, and `support_ask_answered` with `answer` `buy` when Buy a License is pressed, since a toast that goes on its own is no answer; `signed_in` with `method` `interactive`; `signed_out` with none, for the user's own sign-out only. A removed device or a refused refresh token only resets, so nothing goes out as an account that may be deleted. Between the user's Sign Out and the status it ends in, an answer that still names the account, from `/v2/me` or a scheduled refresh, identifies nobody. `feature_gate_shown` waits for a gated feature on Linux.
- **Database types.** `database_type` and `database_types` carry the names macOS's `DatabaseType` uses, such as `PostgreSQL`, `MySQL`, `SQLite` and `SQL Server`, not the driver IDs, so a breakdown by type reads the same from either app. MariaDB goes through the MySQL driver and reports `MySQL`; ScyllaDB goes through the Cassandra driver and reports `Cassandra`. A driver without a name there reports its ID.
- **The switch** stops every event, the `$identify` and the reset at once, and drops what waits for the client. A sign-out made while it is off resets when it is turned on again. As on macOS, the first connection or query made while it is off is still the one counted, and is never sent.
- **Besides the events**, posthog-rs adds `$lib`, `$lib_version` and its three parts, and `$os` and `$os_version` from `os_info` to each event, with a UUID and a timestamp; each request carries the project key, a `sent_at` time and the `posthog-rs/0.27.0` User-Agent. PostHog sees the address the request comes from, which it uses for GeoIP. posthog-rs asks for no feature flags and makes no request of its own.

## Consequences

- A build without `-Dposthog_key`, which is every build so far, sends nothing and shows no Privacy group, since its switch would do nothing.
- A build with a key, which the PPA and COPR packages are, sends the events above from its first launch, and stops when the switch goes off.
- posthog-rs brings reqwest's blocking and gzip features, `derive_builder` and `os_info` into the workspace.

## Alternatives considered

- **The async client.** It needs a runtime to build and drop, and the GTK thread has none; capture is a queue push either way.
- **The hashed machine ID as the anonymous ID.** A reset has to give a new ID, and the machine ID never changes.
- **Off until the user opts in**, from a launch toast whose Choose… opened a Share or Don't Share question with no default, and the first form of this change. The maintainer chose on by default for every app on 2026-11-05, so Linux behaves as macOS does.
- **The question as a first-launch dialog.** The HIG: "Never pop up a dialog window unexpectedly."
