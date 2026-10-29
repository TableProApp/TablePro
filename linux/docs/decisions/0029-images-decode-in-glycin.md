# 0029: Images from the database decode in glycin's sandbox

- **Status**: Accepted
- **Date**: 2026-10-29

## Context

Row Details shows the picture of a binary value that holds an image. Those bytes are written by whoever else uses the database, so they are untrusted input (`.oss-scanner/threat_model.md`). GTK's own loaders run in the app's process, and `gdk_texture_new_from_bytes` says it "should not be used with untrusted data. Use a proper image loading framework such as libglycin" (GTK 4.22, `gdk/gdktexture.c`). GNOME 50 ships glycin: gdk-pixbuf 2.44 loads through it, and Loupe and Fractal decode untrusted images with it.

## Decision

The app decodes a value's picture with the glycin crate 3.x, the GNOME 50 release, which runs each decode in a sandboxed loader process.

## Rationale

- **Out of process.** A loader that a crafted image crashes or takes over runs under bubblewrap, or `flatpak-spawn --sandbox` in Flatpak, with seccomp filters, a memory limit and no network.
- **The platform's loaders.** The formats are the ones the installed glycin loaders read, the same set the rest of the desktop shows.
- **Fits the workspace.** The crate's `tokio` feature runs on the app's runtime and the zbus it already links; `gdk4` hands back a `gdk::Texture`.

## Consequences

- The build links libseccomp and lcms2 (`meson.build`, `build-aux/debian/control`, `build-aux/rpm/tablepro.spec`). The GNOME SDK has both, since it builds libglycin.
- The picture needs the glycin loaders at run time: in the GNOME runtime, a Recommends of the .deb and the .rpm, and a test dependency of both, since the picture tests decode. Without them Row Details shows the bytes and no picture.
- Where bubblewrap cannot create namespaces, as in a container, glycin decodes without the sandbox.
- glycin 3.x speaks the loaders' `2+` protocol. Moving to glycin 4 follows the platform floor ([0015](0015-gnome-50-platform-floor.md)).

## Alternatives considered

- **`gdk::Texture::from_bytes`**: decodes in process, which GTK documents against for untrusted data.
- **gdk-pixbuf**: sandboxed only where the distribution builds it with glycin, and its texture conversion is deprecated since GTK 4.20.
- **The image crate in process**: memory-safe decoders, but no process boundary or memory limit, and a second set of formats beside the desktop's.
- **No picture**: leaves the bytes of an image unreadable in Row Details.
