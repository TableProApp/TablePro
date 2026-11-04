# Extensions statically linked into the iOS DuckDB build.
#
# iOS cannot autoload/autoinstall extensions (App Store Review Guideline 2.5.2
# plus the sandbox), so every extension a feature needs must be built from
# source and linked in here. build-duckdb-ios.sh reads this file and registers
# each extension through DuckDB's generated static extension loader.
#
# Only in-tree extensions, which ship inside the duckdb checkout, so there is
# nothing to pin. httpfs needs libcurl, which the iOS SDK ships no headers for,
# so neither it nor quack, which runs on top of it, builds for iOS.

duckdb_extension_load(core_functions)
duckdb_extension_load(json)
duckdb_extension_load(parquet)
duckdb_extension_load(icu)
duckdb_extension_load(autocomplete)
