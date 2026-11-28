FROM rust:1.99.1-slim-bookworm@sha256:efecb7694d37171c478bd45d0cc88d9acc6e7fd31d7a1a39891ed4a294d0ce6f

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential clang libclang-dev cmake pkg-config \
        libgraphblas-dev python3 python3-venv \
        ca-certificates curl git autoconf automake libtool peg \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/cleishm/libcypher-parser.git /tmp/cypher-parser \
    && cd /tmp/cypher-parser \
    && git checkout 8b59a8d61eff6fa2ddd984be28da48decbe3305e \
    && autoreconf --install \
    && ./configure --disable-tools --disable-werror \
    && make -j2 \
    && make install \
    && ldconfig \
    && rm -rf /tmp/cypher-parser

RUN cargo install just --version 1.40.0 --locked \
    && python3 -m venv /opt/probe-python \
    && /opt/probe-python/bin/pip install --no-cache-dir neo4j==6.0.3

RUN rustup toolchain install 1.99.0 --profile minimal --component rustfmt --component clippy

RUN apt-get update \
    && apt-get install -y --no-install-recommends libffi-dev \
    && rm -rf /var/lib/apt/lists/*

ENV CARGO_BUILD_JOBS=2 \
    CARGO_PROFILE_DEV_DEBUG=0 \
    CARGO_PROFILE_TEST_DEBUG=0 \
    CARGO_INCREMENTAL=0 \
    RUST_MIN_STACK=33554432

WORKDIR /workspace
