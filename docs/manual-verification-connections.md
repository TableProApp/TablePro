# Manual verification: connections and SSH

Part of the [manual verification checklist](manual-verification-0.2-features.md), which holds the setup, evidence and recording rules that apply to every item here.

## Connection dialog and browse shortcuts

- [ ] Screen readers can activate Driver, Endpoint and TLS, and announce Port, Connect timeout and Query timeout. GTK AT-SPI scenario passed in Xvfb on 2026-10-13; no native Hyprland result is recorded here. The sidebar search, saved-filter name and list colour chooser are outside this connection-form check; the specific missing-name/action report in [#658](https://github.com/cozyGarage/BookiE/issues/658) was rechecked and closed.
- [ ] New connection defaults match the selected driver; no PostgreSQL defaults leak into another engine. Switching drivers and editing a saved connection preserves intended custom values. **2026-10-12 historical run:** defaults passed for all seven drivers; switching drivers reset custom port, database and username values. Fixed by [#740](https://github.com/cozyGarage/BookiE/pull/740); transition tests cover all three fields. No installed Hyprland retest is recorded here.
- [ ] For MySQL/MariaDB, select a local Unix socket and confirm the form shows a socket-file path while hiding host and port. Switch back to Network and confirm the socket path is hidden and host/port return.
- [ ] Connect through a real local MySQL/MariaDB socket, save the connection, reopen it, and confirm the socket path and endpoint mode remain selected. Export and re-import a bundle and confirm the same endpoint is retained.
- [ ] Confirm a missing or invalid socket path fails without attempting a TCP connection. Local sockets refuse TLS and SSH; existing PostgreSQL socket-directory and SSH-forwarded MySQL socket connections still work.
- [ ] The current header title and grouped Test/Connect actions fit at narrow width in light and dark; the title does not overlap the actions.
- [ ] Enter submits the form and Escape dismisses without changing saved data. **2026-10-12 Hyprland dark:** Enter failed; fixed by [#737](https://github.com/cozyGarage/BookiE/pull/737). The GTK regression covers nested entry activation; rerun the keyboard flow on installed Wayland.
- [ ] Browse shortcuts show the actual Left, Right, Space and pointer modifiers; keyboard and click actions match their labels. **2026-10-12 Hyprland dark:** failed before the shortcut window was reorganized in [#725](https://github.com/cozyGarage/BookiE/pull/725); no installed retest is recorded here.

## Production marker

- [ ] Connect to a connection marked Production: the header bar is tinted red, a red **Production** badge shows beside Read-only, and the window title starts with `[Production]` in the taskbar or Alt-Tab. Open a table and change a cell: the title reads `• [Production] …`. The badge text and the tinted bar are readable in light and dark.
- [ ] Disconnect, or connect to a Dev, Staging or Local connection: the badge, the tint and the title prefix are gone.
- [ ] A Production connection that is also Read-only shows both badges.

## Connection list

- [ ] Connections are grouped, with one section per group and an ungrouped section.
- [ ] A group that appears twice in the ordering still renders one section.
- [ ] The colour swatch shows on a tagged row and the picker sets it. **2026-10-12 Hyprland dark:** the picker saved the colour; the swatch was not checked.
- [ ] After connecting to a tagged connection, the workspace tab strip shows its colour. Changing or clearing the tag updates the strip, and disconnecting clears it. The GTK regression passes; no installed retest after [#768](https://github.com/cozyGarage/BookiE/pull/768) is recorded here.
- [ ] With Orca, open Group and tags, navigate to Colour, open the named button, choose a palette colour, and confirm the selected colour is announced and saved. Sidebar table search and the saved-filter name field announce their purpose. No native Wayland screen-reader result is recorded here.
- [ ] Duplicate produces a new row with a distinct name. When the source has a saved database password, the copy's credential form opens with an empty password field; save a new password and verify both connections work independently. **2026-10-12 historical run:** distinct name passed ("(copy)"); the copy did not reuse the password but did not ask for one either, it failed and offered Edit Connection. Fixed in [#823](https://github.com/cozyGarage/BookiE/pull/823); no installed retest is recorded here ([#660](https://github.com/cozyGarage/BookiE/issues/660)).
- [ ] The Name field in the connect dialog is used when set, and the derived `user@host` label still appears when it is blank.
- [ ] Two connections to the same endpoint stay separate after reconnecting to each. This is the regression the id-first identity change fixed.
- [ ] For MongoDB, the connect dialog shows Authentication database; save `admin` for a user defined there while Database is `appdb`, reconnect, and confirm connections with different authentication databases stay separate. **Not run.**
- [ ] On PostgreSQL, right-click a schema and hide it. Confirm its tables and views disappear, search cannot reveal them, the filter menu can restore one or all schemas, and each connection retains its own hidden-schema list after reconnecting. **2026-10-12 Hyprland dark:** hide, search and restore one schema passed; per-connection retention after reconnect not run.

## Long-query notice

- [ ] Run `SELECT pg_sleep(12)`, switch to another window: a "Query finished" notification appears when it ends. With the window focused, none appears. **2026-10-12 Hyprland dark:** the unfocused case passed ("Query finished", 12 seconds); the focused case not run.

## Per-connection timeouts

- [ ] The connect dialog shows Connect timeout and Query timeout rows; 0 means default. **2026-10-12 Hyprland dark:** passed.
- [ ] A connection saved with a 2-second query timeout stops `SELECT pg_sleep(5)` after about 2 seconds, while another connection still uses the Preferences timeout. **2026-10-12 Hyprland dark:** stopped after 2.007 s, passed; the wording was fixed by [#668](https://github.com/cozyGarage/BookiE/pull/668). No result for the second connection or installed retest is recorded here.
- [ ] A connect timeout of 3 seconds to an unreachable host fails after about 3 seconds.

- [ ] With a 2-second query timeout, run `SELECT pg_sleep(5)` on PostgreSQL (streamed) and `SELECT SLEEP(5)` on MySQL (materialized): after each, the toolbar shows **Run again with an 8s timeout**. Click it: the same query runs and completes. Running any other query removes the button, and the saved timeout is still 2 seconds.
- [ ] Edit the editor text after a timeout, then click the button: the query that timed out runs, not the new text.

## Connection bundles

- [ ] Export without a passphrase, then read the file: it contains hosts and usernames and **no** password, passphrase or token.
- [ ] Export with a passphrase, then import it on a second profile (`TABLEPRO_PROFILE=development`) and confirm the connections and their credentials arrive.
- [ ] A wrong passphrase and a file edited after export give the **same** message.
- [ ] Importing a bundle whose id already exists locally against a different server creates a new connection and leaves the local one untouched.
- [ ] The import plan lists every connection with its disposition and can be unticked before anything is written.

## Built-in SSH host keys and tunnel loss

- [ ] A new host shows its fingerprint before trust; decline/cancel writes no key and opens no database connection. Explicit acceptance persists only that key.
- [ ] A changed key is refused. Reconnect never silently learns an unknown key.
- [ ] Bastion loss retires affected editor sessions and starts reconnect promptly; a result from the old session cannot replace current state.

## SSH agent (built-in client)

- [ ] Choose "SSH agent" in the SSH section with a key loaded in ssh-agent: the connection authenticates without a password or key file prompt.
- [ ] With the agent stopped, the error says the agent could not be reached.

## System OpenSSH tunnel

Build and install with the helper (`cargo build -p tablepro-ssh --bin tablepro-askpass` beside the app binary, or an installed package).

- [ ] Turn on "Use system OpenSSH" in the SSH section and connect to a host already in `~/.ssh/known_hosts`: no prompt, the connection works.
- [ ] Connect to a new host: a "Trust this SSH host?" dialog shows the fingerprint; Cancel fails the connection and writes nothing.
- [ ] A host reached through a `ProxyJump` line in `~/.ssh/config` connects.
- [ ] A new key at a `ProxyJump` hop requires the same explicit approval as a new destination key; declining does not add the jump key to `known_hosts`.
- [ ] A saved password is used for the target host; a jump host asking for a password gets a dialog instead of the saved one.
- [ ] A PostgreSQL connection with Verify Full through the OpenSSH tunnel verifies the database hostname.
- [ ] After closing the app, no `ssh -M` process is left running.
