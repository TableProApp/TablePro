# SAP HANA Driver Plugin

This plugin connects TablePro to SAP HANA Cloud and SAP HANA 2.0 through [SAP/go-hdb](https://github.com/SAP/go-hdb), a native implementation of the HANA SQL wire protocol. It needs no SAP HANA Client, ODBC, SQLDBC or local SAP install.

The Go bridge in `Native/HanaBridge` is built by `scripts/build-hana.sh` into `tablepro-hana-helper`, an executable with no cgo. The plugin carries it in `Contents/MacOS`, starts one helper for each session, stops it when the session closes, and talks to it over stdin and stdout in length-prefixed JSON frames. The metadata connection pool opens drivers of its own, so one connection can run several helpers. A crash in go-hdb ends that driver's session, not TablePro. The helper owns the HANA session and returns JSON, and the Swift side writes every message the user reads.

Xcode copies the helper into the bundle and does not build it. Run `scripts/build-hana.sh` with no argument, which builds a universal arm64 and x86_64 helper, before building `HanaDriver`, `HanaDriverTests` or `AllPlugins`. A thin build, `scripts/build-hana.sh arm64` or `x86_64`, only works in a build of that one architecture. `scripts/build-plugin.sh` signs the helper with Developer ID, the hardened runtime and a timestamp before it signs the plugin.

What the plugin does:

- User name and password login, with TLS in every TablePro mode. Preferred and Required encrypt without checking the certificate, Verify CA checks the chain only, and Verify Identity checks the chain and the host name, against the system roots unless a CA file is set. A client certificate and key can be added for mutual TLS. The TLS Server Name field overrides the name checked by Verify Identity when the certificate names another host.
- Schema browsing, columns with full types, primary keys, identity and generated columns, indexes, foreign keys, row counts, table DDL and view definitions.
- SQL execution with bound parameters, so grid edits, inserts and deletes work.
- Stop and the query timeout. Both send `ALTER SYSTEM CANCEL SESSION` for the connection's own session, which keeps the session open. The bridge closes the session instead, and TablePro reconnects, when the server refuses the cancel or does not answer it within 10 seconds, or when the statement is still running `hana.ForcedSeverGrace` (30 seconds) later. After Stop, and not after a timeout, the plugin also stops the helper when the operation is still pending 10 seconds past that grace, which the helper announces as `forcedSeverGraceSeconds` in its first frame.
- `EXPLAIN PLAN FOR` runs as one step that saves the plan, reads it and deletes it again. Reading plans needs the `OPTIMIZER ADMIN` privilege on recent HANA versions.

Not supported: structure editing, transactions, LDAP, JWT and SSO logins. Large object values longer than 64 MiB are cut short, and the result says so. A reply frame holds at most 2 GiB - 1 bytes, so a larger result comes back as an internal error, "the result is larger than 2 GiB".
