# 0055: Managed policies for the sync provider and tablepro.app traffic

- **Status**: Accepted
- **Date**: 2026-11-25

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md), App configuration, names six policy keys and one channel per platform. What reads them today:

- The Mac reads `minimumSafeModeLevel`, `AccountServerURL` and `AllowOtherAccountServers` (`apple/TablePro/Core/Services/Policy/ManagedPolicy.swift`). It does not read `UsageDataAllowed`, `PluginCatalogAllowed` or `ICloudSyncAllowed`.
- iOS, Linux and Windows read no policy. Windows passes nulls for the server policy (`windows/src/TablePro.Interop/Mapping.Account.cs`).
- No key forces or forbids TablePro Sync. `ICloudSyncAllowed` can only take iCloud away.
- A Mac held to a company server still reaches tablepro.app hosts: a share link is read from tablepro.app ([0047](0047-the-apple-apps-sign-in-through-the-core.md), Shared links), and the AI catalog refreshes from updates.tablepro.app ([0049](0049-ai-model-catalog.md)).
- A self-hosted install has two switches, `passwordSync` and `historySync` (0044, Policies). None keeps personal data off the install while Team Library runs.

## Decision

- One list-valued key, `PersonalSyncProvider`, names the sync providers a device may use for personal data. One entry forces that provider; several allow those and forbid the rest.
- `AllowOtherAccountServers=false` with a company server also stops share-link reads and the AI catalog refresh.
- The Mac reads `UsageDataAllowed`, `PluginCatalogAllowed` and `ICloudSyncAllowed`. iOS, Windows and Linux read every key that applies to them.
- A self-hosted install gains a third switch, `personalSync`, on by default.

This amends 0044 (App configuration, Policies), 0047 (Shared links) and 0049 (Where it lives). The key table below replaces 0044's; 0044's channel table stays.

## Keys

| Key | Type | macOS | iOS | Windows | Linux | Effect |
| --- | --- | --- | --- | --- | --- | --- |
| `AccountServerURL` | string | yes | yes | yes | yes | The company server, an https URL (0047, The server) |
| `AllowOtherAccountServers` | boolean | yes | yes | yes | yes | `false` with `AccountServerURL` hides tablepro.app and manual entry (0047), and stops share-link reads and the AI catalog refresh (below) |
| `PersonalSyncProvider` | list of strings | yes | yes | yes | yes | The providers a device may use for personal data (below) |
| `UsageDataAllowed` | boolean | yes | yes | yes | yes | `false` turns usage data off and locks the switch |
| `PluginCatalogAllowed` | boolean | yes | no | no | no | `false` stops requests to the plugin registry. Only the Mac has one ([0025](0025-linux-and-windows-link-their-drivers.md)) |
| `UpdateChecksAllowed` | boolean | no | no | yes | yes | `false` stops the app's own update checks; Linux makes none today. The Mac keeps Sparkle's keys (below) |
| `ICloudSyncAllowed` | boolean | yes | yes | no | no | `false` removes the iCloud provider and iCloud Keychain sync (below) |
| `minimumSafeModeLevel` | string | yes | no | no | no | A Safe Mode floor. Its spelling predates 0044 and stays, since profiles in use carry it |

A boolean key that is `true` or absent leaves the person's own setting. Each host reads its channel and passes the raw values to the core, which applies them, as 0044 has it for the server.

| Type | macOS profile | iOS AppConfig | Windows registry | Linux `policy.json` |
| --- | --- | --- | --- | --- |
| Name | `com.TablePro.policy.<key>` in `com.TablePro` | `<key>` in `com.apple.configuration.managed` | Value `<key>` under `SOFTWARE\Policies\TablePro\TablePro` | Member `<key>` of the top-level object |
| string | `<string>` | `string` | `REG_SZ` | string |
| boolean | `<true/>` or `<false/>` | `boolean` | `REG_DWORD` 1 or 0 | `true` or `false` |
| list of strings | `<array>` of `<string>` | `stringArray` | Subkey `<key>` with `REG_SZ` values named `1`, `2`, ..., as an ADMX `<list>` with `valuePrefix=""` writes them | array of strings |

- A value of another type counts as absent, and the host logs why. The Mac already refuses a number where a boolean belongs.
- On Windows each key is read from `HKLM`, then from `HKCU`. The first that has it wins, and a list is never merged across the two.
- The ADMX gives a text box for a string, an enabled or disabled policy for a boolean, and a list box for a list. Its ADML names the values.

## PersonalSyncProvider

- **Values:** `off`, `icloud` and `tablepro-sync`, spelled exactly. An unknown value is skipped and logged.
- **The choices.** The entries this build and platform offer are the choices its picker shows: Linux and Windows have no `icloud`, and a build without TablePro Sync has no `tablepro-sync`. The list is a set, so order and repeats mean nothing.
  - **One choice left:** it is the device's provider, and the picker is locked.
  - **Several:** the person picks among them. A device on a provider that is still allowed keeps it.
  - **None,** from an empty list or entries that do not apply here: personal sync is off, and the picker is locked.
- **What also removes a choice.**
  - `ICloudSyncAllowed=false` removes `icloud`.
  - A self-hosted server with `personalSync` off removes `tablepro-sync` while the device is signed in to it.
