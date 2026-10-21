# TablePro source inventory, October 21

Source pin: `9541927e2d8336ef425c7005ba2254982e423b8f`. Previous review: `c584da5a763014e154b7386dbe7e3ec9811a53d4`. BookiE pin: `be3ce4099`.

This is source inventory, not test execution evidence. Selected source files and PR bodies were read; the complete diff was not audited. Upstream checkout was read with `git show`, without executing its build or test scripts.

## Commit subjects screened

| Commit | Subject | Changes Linux |
|---|---|---|
| [b98b5f097dea](https://github.com/TableProApp/TablePro/commit/b98b5f097deaa506080682757c64f70f997be7bc) | feat(ios): sign in with AWS IAM and Google Cloud IAM on iPhone and iPad (#3689) | No |
| [a420dda83ab9](https://github.com/TableProApp/TablePro/commit/a420dda83ab9890a3f1404d7b79eb126aae3084a) | feat(datagrid): refuse a grid save that would send an UPDATE or DELETE without a WHERE (#3700) | No |
| [3815932f9310](https://github.com/TableProApp/TablePro/commit/3815932f9310fea0422497dc9a5e7a52b3384223) | fix(connections): reopen every strip entry, leaving canceled and disconnected ones not connected (#3701) | No |
| [8f634d92dc30](https://github.com/TableProApp/TablePro/commit/8f634d92dc30b7ae41aba9ae155c42e83e581559) | feat(connections): name the Local Network permission when it blocks a connection (#3699) | No |
| [277b8a03c3f8](https://github.com/TableProApp/TablePro/commit/277b8a03c3f896acad0b6adaf20392a9dbdd725b) | fix(linux): keep sized columns at their width and word the last SSH and TLS errors (#3702) | Yes |
| [0c4eaba288d9](https://github.com/TableProApp/TablePro/commit/0c4eaba288d95dd604f9b732964a515262f55813) | test(mcp): run every MCP and Agent mode write against every connection policy (#3704) | No |
| [44beef703f1d](https://github.com/TableProApp/TablePro/commit/44beef703f1d9f1a8cdf07ddbb3ff6de4087cea1) | feat(linux): add Safe Mode levels per connection (#3706) | Yes |
| [31d54f7488e8](https://github.com/TableProApp/TablePro/commit/31d54f7488e8992ce6d84888255fb18d3462486d) | fix(export): keep every value through an export and its import (#3707) | No |
| [e4231875b905](https://github.com/TableProApp/TablePro/commit/e4231875b905aece88071687ba9afaaf542d38fa) | feat(settings): list what Starter and Team include in Settings > License (#3709) | No |
| [41e42898b3d5](https://github.com/TableProApp/TablePro/commit/41e42898b3d58d56851f34dfbbc20b73324a0f48) | feat(datagrid): show the rows a cascading delete changes before it runs (#3703) | No |
| [fdb14d729ee3](https://github.com/TableProApp/TablePro/commit/fdb14d729ee322072b5bae508a6f9caed2689ec5) | feat(favorites): copy the path of a linked SQL file or folder (#3711) | No |
| [79b25e55c2ea](https://github.com/TableProApp/TablePro/commit/79b25e55c2eaac36e24443ea1ef7e6283eacd28a) | feat(connections): pass connection details to scripts, add Redshift IAM sign-in (#3715) | No |
| [3ea26b39e234](https://github.com/TableProApp/TablePro/commit/3ea26b39e234d3536c103d0c6144333c03af210b) | feat(plugins): connect to Presto through the Trino plugin (#3712) | No |
| [5f86ad2b59c8](https://github.com/TableProApp/TablePro/commit/5f86ad2b59c8b5e4797c035aa43757e3e5d9dcec) | feat(cassandra): set the consistency level per connection and with CONSISTENCY (#3716) | No |
| [ab08c803680d](https://github.com/TableProApp/TablePro/commit/ab08c803680dc578a2f37db725d8fe9f6cd983db) | feat(plugin-cassandra): list user-defined types, offer them in the type picker and drop them (#3719) | No |
| [1ec7fb2605a5](https://github.com/TableProApp/TablePro/commit/1ec7fb2605a5bc6d218b4b98a9dba4f1f7a75005) | feat(datagrid): choose the format Cmd+C copies rows in (#3718) | No |
| [8455484cead6](https://github.com/TableProApp/TablePro/commit/8455484cead6aaf386144e8818000f00ed26a649) | test(plugins): run every listed column type through browse, edit and export (#3710) | No |
| [a76167541245](https://github.com/TableProApp/TablePro/commit/a761675412459b830925f749e3454f8201281f9f) | feat(connections): connect PostgreSQL through a local Unix socket (#3721) | No |
| [4e374d2dc1f6](https://github.com/TableProApp/TablePro/commit/4e374d2dc1f6939e5948981fce752ebb13ce56f7) | feat(connections): show a saved password and test a password source (#3723) | No |
| [ff059f4050ea](https://github.com/TableProApp/TablePro/commit/ff059f4050ea35a3aea096fc4f8f81376acae610) | build(linux): take rustls-webpki 0.103.16 and webpki-roots 1.0.10 for RUSTSEC-2026-0381 and 0382 (#3724) | Yes |
| [2e6102cb5858](https://github.com/TableProApp/TablePro/commit/2e6102cb5858ccb9a6487f29e2b93f0caa6b1703) | feat: finish the follow-ups from the iOS feature PRs (#3680-#3690) (#3697) | Yes |
| [37489c9aa53c](https://github.com/TableProApp/TablePro/commit/37489c9aa53c95de3f25576c7ebd0db42fbd8dd8) | perf(linux): measure and fix the sidebar and completion on 50,000 tables (#3729) | Yes |
| [0cfd845a8fc3](https://github.com/TableProApp/TablePro/commit/0cfd845a8fc37434fc5620686305273f6b8fc698) | feat(tabs): pin a tab so bulk close leaves it open (#3726) | No |
| [c4cae240aceb](https://github.com/TableProApp/TablePro/commit/c4cae240acebfc4892b18bd631ee2db72a009894) | feat(users-roles): manage SQL Server and Oracle users, roles and privileges (#3733) | No |
| [bf51412ca0f9](https://github.com/TableProApp/TablePro/commit/bf51412ca0f9ee665231b9cafc97e057e70ec998) | fix(linux-ssh): pin a chosen key file only when the agent lacks it (#3720) | Yes |
| [b731e4cc6114](https://github.com/TableProApp/TablePro/commit/b731e4cc61142a60f0a41ac5c34c475f8a5f8ceb) | feat(datagrid): write one typed value into every selected cell (#3717) | No |
| [2d47cd89ec96](https://github.com/TableProApp/TablePro/commit/2d47cd89ec96591df70c02f82d1c7914fef8b0cf) | feat(datagrid): show pgvector columns as vectors, not long text (#3725) | No |
| [5fe613f32c6d](https://github.com/TableProApp/TablePro/commit/5fe613f32c6dfa60901e4bc6f03cf124ed1d3dbe) | feat(data-grid): mark invisible characters in cells and value fields (#3728) | No |
| [62dc8b43e8b0](https://github.com/TableProApp/TablePro/commit/62dc8b43e8b0870465574e5c3ae9459c095dd4c5) | feat(export): export a data dictionary of tables and columns as Markdown or HTML (#3735) | No |
| [ea98f402ea2f](https://github.com/TableProApp/TablePro/commit/ea98f402ea2f05a3de7a5941a8c5a97c19dfa6c6) | feat(autocomplete): complete identifiers in the case the server folds them to (#3731) | No |
| [e7808d3dbb2c](https://github.com/TableProApp/TablePro/commit/e7808d3dbb2c4ba8ca1630a80e97f54c58998d04) | fix(mysql): refuse a plain-text password without TLS, and require TLS first on Preferred (#3734) | No |
| [ea5ed041c325](https://github.com/TableProApp/TablePro/commit/ea5ed041c325d5f7fb4304352759dfbd179a2926) | test(shortcuts): list the unbound actions by name instead of counting them (#3744) | No |
| [972d0ccdfbb0](https://github.com/TableProApp/TablePro/commit/972d0ccdfbb0e907f784fd8108a49b56b30c78d3) | perf(linux-sidebar): pick the sidebar's search rows off the GTK thread (#3747) | Yes |
| [cb906011dabc](https://github.com/TableProApp/TablePro/commit/cb906011dabc6c038e071620bd59ccc51292f40b) | feat(er-diagram): export as SVG, PDF, Mermaid and Graphviz DOT (#3738) | No |
| [1c6c02c56921](https://github.com/TableProApp/TablePro/commit/1c6c02c56921630f6237159176709c6a7da4fdc3) | feat(editor): tab stops and fields in saved query snippets (#3741) | No |
| [ee782b36a202](https://github.com/TableProApp/TablePro/commit/ee782b36a202be14b75ae064c2ff4611721fcab6) | feat(editor): configurable SQL formatter rules (#3740) | No |
| [aa430414d6d5](https://github.com/TableProApp/TablePro/commit/aa430414d6d5e73aceb01b79bfb8f72ec79450df) | feat(results): compare two query results row by row (#3739) | No |
| [db64423be70b](https://github.com/TableProApp/TablePro/commit/db64423be70b6406ef136e3ce99c8a379ff1e291) | feat(server-dashboard): add Oracle, MongoDB and Redis (#3732) | No |
| [1daf41090f29](https://github.com/TableProApp/TablePro/commit/1daf41090f29a227cd0b0b517966add2e33cb4cd) | feat(sidebar): list the session's temporary tables (#3746) | No |
| [22c7754d9715](https://github.com/TableProApp/TablePro/commit/22c7754d97156d7534dd310970941d034b91ef3a) | fix(mysql): keep backup and restore from sending a plain-text password without TLS (#3742) | No |
| [774df77e3dec](https://github.com/TableProApp/TablePro/commit/774df77e3decf379f2f721fa782b1631a573e81e) | feat(linux): ship Vietnamese and publish the translation template (#3727) | Yes |
| [91653ddd4c68](https://github.com/TableProApp/TablePro/commit/91653ddd4c6825b4421703ad2130e653a845b927) | feat(editor): complete columns of every CTE shape and ORDER BY aliases (#3713) | No |
| [babb15c827bb](https://github.com/TableProApp/TablePro/commit/babb15c827bb4321ba405c28a59e89b7145c1510) | feat(search): find a value in every table of a database (#3737) | No |
| [1dd58630ecba](https://github.com/TableProApp/TablePro/commit/1dd58630ecbabf1516896d8541b1763997e20875) | feat(ai): answer inline suggestions and query actions with Apple Intelligence (#3749) | No |
| [9541927e2d83](https://github.com/TableProApp/TablePro/commit/9541927e2d8336ef425c7005ba2254982e423b8f) | perf(diagnostics): trace tab switches and benchmark launch, table open and tab switch (#3705) | No |

## Selected source paths inspected

At the pinned source:

- `CONTRIBUTING.md`, `linux/CONTRIBUTING.md`, `linux/ARCHITECTURE.md`, `linux/Cargo.toml` and `.github/workflows/build-linux.yml`.
- Linux sidebar index, model, lazy list, list implementation and the large-catalog fixture.
- Linux completion proposal list, generation checks and lazy-allocation tests.
- Linux grid column sizing, resize implementation and layout tests.
- Linux SSH identity probe, authentication matrix and ADR 0020.
- Linux Safe Mode levels, statement access classifier and editor gate.
- Linux gettext contributor instructions and Meson catalogue checks.
- Linux PostgreSQL codec module layout and the shared value-corpus conformance case.
- Apple pgvector type discovery and PostgreSQL column-type corpus.
- Apple corpus runner and report, export/import round-trip tests, autocomplete parser boundary cases.

## Live metadata inspected

GitHub API PR bodies: #3714, #3729, #3704, #3710, #3713. Open PR inventory and the 30 most recently updated issue/PR records were screened. Open status is a dated observation. Reported test results remain the authors' evidence, not an independent run.

BookiE issue #1149 and open PR titles were checked to avoid reopening completed adoption packets or duplicating implementation already in flight. Detailed BookiE source comparisons and acceptance recommendations are in the [review](../../archive/tablepro-collaboration-2026-10-21.md).
