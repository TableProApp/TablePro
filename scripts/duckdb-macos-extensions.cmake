# Extensions statically linked into the macOS DuckDB build.
#
# The macOS library used to be the bare amalgamation, which carries no extensions
# at all, so DuckDB fetched core_functions from extensions.duckdb.org the first
# time anything called a function that lives in it. That is most of them:
# `sum`, `avg`, `round`, `median`, `string_agg`, `date_trunc`, `len`,
# `current_database` and list literals all failed with "not in the catalog, but it
# exists in the core_functions extension" on a Mac that could not reach the
# registry. Linking these in makes a DuckDB connection work on an offline,
# firewalled or proxied network.
#
# This matches the set in duckdb-ios-extensions.cmake minus httpfs and quack.
# Those two need OpenSSL, which the macOS build does not link, and macOS keeps
# runtime autoloading enabled so they still download on demand the way they do
# today. Adding them here would mean linking OpenSSL into every plugin bundle.
#
# In-tree extensions ship inside the duckdb checkout, so there is nothing to pin.

duckdb_extension_load(core_functions)
duckdb_extension_load(json)
duckdb_extension_load(parquet)
duckdb_extension_load(icu)
duckdb_extension_load(autocomplete)
