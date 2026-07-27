#!/usr/bin/env bash
# Source this when system -dev packages for gtksourceview5/libsecret are unavailable.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_DEPS="$ROOT/.local-deps/root"
if [[ -d "$LOCAL_DEPS" ]]; then
  export PKG_CONFIG_PATH="$LOCAL_DEPS/usr/lib/x86_64-linux-gnu/pkgconfig:$LOCAL_DEPS/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="$LOCAL_DEPS/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export LIBRARY_PATH="$LOCAL_DEPS/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export CPATH="$LOCAL_DEPS/usr/include${CPATH:+:$CPATH}"
fi
