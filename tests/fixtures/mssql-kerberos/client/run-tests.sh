#!/usr/bin/env bash
set -euo pipefail

export KRB5CCNAME=FILE:/tmp/bookie-mssql-kerberos.ccache
trap 'kdestroy >/dev/null 2>&1 || true; rm -f "$KRB5CCNAME"' EXIT

printf '%s\n' "$BOOKIE_KRB_PASSWORD" | kinit "$BOOKIE_KRB_PRINCIPAL"
klist -s
kvno -k /fixture/materials/mssql.keytab MSSQLSvc/mssql.domain1.sink.test:1433
"/bookie-target/$BOOKIE_TEST_BINARY" --include-ignored --test-threads=1
