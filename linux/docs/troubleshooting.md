# Troubleshooting

What to check when TablePro for Linux does not behave, and what to send with a bug report. Paths are for the PPA and COPR packages.

## Passwords

TablePro keeps saved passwords in the Secret Service, the desktop keyring that GNOME Keyring, KWallet and KeePassXC provide. It never writes them to a file.

### TablePro asks for the password at every connect

No Secret Service is running, so there is nowhere to keep the password, and the prompt has no Remember switch. Check for one:

```sh
busctl --user list | grep org.freedesktop.secrets
```

No line means none is installed or none can start. Install one and log in again:

- GNOME and most other desktops: `gnome-keyring` (`sudo apt install gnome-keyring`, `sudo dnf install gnome-keyring`).
- KDE Plasma: KWallet (`kwallet6` on Ubuntu, `kf6-kwallet` on Fedora), which Plasma installs by default.
- KeePassXC: turn on Secret Service Integration in its settings, and leave it running.

The packages recommend one of these, so a normal install has one. A minimal install or a window manager session may not.

### TablePro asks for the password although it was saved

The keyring is locked. The desktop asks to unlock it when TablePro reads a password; if that prompt is dismissed, TablePro asks for the password instead. A keyring that never unlocks at login usually has a different password from the account, after a password change or with automatic login. Seahorse (Passwords and Keys) or KWallet Manager can change the keyring password to the login password.

Saved passwords are listed in Seahorse as `TablePro database password for …`, `TablePro SSH password for …` and `TablePro SSH key passphrase for …`.

## SSH tunnels

TablePro runs the system `ssh` and reads `~/.ssh/config`, `~/.ssh/known_hosts` and the SSH agent the same way a terminal does. When a tunnel fails, try the same hop in a terminal first:

```sh
ssh -v -J jump.example.com user@bastion.example.com true
```

- **Agent sign-in fails**: TablePro uses the agent named by `SSH_AUTH_SOCK` in the desktop session. `ssh-add -l` lists the keys it holds. When it works in a terminal but not in TablePro, the desktop session has a different agent or none: `systemctl --user show-environment | grep SSH_AUTH_SOCK` shows what apps started from the desktop get.
- **Unknown host key**: TablePro shows the server's SHA256 fingerprint before it connects, even where `ssh_config` says `StrictHostKeyChecking accept-new` or `no`. Compare it with `ssh-keygen -lf` on the server's key, or with what the server's administrator gives you.
- **Changed host key**: Review Key in the connection's banner can replace the entry in `known_hosts`. Under `StrictHostKeyChecking yes` it cannot: fix `known_hosts` with `ssh-keygen -R host`, then press Retry.
- **Revoked host key**: refused, with no way past it in TablePro.

## SQL Server with Kerberos

Windows (Kerberos) sign-in uses the ticket `klist` shows, so get one first. `kinit` and `klist` come in `krb5-user` on Ubuntu and `krb5-workstation` on Fedora.

```sh
kinit you@EXAMPLE.COM
klist
```

- **`KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN`**: the server's service principal, `MSSQLSvc/<host>:<port>`, is built from the host and port you typed, and looked up in the default realm only (`default_realm` in `/etc/krb5.conf`). Type the host name the SPN is registered for, not an IP address or a CNAME. A server in another realm works only when your KDC answers with a referral, as Active Directory does inside a forest.
- **No ticket, or an expired one**: run `kinit` again, then Retry.

## Logs

Started from the desktop, TablePro writes its log to the journal:

```sh
journalctl --user --boot | grep -i tablepro
```

For a more detailed log, quit TablePro (a second launch hands over to the running one and exits), then start it from a terminal:

```sh
RUST_LOG=debug tablepro 2> tablepro.log
```

Read the log before you attach it. It names your hosts, databases and tables. It never holds passwords.

## Crash reports

TablePro writes a report of each crash to `~/.local/state/tablepro/crashes/`. Attach the newest one to the bug report, with the log from the same time.

## Reporting a bug

Open an issue at https://github.com/TableProApp/TablePro/issues with:

- The text from About TablePro > Troubleshooting > Debugging Information. Copy Text puts it on the clipboard. It holds the versions and no connection details.
- Where TablePro came from (the PPA, COPR or a source build), the distribution and version, and the desktop and session (`echo $XDG_CURRENT_DESKTOP $XDG_SESSION_TYPE`).
- The log and crash report above, when there is one.

## After a downgrade

An older version never changes a file a newer one wrote. It refuses the file instead, until the newer version is installed again or you reset it:

- The connection list shows "Saved connections were created by a newer version of TablePro". Reset… moves the file aside, under a name the toast shows, and starts an empty list.
- A connection's saved tabs do not reopen, and a toast says "Saved tabs could not be read" with Reset.
- The query history says it could not be read.

Installing the newer version again brings all of it back, unless it was reset. Column widths and filters saved by the newer version are left as they are, and the older version does not save its own.

## Where TablePro keeps its files

| Path | What |
|---|---|
| `~/.config/tablepro/connections.json` | Saved connections, without passwords |
| `~/.config/tablepro/column_widths.json`, `filter_settings.json` | Column widths and filters per table |
| `~/.local/state/tablepro/history.db` | Query history and saved queries |
| `~/.local/state/tablepro/workspaces/` | Each connection's tabs, and the connections open at the last quit |
| `~/.local/share/tablepro/drafts/` | The text of each SQL editor tab |
| `~/.local/state/tablepro/crashes/` | Crash reports |

Preferences are in GSettings: `gsettings list-recursively app.tablepro.TablePro` lists them. `man tablepro` has the same list.
