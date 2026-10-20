# Connection URL TLS preservation, October 20, 2026

Work for [#1172](https://github.com/cozyGarage/BookiE/issues/1172). Base: `718fbd6ff276b37e3eb8517241d82f9dccb9183b`.

## Confirmed defect

The new storage unit regression failed before the fix: `sslmode=prefer` was saved as Disabled. The same parser discarded explicit verification requirements before saving a connection.

## Scope

Supported explicit PostgreSQL `sslmode`, MySQL `ssl-mode` and MongoDB `tls` values map to the existing TLS modes. The saved legacy TLS flag agrees with the mode. Percent-encoded values are decoded by the existing bounded decoder.

Unsupported options, duplicate options and fragments refuse import. This includes MongoDB `authSource`, which has no saved field, and custom TLS certificate URL options, which are not mapped by this fix. Errors do not echo the URL or its credentials. Users can configure supported certificate fields through the connection form.

On 2026-10-20, the maintainer explicitly chose to keep Disabled when TLS options are omitted and preserve explicit options. The existing no-option regression pins that decision. The continuation uses the main checkout at the maintainer's request; no new worktree was created.

## References

- [PostgreSQL connection parameters](https://www.postgresql.org/docs/16/libpq-connect.html)
- [MySQL connection options](https://dev.mysql.com/doc/refman/8.0/en/connection-options.html)
- [MongoDB URI option specification](https://github.com/mongodb/specifications/blob/master/source/uri-options/uri-options.md)

## Evidence

All 12 focused URL-parser tests and full local preflight passed. Documentation links, ledger, comment and function guards, and diff checks passed. Forgejo acceptance remains pending. No database connection or certificate verification claim follows from parser tests alone.
