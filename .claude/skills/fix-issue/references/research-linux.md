# Research sources: Linux

Where to find the correct behavior for the Linux app, and what counts as evidence for it. The method is in the research brief (`references/lanes.md`); this file is the sources.

## GNOME platform

- **API ground truth: the GObject Introspection files** under `/usr/share/gir-1.0/` (`Gtk-4.0.gir`, `Adw-1.gir`, `GtkSource-5.gir`, `Gio-2.0.gir`; GLib's is under `/usr/lib/<multiarch>/gir-1.0/`). Each symbol carries the version that introduced it, so `grep -n -A3 '<class name="Sidebar"' /usr/share/gir-1.0/Adw-1.gir` answers whether it is at or below the floor. The C headers say the same with `GDK_AVAILABLE_IN_4_22`, `ADW_AVAILABLE_IN_1_9` and `GTK_SOURCE_AVAILABLE_IN_5_18`.
- **The Rust bindings** gate each symbol behind a feature such as `v4_22` or `v1_9`. The workspace enables the GNOME 50 set in `linux/Cargo.toml`, so read the gate in the crate's source when the question is whether a binding exists: it is under `linux/_build/cargo-home/registry/src/` once the tree has been built.
- **The web documentation is newer than the floor.** docs.gtk.org and the GtkSourceView site document later releases than GNOME 50, and even the installed GIR files carry the odd newer symbol. A web page gives the intent; the GIR version and the feature gate settle whether TablePro can use it.
- **GNOME Human Interface Guidelines**: `https://developer.gnome.org/hig/`. For a database client the pages that matter most are header bars, sidebars, utility panes, boxed lists, list and column views, selection mode, tabs, search, menus, dialogs, toasts, banners, placeholders, keyboard and accessibility. Quote the rule; "the HIG says so" without a quote is not evidence.
- **API references**: GTK at `https://docs.gtk.org/gtk4/`, libadwaita for the floor at `https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.9/`, GtkSourceView at `https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/`, gtk4-rs at `https://gtk-rs.org/gtk4-rs/stable/latest/docs/gtk4/`, libadwaita-rs at `https://world.pages.gitlab.gnome.org/Rust/libadwaita-rs/stable/latest/docs/libadwaita/`. The Relm4 book trails the version in `linux/Cargo.lock`, so read the locked crate's source for Relm4.
- **freedesktop specifications**, for anything that talks to the desktop: Secret Service (`https://specifications.freedesktop.org/secret-service/latest/`), XDG Desktop Portal (`https://flatpak.github.io/xdg-desktop-portal/docs/api-reference.html`), Desktop Entry (`https://specifications.freedesktop.org/desktop-entry/latest/`), AppStream (validate locally with `appstreamcli validate --explain`) and the Flathub MetaInfo guidelines (`https://docs.flathub.org/docs/for-app-authors/metainfo-guidelines`).
- **TablePro's own decisions** in `linux/docs/decisions/` and `linux/ARCHITECTURE.md`: a fix must not contradict a recorded decision without saying so.

## Dependencies

The source is the crate as compiled, not a web page.

- Versions are in `linux/Cargo.lock`. A crate pinned to a git revision is in `linux/Cargo.toml`, and its checkout is under `linux/_build/cargo-home/git/checkouts/`.
- Read the crate's source at that version under `linux/_build/cargo-home/registry/src/`, with the doc comments for each item in play and what a call returns when it cannot do the job.
- System libraries the binary links (SQLite, MIT Kerberos, GTK) are the installed versions; `pkg-config --modversion <name>` gives each.
- Where the source does not settle it, measure: a test against the real engine (marked `#[ignore = "requires docker"]` when it needs a container) or a scratch Cargo project that links what we link. The workspace has no mocks, so a probe uses the real thing.

## Comparable clients

A Linux user describing how something "should" work is usually describing one of these. None of them is a GTK app, so they answer what capability users expect, never how it should look.

| Client | Why read it | Where |
| --- | --- | --- |
| DBeaver | The default database client on Linux; widest driver and dialect coverage | `github.com/dbeaver/dbeaver` |
| DataGrip | Deepest SQL tooling; take the capability, not the interaction | `jetbrains.com/datagrip` |
| Beekeeper Studio | Open source, ships Linux builds | `github.com/beekeeper-studio/beekeeper-studio` |
| DbGate | Open source, cross-engine | `github.com/dbgate/dbgate` |
| pgAdmin 4 | The PostgreSQL reference tool | `github.com/pgadmin-org/pgadmin4` |
| DB Browser for SQLite | The SQLite reference tool | `github.com/sqlitebrowser/sqlitebrowser` |

For how a surface should look and behave, read GNOME applications built on the same stack:

| Application | Read it for | Where |
| --- | --- | --- |
| libadwaita demo | One page per pattern, in its `demo` folder | `gitlab.gnome.org/GNOME/libadwaita` |
| GNOME Text Editor | A GtkSourceView editor with tabs, a sidebar and search | `gitlab.gnome.org/GNOME/gnome-text-editor` |
| GNOME Builder | Panes, a source editor, search and trees at IDE scale | `gitlab.gnome.org/GNOME/gnome-builder` |
| Loupe, Snapshot, Fractal | Rust apps with the same Meson and Cargo shape | `gitlab.gnome.org/GNOME/loupe`, `gitlab.gnome.org/GNOME/snapshot`, `gitlab.gnome.org/World/fractal` |
| Nautilus | Sidebars, column views and selection mode | `gitlab.gnome.org/GNOME/nautilus` |

None of these can be run from here, so every claim about one is confirmed from a source you read or marked inferred.
