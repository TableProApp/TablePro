#!/usr/bin/env bash
# Source this when system -dev packages for gtksourceview5/libsecret are unavailable.
# Extract the package payloads under <repo>/.local-deps/root first, then:
#   source scripts/dev-env.sh
# Every variable below is namespaced and unset again so sourcing does not
# clobber the caller's ROOT or leave state behind.
# ${BASH_SOURCE[0]} is empty under zsh, where $0 holds the sourced path instead.
_dev_env_self="${BASH_SOURCE[0]:-$0}"
_dev_env_root="$(cd "$(dirname "$_dev_env_self")/../.." && pwd)"
_dev_env_deps="$_dev_env_root/.local-deps/root"
if [[ -d "$_dev_env_deps" ]]; then
  if command -v dpkg-architecture >/dev/null 2>&1; then
    _dev_env_multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  else
    _dev_env_multiarch="$(uname -m)-linux-gnu"
  fi
  _dev_env_lib="$_dev_env_deps/usr/lib/$_dev_env_multiarch"
  export PKG_CONFIG_PATH="$_dev_env_lib/pkgconfig:$_dev_env_deps/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="$_dev_env_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export LIBRARY_PATH="$_dev_env_lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export CPATH="$_dev_env_deps/usr/include${CPATH:+:$CPATH}"
  unset _dev_env_multiarch _dev_env_lib
fi
unset _dev_env_root _dev_env_deps
