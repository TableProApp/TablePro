# 0023: The license ask, the plan's features and the paid-feature gate

- **Status**: Accepted; amends 0008
- **Date**: 2026-11-20

## Context

[0008](0008-tablepro-account.md) signs in to the TablePro account and shows it in Settings, but nothing asked for a license, listed what the plan includes or gated a feature. The maintainer decided that what is paid on macOS is paid on Linux and Windows, with one license and one gate (ROADMAP D-02). The core already answers for a feature code: `AccountService::feature_access` from the entitlement ([core 0016](../../../core/docs/decisions/0016-tablepro-accounts.md), [core 0026](../../../core/docs/decisions/0026-the-windows-app-signs-in-through-the-ffi.md)), as `TableProAccount.Access`.

The macOS app's paid features are the ten `ProFeature` codes of tablepro-cloud's product.md. At this ADR's date the Windows app has none of them: no environment variable references, linked folders, Query Insights, result charts, Team Catalog or Team Library, Compare & Sync, Data Rewind, encrypted export or iCloud sync. Share links' Pro options follow the server's limits, as on macOS ([0009](0009-share-links.md)).

## Decision

- **One gate.** `Workbench.Gate(code)` asks the core for the code and returns what the feature shows instead, null when it is available. A paid command calls `MainWindow.RequirePlanAsync(code)` before it runs; a pane shows `Gate`'s notice in place. Nothing reads the entitlement's features by hand to decide access.
- **What a gated feature shows**, `LicenseGate` in `TablePro.App.Model`, as the macOS app's `LicensePresentation.gate`: signed out, "<feature> needs a paid plan" with what it does, Sign in... and Buy a license; an account without the feature, Upgrade plan; a plan held on other devices, Device limit reached with Open account settings, also while an older entitlement still holds; a lapsed entitlement with the feature, Settings' "Plan not verified lately" with Try again; an offline file past its end, which no refresh reaches, Open account settings; any other check that failed, "Could not verify your plan" with its error and Try again; an account that did not open, Open account settings. A plan that could not be checked never asks a paying customer to buy. A command shows it in a ContentDialog, the macOS license alert; sign in and Try again run in Settings, where their outcome shows.
- **The plan's features in Settings.** `PlanFeatures` holds the ten codes and `shared_links`, each with whether this app has it, as the Linux app's table does. Settings > Account lists only those this app has, each Included or Not included by the gate, so a lapsed plan reads as not included; today that is "Pro options for shared links". Under it, Buy a license while signed out, and Learn more about licensing.
- **The license ask**, as the macOS app's support ask: the app counts the distinct local days it is in use, at launch, when one of its windows comes to the front and each hour while one is in front. From the 30th day, without a license (an entitlement that names one, even lapsed), at least 5 minutes after launch, with no query running or page loading, no dialog open and the account restored, an InfoBar under the menu bar of the window in use says "You've used TablePro on {0} days" with the macOS text, Buy a license and I use it personally. The close button is Not now. It is recorded as it shows, so quitting with it open counts, and a license found while it shows closes it; it comes back 90 days later, a year after I use it personally, and never once a license is held. The count and the answers are in `settings.json` and never leave the computer.
- **Referrers.** The pricing page gets the macOS app's `ref`: `app-settings`, `app-ask`, `app-share` and `app-gate-<code>`.

## Rationale

- **The core's answer, not the app's.** The entitlement's expiry, the refresh's problems and an offline file are the core's to weigh; reading `Features` in the app would unlock a lapsed entitlement.
- **An InfoBar for the ask, where macOS has a sheet.** The Windows guidance keeps dialogs for what the user must read before going on and for blocking questions, and flyouts for what may be ignored ([Dialogs and flyouts](https://learn.microsoft.com/windows/apps/develop/ui/controls/dialogs-and-flyouts/)). The ask withholds nothing and may be ignored. An InfoBar stays until closed without covering the work, holds the three answers, and is where the app already words news about itself (0020).
- **A dialog for a gated command.** It answers the user's own action, as the update's install question does.
- **Only this app's features in Settings**, as the Linux app decided (its ADR 0042): rows for features the app lacks would list what is missing.
- **`TABLEPRO_LICENSE_ASK_QUIET_SECONDS`** shortens the five minutes for the UI tests, as `TABLEPRO_DATA_DIR` gives each its folder.

## Consequences

- No call site is gated yet. A paid feature that comes to Windows turns its `PlanFeatures` flag on, adds its name and description strings (`LocalizationTests` checks them), and calls `RequirePlanAsync` or `Gate` with its code.
- The app sends nothing about the ask or the gate: it has no usage data.
- The core restores the last sign-in after the account opens, so the ask waits for that first status, and never asks where the account could not start.

## Alternatives considered

- **The macOS sheet as a ContentDialog.** A blocking question nobody asked for, which the guidance above reserves for what cannot be ignored.
- **A toast with one button, as the Linux app.** The InfoBar holds I use it personally, so the year-long quiet of macOS stays.
- **All ten features in Settings, as macOS lists them.** macOS has all ten; here every row would be one the app lacks.
