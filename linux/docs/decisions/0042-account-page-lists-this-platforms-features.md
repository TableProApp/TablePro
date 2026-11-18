# 0042: Preferences > Account lists only the features TablePro for Linux has

- **Status**: Accepted; the empty Features group amended by [0046](0046-share-links-and-the-tablepro-scheme.md)
- **Date**: 2026-11-07

## Context

[ADR 0038](0038-account-page-and-license-ask.md) built Preferences > Account with a Features group that lists the ten paid feature codes, each included or not by the entitlement, and each with "In TablePro for macOS", since TablePro for Linux has none of them yet. That follows tablepro-cloud's `docs/design/clients.md:103`: "While Linux has none of the ten, Features lists them all, each included or locked by the entitlement, with "In TablePro for macOS"." The rest of the page's copy promised the paid features on this computer: "Use your plan’s paid features on this computer", "Remove one to use the paid features on this computer", "Paid Features Paused". It also still called Pro by its old name, Starter (#4076, #4077).

On 2026-11-07 the maintainer decided that TablePro for Linux gets the paid features later. The licensing stays as ADR 0038 built it: accounts, plans, device slots, the entitlement, its notices and the device limit dialog. The app never says that Linux lacks a feature. Its copy speaks of the plan and the license, so it stays true today and once the features come.

## Decision

The Features group lists only the codes whose platform flag says TablePro for Linux has the feature, each included or not by the entitlement, and is hidden when it lists none; Buy a License and Learn More About Licensing move to a License group after it, and the page's copy speaks of the plan and the license, never of a feature missing here.

## Rationale

- Ten rows that each say "In TablePro for macOS", beside Upgrade…, list what this app lacks. The maintainer wants the page to describe the plan and the license only.
- The licensing keeps its foundation. Each code's flag in `FEATURES` (`crates/app/src/ui/preferences_dialog/account_view.rs`) and `AppServices::feature_access` stay. A feature that comes to Linux turns its flag on and asks `feature_access` with its code, and its row shows with Included or not, with nothing else to change.
- A Linux computer signed in to an account with a license still takes one of its 3 device slots (tablepro-cloud's `docs/design/product.md`). The device limit notice and dialog stay true, and their copy says the license is in use elsewhere and that TablePro keeps working here without it.
- The License group has a static title in `preferences-account-page.ui`, as every other group on the page does, so rendering only toggles a group's visibility.

## Consequences

- No flag is on today, so the Features group never shows on Linux. The License group carries Buy a License, signed out, and Learn More About Licensing in every state.
- ADR 0038's Features bullet is superseded, and so is its consequence that a feature coming to Linux drops its "In TablePro for macOS" line: no row has that line now.
- The notices for an entitlement close to or past its end speak of verifying the plan ("Plan Not Verified Lately", "Could Not Verify Your Plan"), since they show for a Free account too.
- Which features a plan adds is for the pricing page and the licensing guide to say, through the page's two links, not for the page itself.
- The app departs from tablepro-cloud's `docs/design/clients.md:103`, which still lists all ten with "In TablePro for macOS". That line needs a follow-up in tablepro-cloud to match this ADR.

## Alternatives considered

- **Keep the ten rows with "In TablePro for macOS"**, as ADR 0038 and clients.md have it. They tell a Linux user what the app lacks, which the maintainer ruled out.
- **Drop only the "In TablePro for macOS" line.** Ten rows marked Included or not on Linux would promise features that are not there.
- **Say on the page that the paid features are in TablePro for macOS for now**, as #4077 asked. True today, but the copy would speak of features instead of the plan and the license, and it would need rewriting the day a feature comes.
- **Retitle the Features group at render time** to hold the licensing links when it has no rows. One group with two meanings, and the only title on the page set in code.
