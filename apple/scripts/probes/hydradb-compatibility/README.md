# HydraDB compatibility probes

These probes use real servers and the production driver sources. Use disposable
graphs only. The seed refuses a graph that already contains its fixture label.
No credentials or persistent database directories belong in this folder.

## Server and Python probe

Build `Dockerfile` as `tablepro-hydradb-probe:20261103`. It pins the compiler,
Cypher parser, task runner and Python driver used by the probe. Mount the HydraDB
checkout at `/workspace` and a build-cache volume at `/build`, then build its
`graph-node` binary with `CARGO_TARGET_DIR=/build` and `server-runtime` enabled.
Follow that checkout's `AGENTS.md` for its `just` build and test commands.

Run the image with the build volume read-only at `/build`, this directory
read-only at `/probes`, and `bash /probes/serve.sh` as the command. Set
`HYDRADB_PROBE_TOKEN` to a disposable token. Publish ports 17687, 18443 and 19091
on `127.0.0.1` only. The script creates its store inside the container; use
`--rm` and stop the container after testing.

Inside that server container, run:

```sh
HYDRADB_PROBE_DISPOSABLE=1 /opt/probe-python/bin/python /probes/client-probe.py \
  --seed --require-metadata --require-entities --scale 1002 --parallel-check
```

The probe emits JSON lines. It checks entities, scoped catalogs, parallel edge
identities, error recovery and credential rejection. Unsupported queries are
recorded as rejected. Read routing mode is an observation, not an authorization
test. Recreate the container before seeding again.

## Native driver

On macOS with full Xcode installed, run from the repository root:

```sh
HYDRADB_PROBE_TOKEN='<disposable token>' HYDRADB_PROBE_SCALE=1002 \
  bash apple/scripts/probes/hydradb-compatibility/check-tablepro.sh
```

The script compiles the actual HydraDB and shared Bolt driver sources. It emits
JSON lines and exits unsuccessfully if an expected operation fails. The sparse
export check requires the Python probe's 1,002-node fixture and checks a property
that first appears beyond the browser's 1,000-entity sample. Set
`HYDRADB_PROBE_BUILD_ONLY=1` to compile without connecting.

This is a single-node plaintext development test. It does not establish GUI,
TLS, cluster routing, failover or cancellation behavior. The server's Rust tests
separately exercise metadata scan budgets and a 10,000-node local-store fixture;
that result does not measure object-store network requests.
