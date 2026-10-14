# 0008: Flatpak sandbox permissions

- **Status**: Accepted
- **Date**: 2026-10-14

## Context

The Flatpak build runs in a sandbox that starts with no access to the user's files, sockets or session services. TablePro opens SQLite databases in place, runs the system OpenSSH client for tunnels ([ADR 0013](0013-openssh-client-transport.md)), signs in to SQL Server with Kerberos, and keeps passwords in the Secret Service ([ADR 0004](0004-libsecret-secret-storage.md)). Flathub's linter refuses broad grants unless Flathub has granted the app an exception for each one.

The first manifest also granted `--filesystem=/etc/krb5.conf:ro` and `--talk-name=org.freedesktop.secrets`.

## Decision

`build-aux/flatpak/app.tablepro.TablePro.Devel.json` grants the network, the display, the home folder and the mount points of removable drives, the SSH agent socket and the Kerberos KCM socket, and nothing else. Everything a portal covers goes through the portal.

| Grant | Why |
|---|---|
| `--share=network` | Database servers and SSH bastions. |
| `--share=ipc`, `--socket=wayland`, `--socket=fallback-x11`, `--device=dri` | The GTK display and GPU rendering. |
| `--filesystem=home`, `--filesystem=/media`, `--filesystem=/run/media`, `--filesystem=/mnt` | SQLite databases, and `~/.ssh` for ssh. |
| `--socket=ssh-auth` | Keys held by the user's SSH agent, including FIDO keys. |
| `--filesystem=/run/.heim_org.h5l.kcm-socket`, `--env=KRB5_CONFIG=/app/etc/krb5.conf` | Kerberos tickets in the KCM cache. |

## Rationale

- **SQLite needs the folder, not the file.** SQLite opens a database read-write and creates `-journal`, `-wal` and `-shm` files beside it. The document portal exports only the file the user picked: a file created next to it stays inside the portal and never reaches the real folder, so another program never sees the WAL, and a crash can leave a journal that the next open cannot find to roll back. The FileChooser portal hands the app the real path when the app can already reach the file, so a file picked or opened with Open With under home or a removable drive opens in place. A database from a folder the grants do not cover still arrives through the portal, and the app asks whether to open it read-only, as it does for one on a network share.
- **ssh reads `~/.ssh`.** The OpenSSH client reads `~/.ssh/config`, identity files and `known_hosts`, and writes new host keys there. The home grant covers it; a separate `~/.ssh` grant would add nothing.
- **Agent keys sign on the host.** `--socket=ssh-auth` forwards `SSH_AUTH_SOCK`. A FIDO key kept in a file cannot sign inside the sandbox, since the runtime has no `ssh-sk-helper`; the same key loaded into the host agent can.
- **Kerberos uses the app's own configuration.** `/etc` is reserved for the runtime, so the host's `/etc/krb5.conf` cannot be granted. The app installs `build-aux/flatpak/krb5.conf` to `/app/etc/krb5.conf`, which uses the KCM cache and DNS realm and KDC lookup, and `KRB5_CONFIG` selects it.
- **Portals cover the rest.** oo7 uses the Secret portal inside a sandbox, so `org.freedesktop.secrets` is not needed and the app cannot read other apps' secrets. Export destinations and CA files outside home go through the FileChooser portal, Reveal in Files and links through OpenURI, completion alerts through the Notification portal, and offline detection through the NetworkMonitor portal.

## Consequences

- Two lint findings are expected: `finish-args-home-filesystem-access` and `finish-args-has-socket-ssh-auth`. `build-aux/flatpak/lint-exceptions.json` lists them for `app.tablepro.TablePro` and for the Devel ID, and every lint passes it with `--exceptions --user-exceptions`, so any other finding fails.
- Before the first Flathub submission, maintainers ask Flathub for the same two exceptions with the reasons above. Flathub's builders apply only the exceptions Flathub granted.
- The removed grants stay removed: `/etc/krb5.conf:ro` is a reserved path that Flatpak never granted, and the Secret Service talk-name exposed the whole keyring.
- A `ProxyCommand` or `Match exec` that runs a host program, the host's `/etc/ssh` and FIDO keys kept in files do not work in the Flatpak build ([ADR 0013](0013-openssh-client-transport.md)). Distribution packages have none of these limits.

## Alternatives considered

- **Document portal only**: one file per grant, with no journal or WAL beside it.
- **`--filesystem=host`**: wider than home and the media mount points, with no use the narrower grants miss.
- **`--filesystem=~/.ssh:ro`** instead of home: ssh works, but no SQLite file opens in place.
- **`--filesystem=host-etc:ro` with `KRB5_CONFIG=/run/host/etc/krb5.conf`**: MIT Kerberos refuses a configuration whose `includedir` is missing, and many hosts' files have one.
- **Keeping `--talk-name=org.freedesktop.secrets`**: unused once oo7 talks to the portal.
