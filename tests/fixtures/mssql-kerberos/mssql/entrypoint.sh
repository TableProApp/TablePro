#!/usr/bin/env bash
set -euo pipefail

install -o mssql -g root -m 0440 /fixture/mssql.keytab /var/opt/mssql/secrets/mssql.keytab
exec su -s /bin/bash mssql -c /fixture/start-mssql.sh
