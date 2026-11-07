# Troubleshooting

What to check when TablePro for Linux does not behave, and what to send with a bug report. Paths are for the .deb and .rpm packages; the Flatpak's are in [Where TablePro keeps its files](#where-tablepro-keeps-its-files).

## Passwords

Native packages keep saved passwords in the Secret Service, the desktop keyring that GNOME Keyring, KWallet and KeePassXC provide. Flatpak uses the Secret portal to unlock an encrypted keyring file inside the sandbox. Neither stores passwords in plain text. For the bundle, start with [Flatpak connections](#flatpak-connections).

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

### MCP and AI keys cannot be saved or loaded

**Preferences > MCP > Enable MCP Server** needs a saved access token. **Preferences > AI** needs the saved API key for a provider that requires one. Entering a database password at each connect does not restore either feature.

- If no keyring service is available, set one up as above. Inside Flatpak, check the [Secret portal](#flatpak-connections). Quit and reopen TablePro after fixing the service.
- If the keyring is locked, unlock it in the desktop's keyring manager. Retry the setting and accept the unlock prompt. A dismissed prompt does not mean the key was deleted.
- Retry enabling MCP. If its token changed, copy the new token into each MCP client's settings. For AI, select the provider again and save its API key if it was not stored. Quit and reopen TablePro to check that it was kept.

## TablePro account

Preferences > Account signs in to a TablePro account, which lists your plan, devices and teams. Signing in uses your plan on this computer; everything else works without an account.

- **Sign In opens no browser**: TablePro asks the desktop to open the sign-in page in the default browser, through the OpenURI portal inside Flatpak. Check that one is set, under Settings > Default Apps on GNOME.
- **The browser says the sign-in finished, but TablePro still waits**: the page sends the browser back to `http://127.0.0.1` on a port TablePro picked for this sign-in. A browser that cannot reach this computer's loopback address, such as one in a container or on another machine, or a proxy setting that sends `127.0.0.1` elsewhere, never brings it back. Cancel, fix the browser, and sign in again. TablePro stops waiting after 10 minutes.
- **Signed out at every launch**: no keyring took the sign-in, so it lasts until TablePro quits; the Account page says "Sign-In Not Saved". Set up a Secret Service as for [passwords](#tablepro-asks-for-the-password-at-every-connect). The item is `TablePro account sign-in` in Seahorse.
- **Accounts Unavailable**: TablePro could not read `/etc/machine-id`, or `/var/lib/dbus/machine-id` in its place, which it hashes into the ID this computer has on your account. `systemd-machine-id-setup` makes one on a system that has none.
- **Device Limit Reached**: your license is in use on 3 other devices. To use it on this computer, remove one from the list Preferences > Account offers, or under Devices in your account. TablePro keeps working here either way.
- **A computer with no internet**: make an offline file for the Machine ID the Account page shows, in your account, then use Import Offline File.

## Usage data

The PPA and COPR packages and the Flatpak share usage data by default, as TablePro for macOS does; a build from source sends none. What it sends, to whom and when: [README](../README.md#privacy). To stop it, turn off **Preferences > General > Privacy > Share Usage Data**, or run `gsettings set app.tablepro.TablePro share-usage-data false`; events still waiting are dropped. The anonymous ID PostHog knows this computer by is in `~/.local/state/tablepro/telemetry.json`; removing that file gives a new one.

## SSH tunnels

Native packages run the system `ssh` and read `~/.ssh/config`, `~/.ssh/known_hosts` and the SSH agent the same way a terminal does. The bundle has [Flatpak connection limits](#flatpak-connections). When a native tunnel fails, try the same hop in a terminal first:

```sh
ssh -v -J jump.example.com user@bastion.example.com true
```

- **Agent sign-in fails**: TablePro uses the agent named by `SSH_AUTH_SOCK` in the desktop session. `ssh-add -l` lists the keys it holds. When it works in a terminal but not in TablePro, the desktop session has a different agent or none: `systemctl --user show-environment | grep SSH_AUTH_SOCK` shows what apps started from the desktop get.
- **Unknown host key**: TablePro shows the server's SHA256 fingerprint before it connects, even where `ssh_config` says `StrictHostKeyChecking accept-new` or `no`. Compare it with `ssh-keygen -lf` on the server's key, or with what the server's administrator gives you.
- **Changed host key**: Review Key in the connection's banner can replace the entry in `known_hosts`. Under `StrictHostKeyChecking yes` it cannot: fix `known_hosts` with `ssh-keygen -R host`, then press Retry.
- **Revoked host key**: refused, with no way past it in TablePro.

## SQL Server with Kerberos

For native packages, Windows (Kerberos) sign-in uses the ticket `klist` shows, so get one first. `kinit` and `klist` come in `krb5-user` on Ubuntu and `krb5-workstation` on Fedora. For the bundle, see [Flatpak connections](#flatpak-connections).

```sh
kinit you@EXAMPLE.COM
klist
```

- **`KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN`**: the server's service principal, `MSSQLSvc/<host>:<port>`, is built from the host and port you typed, and looked up in the default realm only (`default_realm` in `/etc/krb5.conf`). Type the host name the SPN is registered for, not an IP address or a CNAME. A server in another realm works only when your KDC answers with a referral, as Active Directory does inside a forest.
- **No ticket, or an expired one**: run `kinit` again, then Retry.

## Flatpak connections

The bundle uses the runtime's tools and configuration. A working host connection may need changes:

- **Secret portal**: install the distribution's `xdg-desktop-portal` and the backend for your desktop. Check that the session provides `org.freedesktop.portal.Secret`; having the FileChooser portal alone is not enough. Unlock the desktop keyring, accept its prompt and retry. The portal does not say why it refused, so TablePro reports any refusal as a locked keyring. With automatic login, GNOME may have no login keyring yet: create a keyring in Passwords and Keys (Seahorse), make it the default, and retry. If a portal is missing, repair the desktop's portal packages and log out and in before reopening TablePro. See [ADR 0004, Consequences](decisions/0004-libsecret-secret-storage.md#consequences) for secret storage.
- **Kerberos**: the bundle selects `/app/etc/krb5.conf`, with DNS realm and KDC lookup and the host's KCM cache. It cannot use the host's `/etc/krb5.conf` or a ticket stored only in a file. With KCM configured on the host, obtain and check a ticket there with `kinit -c KCM: you@EXAMPLE.COM` and `klist -c KCM:`. Ask the domain administrator about DNS or realm setup if that fails.
- **SSH**: `~/.ssh/config`, keys and `known_hosts` are available, but the host's `/etc/ssh` is not. `ProxyCommand` and `Match exec` cannot run host-only helpers. Use a setup the runtime supports, or a native package. A FIDO key file cannot sign inside the sandbox; load the key into the host SSH agent and choose **SSH agent**.
- **Private CA**: a CA installed only on the host may be absent from the runtime's trust store. Choose its PEM file in **CA certificate** and keep **Verify full**.

[ADR 0008, Rationale](decisions/0008-flatpak-sandbox-permissions.md#rationale) explains these grants. [ADR 0035](decisions/0035-flatpak-local-database-sockets.md) covers local PostgreSQL and MySQL sockets.

### First Flatpak app

When TablePro is the first Flatpak app on the computer, choosing it in the app menu can do nothing until you log out and in once. The desktop starts TablePro over D-Bus, and the session bus reads Flatpak's D-Bus services only from folders that existed when you logged in; installing the first app creates them. `flatpak run app.tablepro.TablePro` works meanwhile. Later installs and updates need nothing.

## Logs

Started from the desktop, TablePro writes its log to the journal:

```sh
journalctl --user --boot | grep -i tablepro
```

For a more detailed log, quit TablePro (a second launch hands over to the running one and exits), then start it from a terminal:

```sh
RUST_LOG=debug tablepro 2> tablepro.log
```

Read and redact the log before you attach it. It names your hosts, databases and tables. Error messages can also contain SQL, values or paths.

## Crash reports

TablePro writes a text report for a Rust panic on its main GTK thread, if it can write to the [crash folder](#where-tablepro-keeps-its-files). Worker-thread panics, segmentation faults, native aborts and out-of-memory kills do not produce that report.

Read the newest report before attaching it with the log from the same time. Its panic message is copied verbatim and may contain SQL, values, paths or other private data. Redact those details from the copy you share.

For a native crash on a system with systemd-coredump, list captured crashes, then inspect the matching PID from that list:

```sh
coredumpctl list tablepro
coredumpctl info <PID>
```

Send redacted metadata first, including the time, signal and app version. A raw core dump contains process memory and may hold passwords and query results. Do not attach one publicly. If a maintainer needs it, email hello@tablepro.app to arrange private transfer first.

If no core was captured, include the [journal log](#logs) from the same time. On distributions without systemd-coredump, use their crash reporter, such as Ubuntu's Apport, or system logs. Say when neither captured the failure; a missing dump is not proof that the app did not crash. [coredumpctl's manual](https://www.freedesktop.org/software/systemd/man/261/coredumpctl.html) explains its stored-core states.

The Flatpak's line tables, which turn a backtrace's addresses into files and lines, are its `.Debug` extension, from the repository it came from: `flatpak install tablepro app.tablepro.TablePro.Debug//stable`, or `tablepro-beta` and `//beta` for the beta. With flatpak-builder and the GNOME 51 SDK installed, `flatpak-coredumpctl app.tablepro.TablePro` then opens a crash's core dump in gdb with them.

## Reporting a bug

Open an issue at https://github.com/TableProApp/TablePro/issues with:

- The text from About TablePro > Troubleshooting > Debugging Information. Copy Text puts it on the clipboard. It holds the versions and no connection details.
- Where TablePro came from (the PPA, COPR, the Flatpak repository, a .deb, .rpm or Flatpak bundle from GitHub Releases, or a source build), the distribution and version, and the desktop and session (`echo $XDG_CURRENT_DESKTOP $XDG_SESSION_TYPE`).
- The log and crash report above, when there is one.

## After a downgrade

Each file TablePro keeps carries the version of its format. A build refuses a file in a format newer than it knows, and never writes over it. A format does not change with every release, so an older release still reads and changes a file a newer one wrote in the same format. The refusals look like this:

- The connection list shows "Saved connections were created by a newer version of TablePro". Reset… moves the file aside, under a name the toast shows, and starts an empty list.
- A connection's saved tabs do not reopen, and a toast says "Saved tabs could not be read" with Reset.
- The query history and saved queries say "The query history was written by a newer version of TablePro".
- Column widths and filters saved in the newer format are left as they are, and the older release does not save its own.

Installing the newer release again brings all of it back, unless it was reset.

### Going back to what the older release saved

Before a release writes a file in a newer format for the first time, it keeps a copy of the file as it was, in the same folder, named after the file, the format version it holds and the time in seconds, such as `connections.json.v1-1762300000`. It keeps the newest three copies of each file. A copy never keeps what you deleted since: a connection, query history or saved queries you delete, and history the retention setting drops, leave the copies too.

To give the older release its files back:

1. Quit TablePro. A second launch hands over to the running one, so check that no `tablepro` process is left.
2. List the copies, newest last, in the folders from [Where TablePro keeps its files](#where-tablepro-keeps-its-files):

   ```sh
   ls -ltr ~/.config/tablepro/ ~/.local/state/tablepro/ ~/.local/state/tablepro/workspaces/
   ```

3. Move the current file aside rather than deleting it. It holds what the newer release saved, and the newer release reads it again. For the history, move its `-wal` and `-shm` files with it, if they are there:

   ```sh
   cd ~/.local/state/tablepro
   mv history.db history.db.newer
   mv history.db-wal history.db-wal.newer
   mv history.db-shm history.db-shm.newer
   ```

4. Copy the newest copy back under the file's own name. For the connection list:

   ```sh
   cp ~/.config/tablepro/connections.json.v1-1762300000 ~/.config/tablepro/connections.json
   ```

5. Start the older release.

What was saved after the copy was made, such as a connection added in the newer release, is only in the file you moved aside. The Flatpak keeps the same files under `~/.var/app/app.tablepro.TablePro/`, in `config/tablepro/` and `.local/state/tablepro/`.

## Where TablePro keeps its files

| Path | What |
|---|---|
| `~/.config/tablepro/connections.json` | Saved connections, without passwords |
| `~/.config/tablepro/column_layouts.json`, `filter_settings.json` | Column layouts and filters per table |
| `~/.local/state/tablepro/history.db` | Query history and saved queries |
| `~/.local/state/tablepro/workspaces/` | Each connection's tabs, and the connections open at the last quit |
| `~/.local/share/tablepro/drafts/` | The text of each SQL editor tab |
| `~/.local/state/tablepro/crashes/` | Crash reports |
| `<file>.v<version>-<seconds>` beside a file above | A copy kept before an upgrade changed the file's format ([After a downgrade](#after-a-downgrade)) |

Preferences are in GSettings: `gsettings list-recursively app.tablepro.TablePro` lists them. `man tablepro` has the same list.

The Flatpak keeps the same files under `~/.var/app/app.tablepro.TablePro/`: `config/tablepro/`, `.local/state/tablepro/` and `data/tablepro/` in place of `~/.config/tablepro/`, `~/.local/state/tablepro/` and `~/.local/share/tablepro/`. Its preferences are listed by `flatpak run --command=gsettings app.tablepro.TablePro list-recursively app.tablepro.TablePro`, and a detailed log comes from `flatpak run --env=RUST_LOG=debug app.tablepro.TablePro 2> tablepro.log`.
