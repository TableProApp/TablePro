FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y --no-install-recommends python3-gi python3-pyatspi gir1.2-adw-1 xvfb xauth libxtst6 dbus-x11 fonts-dejavu-core && rm -rf /var/lib/apt/lists/*
