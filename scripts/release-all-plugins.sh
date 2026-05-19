#!/bin/bash
# Trigger a bulk re-release of all registry plugins for a given PluginKit version.
#
# Usage: ./scripts/release-all-plugins.sh <pluginKitVersion>
# Example: ./scripts/release-all-plugins.sh 14
#
# Reads the latest tag for each plugin from git, pairs it with the given
# pluginKitVersion, and fires one workflow_dispatch on build-plugin.yml so all
# plugins build in parallel as a single matrix run.
#
# Prerequisites: gh CLI authenticated, run from repo root.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <pluginKitVersion>" >&2
    exit 1
fi

PKV="$1"

# Registry-only plugins. Bundled plugins (Redis, ClickHouse, SQLite, MySQL,
# PostgreSQL, CSV/JSON/SQL/XLSX/MQL export, SQL import) ship inside the app
# bundle and must NEVER be published to the registry.
PLUGINS=(
    mongodb
    oracle
    duckdb
    mssql
    cassandra
    etcd
    cloudflare-d1
    dynamodb
    bigquery
    libsql
)

BUNDLED_PLUGINS=(
    redis
    clickhouse
    sqlite
    mysql
    postgresql
    csv
    json
    sql
    xlsx
    mql
    sqlimport
)

for PLUGIN in "${PLUGINS[@]}"; do
    for BUNDLED in "${BUNDLED_PLUGINS[@]}"; do
        if [ "$PLUGIN" = "$BUNDLED" ]; then
            echo "ERROR: '$PLUGIN' is a bundled plugin and must not be published to the registry." >&2
            echo "Remove it from PLUGINS in $0." >&2
            exit 1
        fi
    done
done

TAG_LIST=""
FIRST=true
echo "Resolving latest tag for each plugin:"
for PLUGIN in "${PLUGINS[@]}"; do
    LATEST_TAG=$(git tag -l "plugin-${PLUGIN}-v*" | sort -V | tail -1)
    if [ -z "$LATEST_TAG" ]; then
        echo "  WARNING: No tag found for plugin-${PLUGIN}-v*. Skipping."
        continue
    fi
    PAIR="${LATEST_TAG}:${PKV}"
    if [ "$FIRST" = true ]; then
        TAG_LIST="$PAIR"
        FIRST=false
    else
        TAG_LIST="${TAG_LIST},${PAIR}"
    fi
    echo "  $PAIR"
done

if [ -z "$TAG_LIST" ]; then
    echo "ERROR: No plugin tags found." >&2
    exit 1
fi

echo ""
echo "Dispatching build-plugin.yml with PluginKit version $PKV"
echo ""

gh workflow run build-plugin.yml --field "tags=$TAG_LIST"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "Dispatched. Monitor at: https://github.com/${REPO}/actions/workflows/build-plugin.yml"
