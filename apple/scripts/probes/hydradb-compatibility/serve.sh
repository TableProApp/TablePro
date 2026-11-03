#!/usr/bin/env bash
set -euo pipefail
umask 077

# The disposable container owns this store; no host database or cache is mounted.
runtime_root="$(mktemp -d /tmp/tablepro-hydradb.XXXXXX)"
mkdir -p "$runtime_root/store" "$runtime_root/cache"
printf '%s\n' "${HYDRADB_PROBE_TOKEN:?provide a disposable development token}" > "$runtime_root/auth-token"

export CLOUD_PROVIDER=local LOCAL_PATH="$runtime_root/store"
export GRAPH_NAMESPACE=tablepro-probe GRAPH_ID=default
export GRAPH_CELL_ID=cell-0 GRAPH_CELLS=cell-0 GRAPH_DATA_PATH=data
export GRAPH_ALLOW_PLAINTEXT=true GRAPH_AUTH_TOKEN_FILE="$runtime_root/auth-token"
export GRAPH_DATA_CACHE_BYTES=67108864 GRAPH_DATA_CACHE_DIR="$runtime_root/cache"
export GRAPH_NODE_ID=node-0
export GRAPH_BOLT_ADDR=0.0.0.0:17687 GRAPH_ADVERTISED_BOLT_ADDR=127.0.0.1:17687
export GRAPH_BOLT_NODE_ADDRESSES=node-0=127.0.0.1:17687
export GRAPH_HTTP_ADDR=0.0.0.0:18443 GRAPH_ADMIN_ADDR=0.0.0.0:19091
export RUST_MIN_STACK=33554432 RUST_LOG=warn

exec /build/debug/graph-node
