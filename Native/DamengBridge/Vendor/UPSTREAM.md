# Vendored rust-dameng Snapshot

The `dameng`, `dameng-protocol`, and `dameng-types` directories originate from
[`rarnu/rust-dameng`](https://github.com/rarnu/rust-dameng) commit
`c5120eb04abbe232ccc04e19d16093fbe6e0da0e` and are distributed under the MIT
license included in each directory.

TablePro carries compatibility changes for DM8 multi-column responses, binary
DECIMAL values, text EXPLAIN responses, bounded frame allocation, and exact
message-boundary reads. Response bodies and LOB content are capped at 64 MiB.
Review and retest these changes against an OrbStack DM8 instance whenever the
upstream snapshot changes.
