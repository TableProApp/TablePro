# House voice

Two newsletters have shipped. Match them. The checklist below is derived from them, not
invented, so when the checklist and the shipped text disagree, the shipped text wins.

## The checklist

Testable against a draft. A "no" is a rewrite, not a note.

**Framing**

1. Subject is `TablePro <version>: ` plus two or three plain items, lowercase after the colon,
   comma separated, no adjectives.
2. Every item named in the subject has its own `##` section. Nothing promised in the envelope
   arrives as a bullet.
3. The opener is one sentence naming what the release is about, in different words from the
   subject, so the second line adds something.
4. No first person. The subject of a sentence is the product, the feature, or "you". Grep for
   `\bwe\b|\bour\b|\bus\b`.
5. Nothing tells the reader what is worth their time or how they will feel. "Three things
   worth your time" and "fixes you will notice" both fail.

**Sentences**

6. No em dash. Use a comma, a period, a colon, or rewrite.
7. No semicolons, no exclamation marks, no emoji. Neither shipped letter has one.
8. No filler: seamless, robust, comprehensive, intuitive, effortless, powerful, streamlined,
   leverage, elevate, unlock, unleash, supercharge, delve, utilize, facilitate, game-changer.
9. Vague quantifiers get replaced by figures. "More than 90 other fixes", "about 400 built-in
   functions", "four of the five scopes", "200 rows of history". Not "many", "several",
   "significantly", "much faster".
