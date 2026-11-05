# 0034: Preferences > Account, the device limit dialog, offline files and the license ask

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

The maintainer decided on 2026-11-05 that TablePro for Linux is licensed as the Mac is: the same plans, accounts and devices, built now, while the paid features come to Linux later. Linux had no licensing before, so it gets the `/v2` flow only (tablepro-cloud's `docs/design/clients.md`, Linux). The account itself is the core's `tablepro-account` ([core ADR 0011](../../../core/docs/decisions/0011-tablepro-accounts.md)). tablepro-cloud's `docs/design/clients.md` asks for a Preferences > Account page with the sections of the macOS Settings > Account: Account, Plan, Features, Devices, Teams and Offline, with notices for a payment problem, a cancellation and an entitlement close to its end. Over the device limit, a dialog lists the 3 devices holding the license and removes one in place, except a device whose offline file is still valid. A machine that never reaches the internet imports an offline file instead of signing in. The Mac also asks, on the 30th day of use without a license, whether you would buy one (#3922).

## Decision

An `AdwPreferencesPage` in the Preferences dialog shows the account, built from the entitlement and, while the page is shown, from `GET /v2/me` and `GET /v2/devices`. An imported offline file is an entitlement like any other, kept in `account.json`, and works signed out. The license ask works as on macOS, as a toast.

## How it works

- **Where each part comes from.** The plan, the features and the verification time come from the entitlement, so they show offline. The teams, their roles and seats, and the devices come from `/v2/me` and `/v2/devices`, fetched when the page is shown and after each change; until the profile answers, the plan comes from the entitlement's licenses. `tablepro-account` turns the generated types into `Profile` and `Device`, whose plan, cycle, status, role and platform are strings, so one this build does not know shows as `License` or not at all instead of failing the page.
- **Features.** The page lists the ten feature codes, each included or not by the current entitlement. TablePro for Linux has none of the ten yet, so each row says it is in TablePro for macOS, and nothing is gated. Signed out, the group ends with Buy a License, which opens the pricing page, and every state with Learn More About Licensing, as the Mac's Features footer does.
- **Sign-in.** Sign In runs `Account::sign_in`, which opens the browser through `gtk::UriLauncher`; the page shows the wait and a Cancel that drops it. `device_limit_reached` at the end of a sign-in opens the dialog; at a background refresh it is a notice in the Plan section with the same dialog behind a button.
- **Plan rows.** One per license: the plan, and for a subscription or order license its cycle and a Billing... button, as the portal does; nothing bills a license an admin granted or the migration brought over. The status is Renews on (the license's `renews_at`), Active, Ends on, Payment problem, or for a lifetime purchase the cycle alone; a status this build does not know shows none.
- **The device limit dialog** lists the devices `device_limit_reached` names, each with its `offline_until`. Remove asks first, then `Account::remove_device` deletes the device and refreshes the entitlement, which the freed slot lets through. A device whose file is valid shows until when, and the server's `offline_file_active` is worded too.
- **Errors.** Every `AccountError` has a sentence of its own (`crates/app/src/ui/error_text/account.rs`), picked by the variant and, for `Refused`, by the problem code.
- **Offline files.** Import Offline File reads a `tablepro-offline-*.jwt` and verifies it as an online entitlement. Signed in, a file of the same account replaces the entitlement until the next refresh, and one of another account is refused. Signed out, `account.json` keeps it with `offline_only`, the status is `AccountStatus::Offline`, and the keyring is never opened for it. The page shows the machine ID to make the file for. Sign-out removes the file with the rest of `account.json`.
- **Portal links** go to the account service the build signs in to: `/`, `/billing`, `/devices`, `/teams/<id>` and `/teams/<id>/billing`. The portal opens a team's billing to its owner only, so a team license's Billing... and its payment and ending notices link there only when `/v2/me` names the user its owner.
- **The license ask.** GSettings counts the distinct local days TablePro is in use (`usage-days`, `last-usage-day`), at launch and whenever one of its windows takes the focus; the count never leaves the computer. From the 30th day, with no license, a toast on the window in use says how many days and asks for a license, with Buy a License, which opens the pricing page and sends `upgrade_clicked` with `app-ask`; each ask sends `support_ask_shown` ([ADR 0035](0035-usage-data.md)). It comes back 90 days later, and never once a license is held: an entitlement that names a license, even one that has lapsed. It waits out the first five minutes after launch, any tab that is loading, which a running query is, and any dialog already on the window, and shows only on a connection or picker window. The day it showed is recorded as it shows (`license-ask-day`), so quitting while it shows still counts.
- **A toast, where macOS has a sheet.** The GNOME HIG says of dialogs: "Never pop up a dialog window unexpectedly. They should only ever be displayed in immediate response to a deliberate user action." A toast takes one button, so I Use It Personally, which quiets the macOS ask for a year, has no place; a toast that goes on its own asks less than a sheet that waits for an answer.
- **A local stack.** A development build takes `-Ddev_account_url`, `-Ddev_api_url` and `-Ddev_entitlement_keys` ([testing.md](../testing.md#the-app-against-a-local-stack)). `meson setup` refuses them in any other profile, and the app ignores them in a release build. Half a pair, or a key that does not parse, keeps the account from starting rather than falling back to production.

## Consequences

- The app reaches the account service only once someone signs in, or has before.
- No Use License Key: Linux has no key from an older build to exchange (clients.md, Linux).
- Teams and devices need the network; offline the page shows the plan and features from the entitlement and says the rest could not load.
- A paid feature that comes to Linux drops its "In TablePro for macOS" line and asks `AppServices::feature_access` with its code.

## Alternatives considered

- **Everything from the entitlement.** It lists no team without a seat, no role and no device.
- **The dialog on every refresh that hits the limit.** A dialog nobody asked for over the user's work; the notice offers it instead.
- **The offline file in a file of its own.** One file keeps one rule: what `account.json` holds is what the gate reads at launch.
- **The usage count in the state directory.** GSettings already keeps `last-seen-version`, the one other record of this kind, and resets with the rest of the app's settings.
- **The macOS sheet as an `AdwAlertDialog`.** The HIG rule above; a banner is for a persistent state, which an ask is not.
