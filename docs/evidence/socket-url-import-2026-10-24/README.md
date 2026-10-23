# Installed socket URL import acceptance

Issue: [#579](https://github.com/cozyGarage/BookiE/issues/579).

The installed scenario `imported_mysql_socket_urls_survive_restart` pins existing behavior. It imports both MySQL and MariaDB URLs, checks the MySQL driver and exact socket path in persisted connection records, and verifies that synthetic passwords reach Secret Service rather than connection JSON.

It restarts the application, checks both unchanged records and their reopened connection forms, then exports an encrypted bundle. Before importing into an empty second profile, it clears only the synthetic records from the private test keyring. The import must restore both exact connection records and both passwords. This prevents pre-existing credentials from making the restoration check pass.

## Result

The complete scenario passed without retries in 17.112 seconds under private Xvfb, D-Bus and Secret Service. It uses the unchanged development executable qualified with the [connection choice fix](../connection-choice-controls-2026-10-23/README.md), SHA-256 `befb19deb593cf7e838212637930e17b21eaea6ba51a3f3cb6467228aa0f7a07`. Test source branches from Linux `575150120`.

The first probe incorrectly expected a connected window after an import-only restart. Correcting the expectation to the welcome screen resolved that test setup error. No product defect or product behavior change is claimed.

## Remaining acceptance

Native desktop acceptance and the Forgejo gate remain separate. The issue stays open until that acceptance is satisfied.

Local preflight also passed: 2,073 unit tests, 2,086 sandbox tests and the separate Redis cancellation check. The scenario itself ran on the unchanged executable identified above; no GTK widget production code changed.


## Real MySQL socket connection

The existing MySQL GTK fixture now exposes its Unix socket through a private bind mount and runs `imported_socket_urls_connect_to_mysql` by default. That scenario imports distinct MySQL and MariaDB URL forms, opens each saved connection, runs `SELECT 42 AS socket_probe`, and requires an accessible result cell containing 42. Both URL forms use a real MySQL 8.0 server; this is not MariaDB server qualification.

The focused scenario passed in 5.221 seconds. In the complete MySQL GTK fixture, it passed in 8.634 seconds, followed by the existing grid edit/delete scenario in 11.278 seconds and enum/set scenario in 7.570 seconds. No retries were enabled. The fixture removed its own container afterward.

Image identity: `mysql:8.0`, local image SHA-256 `7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b`. The client executable is unchanged from the result above.

The first real-socket probe reached the server and completed its query, but expected a column-header accessibility role that this grid does not expose. The corrected probe asserts the actual result cell. Distinct database names prevent duplicate connection labels from selecting the first import twice.

After the real-socket fixture extension, full preflight passed again (2,073 unit tests, 2,086 sandbox tests and the separate Redis check). The focused GTK harness contracts also passed all 58 tests. No shared or pre-existing container was stopped.
