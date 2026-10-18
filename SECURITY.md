# Security Policy

## Reporting a vulnerability

Report it privately through [Report a vulnerability](https://github.com/TableProApp/TablePro/security/advisories/new), or email **hello@tablepro.app**. Do not open a public issue, discussion or pull request for a vulnerability.

Include:

- What is affected and its version: the Mac app, the iPhone and iPad app, the Linux app, a plugin, or tablepro.app.
- The macOS or iOS version, or the Linux distribution and where the app came from, and the database type when a driver is involved.
- Steps to reproduce, or a proof of concept.
- What an attacker gains: the data or access exposed.

Write in English or Vietnamese.

## Scope

- The Mac app.
- The iPhone and iPad app.
- The Linux app, from the Launchpad PPA, the COPR project or a source build of a release.
- The plugins, bundled with the app or installed from the [plugin registry](https://docs.tablepro.app/features/plugins).
- The website, [tablepro.app](https://tablepro.app).

## Supported versions

- The Mac app: the newest release line, plus security fixes on the line before it ([RELEASING.md](RELEASING.md#branches)). Plugins ship with the app and follow it.
- The iPhone and iPad app, the Linux app and the website: the latest release only.

A fix ships in a new release and is listed under **Security** in [CHANGELOG.md](CHANGELOG.md), or in `linux/CHANGELOG.md` for the Linux app. Check that the problem is still in the latest release before you report it.
