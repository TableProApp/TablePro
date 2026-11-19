# 0020: Updates through App Installer files, a beta channel, and the app's own check

- **Status**: Accepted; amends 0005
- **Date**: 2026-11-20

## Context

[0005](0005-distribution.md) ships one `.msixbundle` on GitHub Releases and on winget. Nothing updates an install made from the bundle, winget updates only on `winget upgrade`, and 0005 left the app without a beta channel because MSIX orders a package by its four version numbers. The maintainer chose on 2026-11-19: each release publishes an App Installer file next to its bundle, whose UpdateSettings make Windows check on its own; stable and beta are two such files at stable URLs; the app checks with `Package.CheckUpdateAvailabilityAsync` and words an update as the macOS app (Sparkle) and the Linux app (its update notice) do, with a channel setting; winget stays.

Microsoft's documentation, read on 2026-11-20:

- An install made from an App Installer file "is associated with the App Installer file", and an update of the file "is pushed to the user" ([App Installer file overview](https://learn.microsoft.com/windows/msix/app-installer/app-installer-file-overview)). The same page names GitHub release assets as a host, with the `.appinstaller` URL kept stable.
- The root element's `Uri`: "When the Uri specified in the field differs from the current file, the deployment operation will redirect to the Uri instead of the current file." Only UTF-8 with no escape characters and no non-ASCII characters is read ([AppInstaller element](https://learn.microsoft.com/uwp/schemas/appinstallerschema/element-appinstaller)).
- `OnLaunch` arrived in 1709 and `HoursBetweenUpdateChecks` and `AutomaticBackgroundTask` in 1803; `ShowPrompt`, `UpdateBlocksActivation` and `ForceUpdateFromAnyVersion` in 1903. Without `ForceUpdateFromAnyVersion` "the app can only move to a higher version" ([update settings](https://learn.microsoft.com/windows/msix/app-installer/update-settings)). `ShowPrompt` "currently shows a prompt for UWP applications but not for desktop applications" ([OnLaunch](https://learn.microsoft.com/uwp/schemas/appinstallerschema/element-onlaunch)).
- `CheckUpdateAvailabilityAsync` (1809, UniversalApiContract 7) "currently only works for applications installed via .appinstaller files", returns `Unknown` for a package with no App Installer association, and on the `Package` that `Package.Current` returns "will fail with an 'Access denied' error"; its examples take the package from `PackageManager.FindPackageForUser` ([reference](https://learn.microsoft.com/uwp/api/windows.applicationmodel.package.checkupdateavailabilityasync)).
- An update from code goes through `PackageManager.AddPackageByAppInstallerFileAsync`, "so that your regular App Installer file updates will continue to work"; managing the app's own package needs no `packageManagement` capability, and a desktop app calls `RegisterApplicationRestart` to come back after `ForceTargetAppShutdown` ([Update non-Store published apps from your code](https://learn.microsoft.com/windows/msix/non-store-developer-updates)).
- The API that changes an install's App Installer file without deploying, `AppInstallerManager.SetAutoUpdateSettings`, needs Windows 11 (UniversalApiContract 14).
- `Microsoft.Windows.SDK.BuildTools.MSIX` 1.7.251221100, which the app builds with, writes its own App Installer files in the `2017/2` schema with `OnLaunch`.

## Decision

- **Versions.** A tag is `windows-vX.Y.Z` or `windows-vX.Y.Z-beta.N`, N from 1 to 98. The package version is `X.Y.Z.N` for a beta and `X.Y.Z.99` for the release, so a beta sorts below its release and above the release before it, as the macOS build number's last two digits do. Settings shows `X.Y.Z` or `X.Y.Z-beta.N`.
- **Two App Installer files**, served from the `gh-pages` branch the macOS feed lives on: `https://updates.tablepro.app/windows/TablePro.appinstaller` for releases and `https://updates.tablepro.app/windows/TablePro-Beta.appinstaller` for betas. The beta file names the newest build of either channel, as the macOS beta feed carries every stable item. `windows/ci/appinstaller.py` writes them from the bundle's identity in the `2017/2` schema, ASCII only, and never moves a channel to a lower version.
- **On GitHub Releases** each release carries its channel's file next to the bundle, with that channel's URL as its `Uri`, so opening it installs the channel's newest build and associates the install with the channel. A beta is a GitHub pre-release.
- **UpdateSettings on the release file only**: `<OnLaunch HoursBetweenUpdateChecks="24"/>`, the macOS app's daily interval, and `<AutomaticBackgroundTask/>`, which checks every 8 hours with the app closed. The beta file has none: its installs update through the app's check.
- **The app's check**, in a packaged build only: at launch, every 24 hours while running, and from Help > Check for updates... and Settings > Software update. It reads the file the install came from, or the channel Settings chose when that is the other channel's file or there is none. When the install came from the file it reads, `CheckUpdateAvailabilityAsync` on the package from `FindPackageForUser` decides; otherwise the file's version against the installed one. The file's version words the update.
- **The wording** is the macOS app's: "TablePro {0} is available", "Last checked: ...", "Install update...", "Update channel" with Stable and Beta and its footer, and "Check for updates..." becoming "Update available..." in the Help menu; an InfoBar under the menu bar offers it. The first start of a newer version says "TablePro was updated to {0}" with What's new, as the Linux app's update notice does, and an older build records nothing.
- **Installing** asks first ("Install TablePro {0}?", Restart), then the questions Exit asks about unsaved changes, held transactions and running queries, then calls `AddPackageByAppInstallerFileAsync` with `ForceTargetAppShutdown`. Restart Manager closes the app, which writes its session as it does for any Restart Manager close, and starts the new version through the registration `AppRestart` makes at launch.
- **winget** stays as 0005 has it and lists releases only; a beta tag skips it.

## Rationale

- **Betas need four ordered numbers.** MSIX compares the four numbers and App Installer never moves an install down without `ForceUpdateFromAnyVersion`, so a beta has to sort below its release in the package version itself. The revision carries it, as the macOS build number's last two digits do; no Windows release has shipped, so the change costs no install.
- **No UpdateSettings for betas.** An install stays associated with the file it came from, and on Windows 10 only a deployment from another file moves it. Going back to Stable while on a beta newer than the release has no such deployment until a newer release ships, so with UpdateSettings in the beta file Windows would keep installing betas the user turned off. Without them, a beta install updates only through the app, which reads the channel Settings chose, and its first install from the release file moves it to that file's UpdateSettings: "Switching back to Stable keeps the beta you have until a newer release ships" holds as on macOS.
- **The file's own `Uri` on the release asset.** The redirect rule makes the release's copy install the channel's newest build and record the channel's URL, so an install from any release keeps following its channel.
- **updates.tablepro.app.** The repository's latest release stays the macOS one (0005), so `releases/latest/download/` cannot name a Windows file; GitHub Pages already serves the macOS appcast and the plugin manifest there, and serves `.appinstaller` as `application/appinstaller` from mime-db.
- **`FindPackageForUser`, not `Package.Current`**, for the check, as its reference page says.
- **The app's own read of the file.** `CheckUpdateAvailabilityAsync` answers only for the associated file and gives no version; the file names the version the headline words, and a chosen channel that is not the associated one can only be read directly.

## Consequences

- An App Installer install needs App Installer, which Windows 10 and 11 client editions ship. Windows Server has none; there the bundle installs as before and the app's check offers the update, whose install fails with App Installer's error.
- A winget or bundle install has no association. The app's check reads the chosen channel and, when the user installs an update from it, associates the install with that file.
- `release-windows.yml` writes the release's file in the bundle job, publishes it with the bundle and `SHA256SUMS`, then moves the channel files on `gh-pages` and deploys Pages; a dry run writes the change into a copy of `gh-pages`, shows it and pushes nothing. The `github-pages` environment has to deploy from `windows-v*` tags too.
- A beta tag runs no winget job; `github-release` takes the skipped job as passed only for a beta.
- The package version a user sees in Windows Settings ends in `.99` for a release.
- `UpdateSettings` live in each install's association; changing them reaches an install with its next update from the file.

## What the runner showed

- Runs [44638547787](https://github.com/TableProApp/TablePro/actions/runs/44638547787), [44639466235](https://github.com/TableProApp/TablePro/actions/runs/44639466235), [44640094804](https://github.com/TableProApp/TablePro/actions/runs/44640094804) and [44640925985](https://github.com/TableProApp/TablePro/actions/runs/44640925985) installed a dry run's bundle on Windows Server 2022 x64 and Windows 11 Arm64, which ships App Installer 1.29.379. A bundle installed with `Add-AppxPackage -Path` had no App Installer association, and `CheckUpdateAvailabilityAsync` on it returned `Unknown`. `Add-AppxPackage -AppInstallerFile` returned without installing, and `AddPackageByAppInstallerFileAsync` failed with "There are no more endpoints available from the endpoint mapper" (0x800706D9), for `file:` and `http:` App Installer files alike, on Server with App Installer 1.29.380 added, and on Windows 11 with Windows Update, BITS, Delivery Optimization, the Install Service and AppX Deployment running.
- So a hosted runner cannot install from an App Installer file, and `release-windows.yml` installs the bundle itself as before. Its packaged UI test reaches the update check, which reads the release channel's file with no association; the association, `CheckUpdateAvailabilityAsync` on an associated install and the restart after `ForceTargetAppShutdown` rest on the documentation above until a client machine runs them.

## Alternatives considered

- **A second package identity for betas**, as Windows Terminal Preview has: an install beside the release with its own data, not a setting that moves one install between channels.
- **`ForceUpdateFromAnyVersion` in the release file**, so going back to Stable reinstalls the release at once: a downgrade over data a newer beta wrote, against the macOS behavior the setting copies.
- **UpdateSettings in the beta file too**: Windows would go on installing betas after the user chose Stable.
- **`AppInstallerManager.SetAutoUpdateSettings` to move the association**: Windows 11 only, while the floor is Windows 10 1809.
- **Release assets at `releases/latest/download/`**: the latest release is the macOS one.
- **The `ms-appinstaller:` link**: disabled by default since December 2023, so the file is downloaded and opened.
- **The build tools' `GenerateAppInstallerFile`**: it writes one file per architecture build, before the two packages are bundled and signed.
