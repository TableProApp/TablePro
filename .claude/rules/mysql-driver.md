---
paths:
  - "Plugins/MySQLDriverPlugin/**/*"
  - "TableProMobile/**/*MySQL*"
  - "TableProMobile/**/*MariaDB*"
---

# MySQL and MariaDB driver

- **Every connect sets the session character set with `MariaDBCharacterSet.establishSession`**, because a server may ignore the handshake's charset. Outgoing SQL stays the UTF-8 bytes of the Swift string, and each result cell decodes by its field's own `charsetnr` through `MySQLColumnDecoding`.
- **`MySQLCharacterSet` is a transcription of the server's tables.** Change it only after running `scripts/probes/check-mysql-charset-decoding.sh` against a live server.
- **After a reconnect the user did not ask for, replay a statement only when `MySQLSessionFootprint.isClean`** (`mysqlMayReplay`): the new session has lost variables, `USE`, `sql_mode` and any open transaction. Statements whose answer is session-scoped (`LAST_INSERT_ID` and similar) and the bodies of `/*!NNNNN ... */` count toward the footprint.
