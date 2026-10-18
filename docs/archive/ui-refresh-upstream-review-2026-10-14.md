# Settings and icon review: 2026-10-14

This review covers recent upstream changes relevant to the Linux Settings,
About and icon polish. Linux behavior is assessed against the current BookiE
implementation; macOS-only UI is not copied as source.

## TablePro 0.80

Source: [release notes](https://github.com/TableProApp/TablePro/releases/tag/v0.80.0).

| Upstream change | BookiE evidence | Decision |
| --- | --- | --- |
| Custom icons for connections and groups; group name, icon, color and parent editing (#3309, #3313) | Connection colors already exist; saved connection metadata has no icon field | Defer as a separate connection-library feature because it needs a persistence and import/export design, not a Settings-only polish change |
| Filter Schemas and catalog query performance (#3343) | PostgreSQL schema visibility can already be changed from the sidebar and hidden schemas persist with workspace state; issue #580 tracks catalog performance | Keep #580 as the performance work item; do not duplicate the existing visibility control |
| Settings deep links (#3322) | Preferences pages exist, but no settings-link protocol is part of the current Linux product surface | Defer until a Linux URI/deep-link feature is planned |
| Result filter and selection persistence (#3329) | Current changelog records Linux result-filter, sort and selection persistence | Treat as covered behavior and retain its regression tests |

The existing launcher SVG already presents the BookiE open-book and grid mark
at scalable resolution and is shared by Flatpak, Arch and embedded resources.
Keep that identity. The UI change adds the standard
`preferences-desktop-appearance-symbolic` icon to a dedicated Appearance page.

## DBX

Sources: [latest release](https://github.com/t8y2/dbx/releases),
[contributing guidance](https://github.com/t8y2/dbx/blob/main/CONTRIBUTING.md),
and [issue #10374 with fix #10375](https://github.com/t8y2/dbx/issues/10374).

The latest reviewed release is v0.6.31. Its release notes focus on plugin AI
text generation, precise backup table selection and SQL Server temporal-table
DDL; they do not add a Settings, About or app-icon pattern that maps directly
to this pass. Issue #10374 reports UI stalls from rewriting a large local
debug-log value during editor interactions, fixed by #10375. This is a useful
performance test lesson, but its webview/localStorage implementation has no
matching BookiE UI path to port.

## Applied outcome

BookiE separates appearance from data browsing, keeps all current preference
storage and live-apply behavior, and clarifies the existing settings groups.
The About dialog names BookiE contributors and the upstream TablePro authors
separately while retaining the upstream copyright attribution. No new
preference or connection metadata field is introduced.
