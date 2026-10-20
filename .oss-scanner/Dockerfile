# Build image for Anthropic's OSS Scanner (github.com/anthropics/oss-scanner/tree/main/projects/tablepro).
# The scanner builds it online, then scans offline, so every dependency a test needs is fetched here.
# The Mac and iOS apps need Xcode and are scanned as source; this builds the Linux app and the
# TableProCore targets that compile on Linux.
# The official Swift image is Ubuntu 26.04 with the toolchain installed, the base the Linux app needs.
FROM swift:6.4.1-resolute

ENV DEBIAN_FRONTEND=noninteractive

# Mirrors the Linux fast job in .github/workflows/build-linux.yml.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git \
      build-essential pkgconf meson ninja-build gettext desktop-file-utils appstream libglib2.0-bin \
      libxml2-utils libgtk-4-dev libadwaita-1-dev libgtksourceview-5-dev libsqlite3-dev libkrb5-dev \
      clang libclang-dev adwaita-icon-theme locales gnome-keyring openssh-client xvfb xauth dbus-daemon \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -f UTF-8 en_US.UTF-8

ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain 1.98 --component rustfmt,clippy

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
