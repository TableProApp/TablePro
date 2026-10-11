# Known limitations of BookiE 0.2

What the application does not do, or does differently from what you might expect, and the bugs we know about. Each entry names its ledger row. Draft of 2026-10-11, for the maintainer; an entry is removed when the row closes.

## Data and values

- **Full-table export is unavailable** (UI-13b). The current drivers do not have
  a verified snapshot export path, so the application refuses full-table export
  before opening the destination dialog or publishing a file. Export the current
  page or a loaded query result instead. Snapshot export support is planned.
- **Large results are capped and held in memory** (PERF-2, PERF-8). Results stop at
  1 million rows, 10 million cells or 64 MiB estimated size. The historical grid
  measurement was about 2.5 times the result memory; #518 now shares immutable
  values with materialized rows, and comparable profiling remains open. Nothing
  is streamed yet.
- **Long cells are shown as a preview** (PERF-10). A table cell over 8 KiB shows a
  typed preview and its byte count; View Value fetches the whole value by primary
  key. A table without a primary key cannot refetch.
- **Hidden-column projection still needs desktop acceptance** (PERF-9). Merged
  [#384](https://github.com/cozyGarage/BookiE/pull/384) projects hidden non-key
  columns out of the select and refuses full-row copy, row JSON and current-page
  export while those values are unfetched. Distribution Wayland/GNOME acceptance
  remains open.
- **A table without a primary key cannot be deleted from the grid** (TEST-14). There
  is no all-column fallback, by design.
- **ClickHouse ambiguous local times:** a `DateTime64` that falls in a repeated or
  missing daylight-saving hour is shown as undecodable and is never turned into a
  literal, because the instant cannot be known.
- **SQLite real numbers:** negative zero and NaN cannot be bound as parameters.
- **SQLite JSON aggregate output** can differ across system SQLite versions (TEST-25).
- **MongoDB:** browse pages are separate observations, not one point-in-time view (TEST-12); a column with mixed types is read-only; deep unfiltered `_id` keyset browse is fast in local Docker ([#493](https://github.com/cozyGarage/BookiE/pull/493)), but filtered, sorted and keyless deep pages plus installed and network acceptance remain open (PERF-3).
- **MySQL failed batches:** rollback of a failed batch is verified for InnoDB and a Docker matrix that includes MyISAM, MEMORY, CSV, ARCHIVE, `MRG_MyISAM`, BLACKHOLE, Aria and related side effects; optional or vendor engines and package acceptance remain open (B4-11).

## Editing and connections

- **SSH jump chains cannot be edited in the form** (UI-1b). They connect and run, but the form refuses to edit them until per-hop secrets, transport identity and the bundle format all land and pass together.
- **Reusable SSH profiles cannot be edited** (UI-26).
- **SQL Server with Kerberos** has a Samba AD and verified-TLS fixture that passed the Kerberos selectors; Windows AD interoperability and package acceptance remain open (B4-21).
- **DuckDB read-only flat files** need Linux and a writable directory on the same filesystem as the file (the application pins the file through a private link there). A read-only in-memory DuckDB connection is refused.

## Interface

- No code folding, multi-cursor or split panes (UI-22). Vim keys are an opt-in preference; typed vim commands in a running editor are not yet covered by an installed scenario. No preview tabs (UI-17b); history is a dialog (UI-18).
- The PostgreSQL catalog lists materialized views, routines, triggers, sequences, extensions and roles; a typed activity console is deferred and the activity dialog stays a plain result grid (UI-23).
- No server messages (NOTICE, PRINT) and no timing breakdown; timing shows elapsed time only (UI-20, PERF-4).
- No foreign key picker, enum or set pickers, or paste of tab-separated rows (UI-19).
- No database snapshots or restore (SNAP-1 accepted the feature for 0.2.x; build is SNAP-2 to SNAP-4).
- Accessibility with Orca, keyboard-only order and high contrast has not been verified (DOC-3).

## Platforms and packaging

- 0.2.0 is tested on Arch Linux with Hyprland as a native Wayland client (Omarchy Arch first). The install, upgrade and rollback pass on the real desktop is pending (PKG-1); Xvfb results do not count.
- GNOME on Debian and Ubuntu is not accepted on a real desktop yet (PKG-2), although the packages build and the installed test suite passes in containers.
- The Flatpak build installs and shows a window on a Debian 13 guest, but Flathub submission and screenshots are not done and the package is not offered (PKG-4, PKG-8).
- Windows and macOS are not supported; the application is built for Linux with GTK 4 and libadwaita.

## Known bugs

- **Installed GTK suite is intermittent on Forgejo** (TEST-31): accessibility timeouts under capacity pressure, and a separate startup restore abort when GTK logs an `AdwBin` width near minus two billion under `G_DEBUG=fatal-criticals`. It is not yet known whether the layout abort can happen outside that test setup, where GTK only warns.

## Test and CI limits

- The installed GTK suite does not pass reliably on a native Ubuntu 24.04 runner (TEST-28); it passes in the Ubuntu container.
- About 68 percent of the policy crate's and 81 percent of the core crate's mutations are caught by their own tests; the survivors are listed in the [mutation reports](evidence/test-quality-2026-10-11/policy-mutants.md) (TEST-32).
