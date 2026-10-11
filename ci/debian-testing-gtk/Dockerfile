FROM debian:testing

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        pkg-config \
        libgtk-4-dev \
        libadwaita-1-dev \
        libgtksourceview-5-dev \
        libssl-dev \
        libsecret-1-dev \
        libkrb5-dev \
        libsqlite3-dev \
        clang \
        dbus-daemon \
        xvfb \
        xauth \
        at-spi2-core \
        python3-pyatspi \
    && rm -rf /var/lib/apt/lists/*
