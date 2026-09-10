# Extensions statically linked into the iOS DuckDB build.
#
# iOS cannot autoload/autoinstall extensions (App Store Review Guideline 2.5.2
# plus the sandbox), so every extension a feature needs must be built from
# source and linked in here. DuckDB reads this file through EXTENSION_CONFIGS and
# generates the static loader that registers each extension at startup.
#
# In-tree extensions ship inside the duckdb checkout. Out-of-tree extensions
# (httpfs, quack) are fetched from their own repos. quack is what powers remote
# DuckDB connections; it requires httpfs (TLS over OpenSSL) at runtime.
#
# Both are pinned to a commit, never a branch: these are compiled into a binary that ships on
# the App Store, and a moving ref means nobody can say what was in a given release.
#
# The rule when bumping DuckDB is to move each pin to a commit whose own duckdb submodule matches
# DUCKDB_VERSION in build-duckdb-ios.sh. That is not satisfied today: the quack pin below is the
# head of its v1.5-variegata line and carries duckdb v1.5.4, while the build uses v1.5.2. No
# commit on that branch carries v1.5.2, so closing the gap means either moving DUCKDB_VERSION to
# v1.5.4, which also has to move the bundled macOS libduckdb.a, or backporting quack. Pinned
# anyway, because a fixed commit on the right release line is strictly better than tracking main.

duckdb_extension_load(core_functions)
duckdb_extension_load(json)
duckdb_extension_load(parquet)
duckdb_extension_load(icu)
duckdb_extension_load(autocomplete)

duckdb_extension_load(httpfs
    GIT_URL https://github.com/duckdb/duckdb-httpfs
    GIT_TAG 53c5b032f6c368cfcc1a1ac3819118e86d3286a6
    APPLY_PATCHES)

duckdb_extension_load(quack
    GIT_URL https://github.com/duckdb/duckdb-quack
    GIT_TAG 7e80f7ffcc98d0b3e81d0e1df8cc1c2da240a64b)
