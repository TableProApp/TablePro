# Dameng bridge

TablePro's C ABI over the DM8 wire protocol. `src/lib.rs` is the only first-party code here;
the protocol itself comes from a pinned dependency.

## Layout

| Path | What it is |
|------|------------|
| `src/lib.rs` | The `tp_dm_*` C ABI Swift links against. Contracts live in `Plugins/DamengDriverPlugin/CDameng/CDameng.h`. |
| `lib/` | Build output. Gitignored, and deliberately not `Libs/`, which `download-libs.sh` checksum-verifies and `publish-libs.sh` guards. |
| `LICENSES/rust-dameng.txt` | MIT licence for the protocol crates, which ship inside the compiled plugin. |

## Protocol dependency

`dameng`, `dameng-protocol` and `dameng-types` come from
[`TableProApp/rust-dameng`](https://github.com/TableProApp/rust-dameng), TablePro's fork of
[`rarnu/rust-dameng`](https://github.com/rarnu/rust-dameng), pinned by revision in `Cargo.toml`.
This mirrors how OracleNIO is carried.

The fork's `main` tracks upstream. TablePro's work sits on the `tablepro` branch as reviewable
commits on top of upstream `c5120eb0`, and that branch runs the protocol test suite in its own CI.
Upstream's `tokio-dameng` and `dameng-macros` are not linked here, and `tokio-dameng`'s tests do
not compile on upstream either, so the fork's CI covers only the three crates TablePro uses.

To change protocol behaviour, commit to the fork's `tablepro` branch, then bump `rev` in
`Cargo.toml` and commit the refreshed `Cargo.lock`. Do not patch the dependency in place.

## Building

```bash
scripts/build-dameng.sh [arm64|x86_64|both]
```

Fetching a git dependency needs network access. Xcode does not build this; the plugin target
links the archive `build-dameng.sh` produces, so build it before building `DamengDriver`.
