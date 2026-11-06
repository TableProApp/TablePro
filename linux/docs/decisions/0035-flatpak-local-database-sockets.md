# 0035: Flatpak access to local database sockets

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

A connection can reach PostgreSQL, MySQL or MariaDB on the same computer through the server's Unix-domain socket, which is how peer, `auth_socket` and `unix_socket` logins work. The sandbox of [ADR 0008](0008-flatpak-sandbox-permissions.md) sees none of the host's sockets: it has its own `/tmp`, its `/var/run` points at its own `/run`, and the manifest grants nothing under `/run` but the Kerberos KCM socket.

Where the packages put the socket:

| | PostgreSQL | MySQL, MariaDB |
|---|---|---|
| Debian, Ubuntu | `/var/run/postgresql` | `/run/mysqld/mysqld.sock` |
| Fedora, RHEL | `/var/run/postgresql`, and `/tmp` | `/var/lib/mysql/mysql.sock` |
| Arch | `/run/postgresql` | `/run/mysqld/mysqld.sock` |

`/var/run` is a link to `/run` on all of them.

## Decision

The stable and Devel manifests grant `--filesystem=/run/postgresql:ro` and `--filesystem=/run/mysqld:ro`.

## Rationale

- **The folder, not the file.** A server that restarts makes its socket again; a bind mount of the file would keep the old one.
- **Read-only is enough.** `connect()` works through a read-only mount; nothing in these folders is written by a client.
- **`/run`, never `/var/run`.** Flatpak refuses a path under a `/var/run` that links to `/run`, and refuses `/run` itself.
- **No lint finding.** Neither path is on the reserved list of flatpak-builder-lint's master branch.

## Consequences

- PostgreSQL on every listed distribution, and MySQL and MariaDB on Debian, Ubuntu and Arch, connect through their sockets in the Flatpak build.
- A socket under `/tmp` or `/var/lib/mysql` stays out of reach: the app says so when the socket is missing, and connecting to `127.0.0.1` still works. Granting `/var/lib/mysql:ro` would show the data folder's names, and is left to a Flathub review.
- A grant that does not exist when the app starts is skipped, so a server installed later needs the app restarted.
- Distribution packages have none of these limits.

## Alternatives considered

- **`--filesystem=/tmp`**: shares every program's temporary files with the app.
- **`--filesystem=/var/lib/mysql:ro`**: covers Fedora's MySQL, at the cost above.
- **No grant**: socket logins would work only outside the Flatpak.
