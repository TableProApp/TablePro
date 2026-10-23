# 0023: DuckDB built from the duckdb crate's bundled sources

- **Status**: Accepted
- **Date**: 2026-10-23

## Context

The DuckDB driver needs libduckdb. The duckdb crate either links a system library through pkg-config or compiles the C++ sources libduckdb-sys carries (`bundled`). The packages build offline from the vendor tarball on Launchpad and COPR ([0018](0018-ppa-copr-and-flathub-later.md)), so a system library has to be in the archive each channel builds against. Measured on 2026-10-22:

| Target | DuckDB package |
|---|---|
| Ubuntu 26.04, the PPA's first series | none |
| Ubuntu 26.10 and Debian sid | `libduckdb-dev` 1.5.5, extension autoload and autoinstall off |
| Fedora 44 and rawhide, the COPR targets | none |

duckdb 1.20000.0, the newest crate, bundles a `v2.0.0-dev` snapshot, not a DuckDB release, and its static build fails to link `duckdb_register_static_extensions`. duckdb 1.10506.1 bundles DuckDB 1.5.6.

## Decision

The driver uses duckdb `~1.10506` with `bundled`, `json` and `parquet` and no default features, so every channel builds the same DuckDB 1.5.6 from the vendor tarball.

## Rationale

- **One engine on every channel.** Only Ubuntu 26.10 could link a system library. A system build would leave 26.04 and Fedora without the driver, or ship two DuckDB versions with different file formats and SQL.
- **A release, not a snapshot.** The tilde requirement keeps Cargo on 1.5.x patch releases until a stable 2.x crate is checked.
- **Offline.** The `cc` backend compiles the sources in the crate and fetches nothing. The `bundled-cmake` features (ICU, autocomplete, TPC-H) need CMake and add build time for no driver feature.
- **No extension loads by itself.** The bundled build turns on DuckDB's extension autoinstall and autoload, so the driver sets `autoinstall_known_extensions` and `autoload_known_extensions` off when it opens a file ([duckdb.md](../drivers/duckdb.md#extensions)).

## Consequences

- libduckdb-sys is a 6.2 MB crate in the vendor tarball. The release build of DuckDB took 672 s on 4 cores. Its translation units take 0.5 GB at the median and 2.6 GB at most, 3 GB with Fedora's flags, and four pass 2 GB, so `debian/rules` starts one job per 3 GiB, up from 2 GiB, and the spec keeps one per 4 GB.
- The packages need a C++ compiler: `gcc-c++` in the spec, and `build-essential` on Launchpad.
- The packages build C and C++ without the distributions' LTO flags (`optimize=-lto` in `debian/rules`, `_lto_cflags` in the spec). Fat LTO objects double what DuckDB's compile writes and the memory per translation unit, and rustc links without `-flto`, so their GIMPLE half would go unused.
- The dev profile builds libduckdb-sys at `opt-level = 2` without debug info. Unoptimized with debug info, its archive is 2.6 GB and the tests run the engine at debug speed.
- libduckdb-sys has a build dependency on ureq with its default features, for a download path the bundled build never compiles. That turns on rustls's `ring` feature in the build script's dependency graph, outside the one the binaries link. `deny.toml` allows ring only under rustls and rustls-webpki, and ureq only under libduckdb-sys and bollard-buildkit-proto, which amends the ring ban of [0009](0009-crypto-provider-and-sources.md). `crates/drivers/postgres/tests/tls_provider.rs` still fails if a second provider reaches a binary.
- DuckDB's third-party code (fmt, re2, zstd, brotli, mbedtls and the rest) is compiled into the binary, so its license files join the third-party notices.
- Moving to DuckDB 2.x is a crate bump, a vendor tarball update and a run of the driver's suites, which read the file format and the catalogue.

## Alternatives considered

- **System libduckdb through pkg-config**: available on Ubuntu 26.10 only.
- **duckdb 1.20000.0**: a development snapshot whose static link fails.
- **Downloading libduckdb at build time (`DUCKDB_DOWNLOAD_LIB`)**: Launchpad and COPR build without network, and the binary would not come from source.
- **`bundled-cmake` with ICU**: time zone names and collations, at the cost of CMake and a longer build; a later change can add it.
