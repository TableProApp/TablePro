# Build image for Anthropic's OSS Scanner (github.com/anthropics/oss-scanner/tree/main/projects/tablepro).
# The scanner builds it online, then scans offline, so every dependency a test needs is fetched here.
# The Mac and iOS apps need Xcode and are scanned as source; this builds the Linux app and the
# TableProCore targets that compile on Linux.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# The first group mirrors the Linux fast job in .github/workflows/build-linux.yml, the second the
# official swift:6.4-resolute image.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg2 libarchive-tools \
      build-essential pkgconf meson ninja-build gettext desktop-file-utils appstream libglib2.0-bin \
      libxml2-utils libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev libsqlite3-dev libkrb5-dev \
      clang libclang-dev adwaita-icon-theme locales gnome-keyring openssh-client xvfb xauth dbus-daemon \
      binutils binutils-gold libc6-dev libcurl4-openssl-dev libedit2 libgcc-15-dev libpython3-dev \
      libstdc++-15-dev libxml2-dev libncurses-dev libz3-dev tzdata unzip zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -f UTF-8 en_US.UTF-8

ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain 1.98 --component rustfmt,clippy

ARG SWIFT_VERSION=6.4.1
RUN set -e; \
    case "$(dpkg --print-architecture)" in \
      amd64) suffix='' ;; \
      arm64) suffix='-aarch64' ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    url="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2604${suffix}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu26.04${suffix}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/swift.tar.gz "$url.sig" -o /tmp/swift.tar.gz.sig; \
    export GNUPGHOME="$(mktemp -d)"; \
    curl -fsSL https://www.swift.org/keys/all-keys.asc | gpg --batch --quiet --import; \
    gpg --batch --verify /tmp/swift.tar.gz.sig /tmp/swift.tar.gz; \
    bsdtar -xzf /tmp/swift.tar.gz -C / --strip-components=1; \
    chmod -R o+r /usr/lib/swift; \
    rm -rf "$GNUPGHOME" /tmp/swift.tar.gz /tmp/swift.tar.gz.sig; \
    swift --version

COPY . /src
WORKDIR /src

# Linux app. Meson keeps Cargo's home and target under _build, so later runs go through `meson devenv`.
RUN cd linux \
    && meson setup _build -Dprofile=development \
    && meson compile -C _build \
    && meson devenv -C _build cargo fetch --locked \
    && meson devenv -C _build cargo test --locked --workspace --no-run
RUN cd linux && (xvfb-run -a dbus-run-session -- meson test -C _build --print-errorlogs \
    || echo "WARNING: meson test reported failures")

# Each target .oss-scanner/swift/Package.swift names is linked in from TableProCore, so a patch to the
# linked files is a patch to the app.
RUN cd .oss-scanner/swift \
    && mkdir -p Sources Tests \
    && for name in $(grep -oE 'name: "[A-Za-z]+"' Package.swift | cut -d'"' -f2 | grep -vx TableProCoreLinux); do \
         case "$name" in *Tests) dir=Tests ;; *) dir=Sources ;; esac; \
         ln -s "/src/apple/Packages/TableProCore/$dir/$name" "$dir/$name"; \
       done \
    && swift build --build-tests \
    && (swift test --skip-build || echo "WARNING: swift test reported failures")

ENV CARGO_NET_OFFLINE=true
