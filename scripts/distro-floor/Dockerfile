ARG BASE
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl pkg-config clang gettext git \
    libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev libglib2.0-dev-bin \
    libssl-dev libsecret-1-dev libkrb5-dev libsqlite3-dev \
    xvfb xauth dbus dbus-x11 dbus-user-session python3 python3-pyatspi at-spi2-core gnome-keyring libsecret-tools \
    scrot libglib2.0-bin fuse3 x11-utils libsqlite3-0 libsecret-tools openssh-client \
    && rm -rf /var/lib/apt/lists/*
ARG RUST_VERSION=1.98.0
ENV CARGO_HOME=/opt/cargo RUSTUP_HOME=/opt/rustup PATH=/opt/cargo/bin:$PATH
ARG RUSTUP_VERSION=1.29.1
ARG RUSTUP_INIT_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
RUN curl -sSfo /tmp/rustup-init https://static.rust-lang.org/rustup/archive/"${RUSTUP_VERSION}"/x86_64-unknown-linux-gnu/rustup-init \
    && echo "${RUSTUP_INIT_SHA256}  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --profile minimal --default-toolchain "${RUST_VERSION}" \
    && rm /tmp/rustup-init
WORKDIR /src
