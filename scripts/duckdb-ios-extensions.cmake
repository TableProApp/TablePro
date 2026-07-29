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
# Pin httpfs and quack to commits whose duckdb submodule matches DUCKDB_VERSION
# in build-duckdb-ios.sh. quack tracks duckdb main, so when you bump DuckDB,
# update QUACK_GIT_TAG to a commit built against the same tag.

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
    GIT_TAG main)
