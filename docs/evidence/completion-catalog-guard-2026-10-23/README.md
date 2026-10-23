# Completion catalog request bounds

Issue: [#1487](https://github.com/cozyGarage/BookiE/issues/1487).

## Scope

Completion previously requested columns for each partial table name while typing. Both the editor provider and application request handler now require a complete name from the cached catalog. Unqualified names still resolve against schema-qualified catalog entries. Cached columns suppress additional requests.

Metadata refresh uses a 250 ms trailing debounce. SQL text updates remain immediate. Dropping the refresh owner prevents a pending callback from requesting metadata.

## Regression evidence

The typing-burst regression failed before the fix: eight callback invocations occurred immediately, where zero were expected. After the fix, eight triggers produced one callback after the debounce interval. The isolated X11 test passed with fatal GTK criticals enabled.

The catalog regression rejects partial, unknown-schema and incorrectly cased quoted names. It accepts complete qualified and unqualified names, preserves quoted case, and skips cached columns. All 33 completion tests passed after the catalog fix.

The generated [ignored test inventory](ignored-test-inventory.txt) records the GTK registration.

## Limits

The callback count is measured at the metadata refresh boundary. This run does not measure PostgreSQL audit records or native Wayland keyboard behavior. Full preflight passed, including unit and sandbox tiers. Application Clippy passed with warnings denied. All 155 isolated GTK tests passed. Preflight ran 2,074 unit tests, 2,087 sandbox tests and the separate Redis check successfully.

After integrating Linux at 575150120, full preflight passed again and all 158 isolated GTK tests passed, including the three connection-choice regressions.