- **Leaving a provider.** When the provider in use is no longer allowed, it stops at once with no last pass, and the device keeps its data and its unsent edits. A single remaining choice is then taken for the person; otherwise they pick one.
- **Forced TablePro Sync still asks before its first upload.** The device stays off until the person signs in to a server that grants `service_sync`, confirms the upload (the move off iCloud in 0054, for a device on iCloud) and sets up the recovery key (0053). A forced iCloud starts as the person's own switch does.
- **Team Library is not a personal provider.** No value of this key starts or stops a team scope.
- **Which server.** TablePro Sync goes to the server the person is signed in to. An organization that wants personal data on its own server pairs `tablepro-sync` with `AccountServerURL` and `AllowOtherAccountServers=false`.
- **One rule.** The core's sync engine works out the choices from the raw list, the other keys and the server's policies, so every app shows the same choices for the same profile.

## Requests to TablePro hosts

The core's server resolution decides one case, and the account reports it to the host: `AllowOtherAccountServers` is `false`, and `AccountServerURL` is a valid origin that is not tablepro.app's. That is the case in which 0047 refuses `choose_server`. In it, the apps make no request to a tablepro.app host:

- **Share links.** A share-link read fails with `account.server_managed` before any request, and the app says the organization does not allow links from tablepro.app.
- **AI catalog.** The refresh is skipped, and the newer of the bundled and kept copies serves (0049).

`AllowOtherAccountServers=false` alone, or with tablepro.app's own origin, stops nothing more, since 0047 ignores the key alone. A host whose read is still its own code, as the Mac's share client and catalog are today, asks the account rather than reading the keys again.

| Request | Apps | Stopped by |
| --- | --- | --- |
| Sign-in, entitlement, devices, Team Library and share management on tablepro.app | all | `AccountServerURL` with `AllowOtherAccountServers=false` (0047) |
| Share-link reads and the AI catalog (`updates.tablepro.app/ai/models-v1.json`) | all | The same pair, as above |
| Plugin registry (`updates.tablepro.app/plugins/v3.json`) and the downloads it lists | macOS | `PluginCatalogAllowed=false` |
| Update feed (`updates.tablepro.app/appcast.xml`) | macOS | Sparkle's `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` in the same profile |
| App Installer feed (`updates.tablepro.app/windows/`) | Windows | `UpdateChecksAllowed=false` |
| Usage data, sent to PostHog and not to a TablePro host | each app that sends it | `UsageDataAllowed=false` |

## The Mac's new keys

- **`UsageDataAllowed=false`.** Usage data stops, and General's Share Usage Data switch shows off, locked, and managed by the organization.
- **`PluginCatalogAllowed=false`.** No manifest is fetched, so nothing installs or updates from the registry. Plugins already installed keep loading. A connection whose driver is a registry plugin not yet installed says the organization manages plugins.
- **`ICloudSyncAllowed=false`.**
  - `icloud` leaves the choices. CloudKit sync stops at once, and the iCloud zone stays.
  - Keychain items are written device-only from then on. Synchronizable items already written stay, since deleting one deletes it on every device, and both forms stay readable.
  - Apple's `allowCloudKeychainSync` restriction governs iCloud Keychain as a whole. This key governs what TablePro writes.

## The self-hosted `personalSync` switch

- **What it is.** A third install-wide setting beside `passwordSync` and `historySync`, on by default. The owner or an admin sets it in the portal, and each change is audited, as with the other two (0044, Policies).
- **Off.** The personal and history scopes answer pushes with `rejected` (`policy`) and their records are tombstoned for policy, whatever `historySync` says. Devices keep what they hold. The install then serves Team Library only. 0051 gives the wire for all three switches.
- **The apps.** `tablepro-sync` leaves the personal choices while the device is signed in to that server, so a device on it stops as Leaving a provider says.
- **The SaaS has no such switch.** Personal and history scopes belong to the account, which can be in several teams (0044, Policies).

## Consequences

- The policy key list lives here, and 0044 keeps the channels. A key added later adds a row to the Keys table.
- A build older than the one that reads a key ignores it. An organization that relies on a key requires that build through its MDM.
- A Mac held to a company server opens no share link from tablepro.app, and its AI catalog stays at the bundled or kept copy until the next app update.
- A Mac without the registry has only bundled and installed plugins. An organization that needs a registry plugin installs it before it sets the key.
- A forced TablePro Sync on a device that is not signed in leaves personal sync off, and the settings say why.
- `UpdateChecksAllowed` and `minimumSafeModeLevel` keep their scope: this ADR adds no platform to either.

## Alternatives considered

- **Two keys, a forced provider and a forbidden list.** They can disagree, and one list says both.
- **`off` always allowed.** An organization that requires sync could not say so.
- **One boolean per provider.** Booleans cannot force a provider, and `ICloudSyncAllowed` already takes iCloud away.
- **Stop every TablePro request under `AllowOtherAccountServers=false`.** Updates and the plugin registry have their own keys, and an organization may hold the server and still take updates.
- **A separate key for share links and the catalog.** An organization that keeps its people off tablepro.app accounts wants no tablepro.app traffic, so the pair that already says so covers it.
- **A `personalSync` switch per SaaS team.** A team does not own an account's personal or history scope.
