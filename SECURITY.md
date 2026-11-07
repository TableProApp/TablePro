# Security Policy

## Reporting a vulnerability

Report it privately through [Report a vulnerability](https://github.com/TableProApp/TablePro/security/advisories/new), or email **hello@tablepro.app**. Do not open a public issue, discussion or pull request for a vulnerability.

Include:

- What is affected and its version or source commit: the Mac app, the iPhone and iPad app, the Linux app, the Windows app in development, the shared Rust core, a plugin, or tablepro.app.
- The operating system and version, the Linux distribution and install source when relevant, and the database type when a driver is involved.
- Steps to reproduce, or a proof of concept.
- What an attacker gains: the data or access exposed.

Write in English or Vietnamese.

## Scope

- The Mac app.
- The iPhone and iPad app.
- The Linux app, releases and betas (`linux-vX.Y.Z-beta.N`) alike: from the Launchpad PPAs, the COPR projects, the Flatpak repositories at `flatpak.tablepro.app`, the .deb, .rpm or Flatpak bundle on a GitHub release, or a source build of a `linux-v*` tag.
- The Windows app in development and the shared Rust core used by Linux and Windows. Include the source commit when reporting an unreleased build.
- The plugins, bundled with the app or installed from the [plugin registry](https://docs.tablepro.app/features/plugins).
- The website, [tablepro.app](https://tablepro.app).

## Supported versions

- The Mac app: the newest release line, plus security fixes on the line before it ([apple/RELEASING.md](apple/RELEASING.md#branches)). Plugins ship with the app and follow it.
- The Linux app: the latest release, and the latest beta while it is newer than that release.
- The iPhone and iPad app and the website: the latest release only.

Windows has no released version yet. Reports about its development builds and the shared core are welcome through the same private channels.

A fix for a released app ships in a new release and is listed under **Security** in [apple/CHANGELOG.md](apple/CHANGELOG.md), or in [linux/CHANGELOG.md](linux/CHANGELOG.md) for the Linux app. Check that the problem is still in a supported version before you report it.
