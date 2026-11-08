# 0044: The tablepro command line and connection URLs

- **Status**: Accepted
- **Date**: 2026-11-08

## Context

`tablepro` was only the GTK application. GApplication read every word as a file, so `tablepro help` opened a window saying "help could not be found", and `--help` and `--version` needed the installed GSettings schema, the tokio runtime and every driver first. The macOS app has a command line over its MCP server, and the shared crate `tablepro-cli` ([core 0017](../../../core/docs/decisions/0017-command-line.md)) gives Linux the same commands over the server of [0022](0022-ai-assistant-and-mcp-server.md).

`tablepro postgresql://ada:secret@db/shop` reached file resolution, which logged the URL and showed it, password included, on the failure page. No scheme handler was registered. On a desktop with gvfs, GIO turns a URI of a scheme gvfs has no backend for into a mount spec that drops the password and every host of a MongoDB seed list but the first, before the application's `open` sees it.

Flatpak exports one command per application, the manifest's `command`.

## Decision

The one `tablepro` binary hands argv to `tablepro_cli::classify` in `main()`, before any of the GUI's setup, and runs a command there with `LinuxHost`; everything else reaches GApplication unchanged, with `open` taken off. The desktop entry claims `x-scheme-handler/<scheme>` for each scheme the core URL parser reads, every process registers those schemes with `g_vfs_register_uri_scheme` before `g_application_run`, and `open` routes a connection URL before file resolution: to the saved connection that goes where it goes after an `AdwAlertDialog`, or to the connect dialog filled from it. The command line reads the MCP token from the keyring and never makes one.

## Rationale

- **Dispatch in `main()`.** A command then needs no display, no schema and no GResource, and starts no runtime, driver or crash handler, so a command's panic never becomes a report the next launch shows. `local_command_line` runs only after `run()`'s setup.
- **Only a command word goes to the parser.** A subcommand, `help`, `-h`, `--help` or `--version` in argv[1] is the command line's. `-n`, `--gapplication-service`, `--help-all` and files stay GApplication's, so the D-Bus service and the desktop entry never meet clap.
- **Running is asked of the bus.** `NameHasOwner(APP_ID)` never starts TablePro; a call to its own name would D-Bus-activate it, and a bare activation quits after GLib's 10 s inactivity timeout.
- **The registered schemes keep the text.** The lookup returns the local VFS's file for the URI, which keeps it whole. GLib calls every registered parse-name function for every parse name, so each scheme registers one that answers only for its own links.
- **The dialog is the consent.** A link can come from any web page. A saved connection opens only after Open, with Cancel the default and the close response. Any other link fills the connect dialog, which connects only on Connect and saves only after a connect works. The link's text is never logged or shown.

## Consequences

- `tablepro --help` is the command line's, in English, since the core holds no catalog. GApplication's options, translated, are under `--help-all`, where `startup.rs` and the smoke tests now look.
- A file named like a command opens with `tablepro open` or `./name`. A word that is neither a command nor an existing file exits 2.
- `--new-window FILE` on a second launch opens the files in a window of their own. GOption collects the files, and the `open` hint `new-window` carries the choice to the running instance; before, the launch opened an empty window and dropped them.
- The .deb and .rpm install bash, zsh and fish completions printed by the built binary. The Flatpak ships none and its commands run in the sandbox, `flatpak run app.tablepro.TablePro <command>`, where the token and settings are the app's own.
- A command needs TablePro running with its MCP server on, and never starts it.

## The token, amending 0022

0022's server is unchanged: one token per user, made at the server's first start, off until the user turns it on. The command line of the same application id is a second reader of that token, through `SecretItem::McpToken`, and only reads it: a token it made would be one the running server never accepts. 0022's rejected stdio bridge stays rejected: there is no second binary and no handshake file, since the port is the GSettings key the server follows.

## Alternatives considered

- **`local_command_line` in the application.** GLib's hook for this, but it runs after the runtime, settings and drivers are built, and needs the schema.
- **A separate command-line binary.** Flatpak would reach it only through `flatpak run --command=`, and packages would put a second name on `PATH`.
- **Starting TablePro from a command.** `Activate` opens windows and races the session restore, and a bare activation quits.
- **Always Allow for trusted links, as on macOS.** A list to keep and manage in Preferences, for a step the connect dialog already makes one click.