10. No prose sentence over 35 words. An enumeration after a colon may run longer.
11. Name the old behaviour alongside the new one, at about one marker per two sentences. Vary
    the form: "instead of", "used to", "no longer", and the flat past tense ("Both used to
    encrypt without checking anything"). Eight "instead of" clauses in one letter is a tic.
12. Second person, present tense, active. No "will now", no "has been improved", no "is able
    to".
13. No paragraph opens with "It also". That is the connective reached for when a second idea
    is bolted onto a finished paragraph. Open with the real subject instead.
14. At least one short flat closer, three to eight words, stating a limit or a guarantee.
    "Nothing is closed for you." "Nothing leaves the Mac." "A half-written statement is never
    flagged."

**Typography and structure**

15. Backticks on every shortcut, SQL keyword, type name, identifier and literal: `Cmd+F`,
    `EXPLAIN ANALYZE`, `FOR UPDATE`, `1970-01-01 00:00:00`. Uppercase SQL keywords
    consistently. Keep it under about eight backticked tokens in one sentence.
16. Bold for menu paths (`**Database > Query Insights**`) and the first mention of a new
    proper noun. Not for run-in paragraph headlines.
17. Every heading is a plain statement or a plain name. "Query History is a drawer", "The
    sidebar is native again", "Security". No slogan, no question, no promise.
18. Image alt text describes the picture, not the feature: "The connections strip on the left,
    with the Quick Switcher open", not "Query Insights".
19. Ends with the round-up section, then the changelog link, then the download link, in that
    order. Round-up bullets are one line, one idea, ending in a full stop.

**Soft conventions.** British spelling in prose (colour, behaviour, honours) but the product's
own words for product things: the app and docs say "license", so the email says "license".
One documentation link per feature section, on its own line, written as a descriptive phrase.

## Reference A: 0.65, sent 2026-08-15, the long shape

SUBJECT: TablePro 0.65: one window per connection, readable query plans, a searchable history

# TablePro 0.65

Three big changes this release: how windows work, how you read a query plan, and how you find a query you ran last week.

---

## Every connection in one window

Open connections now share a window. Picking a connection in the strip switches the window to it instead of raising a second one, and each connection keeps its own state while it waits its turn. The grid stays scrolled where it was, the editor keeps its cursor and selection, and a half-filled sheet stays filled in.

Opening a table or query on a connection you already have open adds a tab instead of a window. Closing the last tab leaves the connection on its empty state, so Close Tab no longer takes the window with it.

![The connections strip on the left, with the Quick Switcher open](https://docs.tablepro.app/images/quick-switcher-cross-connection-queries.png)

The Quick Switcher searches tables, views, saved queries and recent queries across every connection you have open, not just the one in front of you.

[How the connections strip works](https://docs.tablepro.app/features/workspace-rail)

---

## Query plans you can read

EXPLAIN output opens in a Plan tab next to your results, so you can switch back to the data without re-running the query. Pin the plan to keep it.

![The query plan diagram](https://docs.tablepro.app/images/explain-diagram.png)

Diagrams zoom with a trackpad pinch, a two-finger double tap, or Cmd and scroll. They fit to the window, copy, and export as a PNG. Cost badges change shape as well as colour, so the expensive steps read without relying on colour.

![The query plan tree with the detail panel](https://docs.tablepro.app/images/explain-tree.png)

The tree view has resizable, sortable Operation, Cost, Rows and Actual Time columns, arrow-key navigation, and a detail panel for the selected step.

MySQL `EXPLAIN FORMAT=TREE` and `EXPLAIN ANALYZE` now render this way, along with PGlite, Cloudflare D1, libSQL and Turso. The Stop button cancels a running `EXPLAIN ANALYZE`, and Safe Mode asks before one runs.

---

## Query History is a drawer

Query History is a resizable drawer that opens per connection and remembers its height, its filters, and whether it was open. Entries group by day and load in pages, so history older than the last few hundred queries is reachable for the first time.

Filter by where a query came from: what you typed, EXPLAIN runs, the SELECTs the app generates while you browse, grid edits, structure changes, imports, and AI or MCP clients. Filter to failures only, or by last hour, today, last 7 days or last 4 weeks. Search matches as you type.

Arrow keys move through entries and Return loads one into the editor. A pause button stops recording from every source when you need it off.

[Query History documentation](https://docs.tablepro.app/features/query-history)

---

## The sidebar is native again

The object list is a real outline in every layout, so selection is drawn properly, arrow keys move between objects, and typing a name jumps to it. Procedures, functions, Redis keys and Recent entries can be selected too. The Favorites tab works the same way.

Clicking a table opens it right away instead of waiting out the double-click interval. Shift-click and Cmd-click select several databases or schemas to drop, refresh, copy or export at once. Row size follows Sidebar icon size in System Settings, with an override in General settings.

The bar at the bottom of the sidebar is gone. New Table and New View moved to the Database menu and the right-click menu, schema switching is Database > Schema, and the database filter is View > Filter Databases.

---

## Autocomplete for PostgreSQL and MongoDB

PostgreSQL autocomplete now covers the operators, including `::`, the JSON ones, array and range containment, regex and full-text search, about 400 built-in functions, and multi-word syntax such as `ON CONFLICT DO UPDATE SET`. Compare against an enum column and it offers the labels the type declares.

MongoDB gets autocomplete for the first time. `db.` lists collections, a collection lists the driver methods, and inside a query you get field names, nested paths such as `address.city`, and the operators valid in that spot.

The editor also underlines structural mistakes as you type, such as an unmatched bracket or an unterminated comment. A half-written statement is never flagged.

---

## MongoDB and PostgreSQL data types

Turn on Legacy UUID Encoding and binary UUIDs written by the Java, C# or Python drivers read as UUIDs instead of hex. Filters, edits and MQL exports write the same bytes back. MQL export now writes `ObjectId(...)`, `ISODate(...)` and `BinData(...)`, so running the script inserts the same types back.

PostgreSQL array columns of a simple type, including enum arrays, get a list editor in the data grid: one row per element, with reordering, add, remove and NULL per element.

---

## Security

- SQL Server Verify CA and Verify Identity check the certificate for real on Mac. Both used to encrypt without checking anything.
- ClickHouse Verify CA reads a PEM certificate authority file and refuses to connect when it cannot be read, instead of falling back to the public root store.
- Mobile checks the SSH host key before sending any credential, and asks the first time it sees a server.
- libssh2 is patched against CVE-2026-55199.
- Query parameter values are no longer written to the history database, and existing ones are deleted on upgrade.
- An MCP client can no longer read a connection it was not allowed to reach by naming it directly.

---

## Mobile

SSL settings for MySQL, PostgreSQL and Redis, with a mode picker plus CA, client certificate and client key from a PEM file, pasted text, or PKCS#12. Redis and Valkey ACL users can sign in. Remote connections stay open when you switch apps, and editing a connection no longer wipes its SSL settings.

---

## Everything else

More than 90 other fixes: the toolbar no longer rebuilds when you switch connection, a failed query shows the database's error again, sidebar and inspector widths are remembered per window, and DuckDB in-memory tables show up in the sidebar.

[Read the full changelog](https://docs.tablepro.app/changelog)

[Download TablePro](https://tablepro.app/download)

## Reference B: 0.64, sent 2026-08-10, the short shape

SUBJECT: TablePro 0.64: one click between every open connection

## TablePro 0.64 is out

Update from **TablePro > Check for Updates**, or download it below.

[Download TablePro 0.64](https://tablepro.app/download)

---

### Every connection you have open, one click away

![The workspace rail beside the object browser](https://license.tablepro.app/storage/IvOfAeOoMv20J3uCuA8HfCTQSbjNMKPOP8VYAni8.jpg)
TablePro 0.64 adds the **workspace rail**: a strip on the leading edge of the window that lists every connection and database you have open. Switching takes one click, instead of a trip back through the connection list or the database picker.

Each icon is the database engine's symbol, tinted with the connection's color, so staging and production are easy to tell apart. The icon changes shape when a session fails or drops, so a dead connection is visible without hovering. The workspace you are looking at is highlighted.

An entry appears when you open a connection, or when you switch database and leave work behind in the one you came from. It goes away when its last tab closes. Nothing is closed for you.

The rail has its own shortcuts and full keyboard control. Hide it with `Cmd+Option+0`.

[Download TablePro 0.64](https://tablepro.app/download)

Already have TablePro? **TablePro > Check for Updates**.

---

### Also in 0.64

- Each connection gets its own window, and a tab stays bound to the database it was opened on.
- The menu bar is rebuilt on native macOS menus, with a new Database menu. `Cmd+F` searches whatever is in front of you.
- Match Case in filter operators, on every database that can express it.
- Oracle SYSDBA and SYSOPER logons, and Oracle in TablePro Mobile.
- Disconnect and Reconnect a session without closing its window.
- Sparkle updated to 2.9.5, patching CVE-2026-47121 and CVE-2026-47122 in the updater.

[Read the full changelog](https://docs.tablepro.app/changelog)

## Reading the two together

0.65 runs about 1,030 words across eight sections, 0.64 about 300 across two. The length
follows the release, not a target. What does not change between them: the opener names
content, the headings are flat, the old behaviour sits next to the new one, the numbers are
real, and the last three lines are always round-up, changelog, download.
