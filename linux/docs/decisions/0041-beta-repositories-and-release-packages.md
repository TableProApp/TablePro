# 0041: Beta repositories, a Flatpak repository of our own, and packages on every GitHub release

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

[ADR 0018](0018-ppa-copr-and-flathub-later.md) made a Launchpad PPA and a
COPR project the channels, sent a pre-release to GitHub Releases alone,
kept binary packages off GitHub, left other distributions to a source
build until Flathub, and kept no Flatpak manifest but the development one.
Before the first tag the maintainer asked for betas that testers install
the way they install a release, for packages on every GitHub release, and
for an updating install on Ubuntu 22.04 and 24.04, Debian, Linux Mint,
Pop!_OS and the rest. Checked on 2026-11-05:

- Ubuntu 24.04 ships GTK 4.14 and libadwaita 1.5, and 22.04 GTK 4.6 and
  libadwaita 1.1, below the GNOME 50 floor of
  [ADR 0015](0015-gnome-50-platform-floor.md). Their own Flatpak, 1.12.7
  and 1.14.6, installs the GNOME 51 runtime from Flathub.
- Flatpak documents a repository on any web server (docs.flatpak.org,
  Hosting a repository), signed with GPG, with static deltas.
- Flathub's linter documentation no longer refuses the home and host
  exceptions "if there are signs of LLM usage" (flathub-infra/documentation
  762f508, 2026-10-26). Flathub moderators now approve each submission's
  permissions on the website.
- flatpak-builder-lint stopped reporting home and host access,
  `--socket=ssh-auth` and `--socket=gpg-agent` on 2026-10-23
  (flathub-infra/flatpak-builder-lint 1d036a8), leaving them to that
  moderation.
- Flathub's generative AI policy still bars AI-generated or AI-assisted
  content in a manifest, and AI tools opening or writing a submission pull
  request. Flathub beta takes no new application: one reaches it only after
  the stable repository accepted it. Both are on docs.flathub.org,
  Requirements.
- The Snap Store granted DBeaver Community classic confinement in November
  2025, after a review
  ([forum](https://forum.snapcraft.io/t/request-classic-confinement-for-dbeaver-ce/49008)).
  0018 rejected Snap because "a database client does not qualify for
  classic confinement"; it needs a store review, which a database client
  can pass.
- `rustc-1.98` is published for resolute in `~rust-toolchain/staging`
  since 2026-10-20, and COPR has fedora-45-x86_64 and fedora-45-aarch64
  chroots.
- GitHub rewrites a `~` in a release asset's name to `.`
  (openpreserve/jpylyzer#217), and every .deb and .rpm file name carries
  one.
- AppStream 1.1.2 sorts `0.1.0-beta.1` above `0.1.0`, so `appstreamcli
  validate` fails a metainfo that lists 0.1.0 above that beta
  (`releases-not-in-order`). `0.1.0~beta.1` sorts below and passes, as
  AppStream's version comparison documents for pre-releases.

## Decision

`linux-vX.Y.Z-beta.N` is a beta and `linux-vX.Y.Z` a release, with no
other pre-release. Each goes to its own repositories, which testers layer:

| | Release | Beta |
|---|---|---|
| GitHub Releases | a release | a pre-release |
| Launchpad | `ppa:tablepro/tablepro` | `ppa:tablepro/tablepro-beta` |
| COPR | `@tablepro/tablepro` | `@tablepro/tablepro-beta` |
| Flatpak | `https://flatpak.tablepro.app/repo/`, branch `stable` | `https://flatpak.tablepro.app/beta-repo/`, branch `beta` |

The Flatpak repositories are OSTree repositories in the Cloudflare R2
bucket `tablepro-flatpak`, served as `flatpak.tablepro.app`. A key of their
own signs every commit and summary; the summaries carry static deltas, and
each ref keeps its last 3 commits. Each repository holds a `.flatpakrepo`
and a `.flatpakref` that names Flathub for the GNOME runtime. The release
job pulls the published repository, signs the new commits into it, uploads
objects before summaries, and deletes what pruning removed last
(`build-aux/packaging/flatpak-repo.sh`, `flatpak-publish.sh`).

Every GitHub release and pre-release carries what CI built offline from
that tag's tarballs and installed in fresh containers: the .deb for each
Ubuntu series and the .rpm for each Fedora release CI builds, both tested
as they build, and a single-file Flatpak bundle made from the signed
repository, which it names for its updates, all for amd64 and arm64, with
`SHA256SUMS`, and named after the tag's version.

The Flatpak comes from `build-aux/flatpak/app.tablepro.TablePro.json`: the
release profile under the real app id, GNOME 51, built offline from the
same tarballs, line tables in its `.Debug` extension, and translations
kept in the app. The `.Devel` manifest
stays for development builds, as GNOME apps keep a `.Devel` id. This
manifest serves our repository only; a Flathub submission stays one a
maintainer writes by hand under Flathub's policy.

The packages and the metainfo spell a beta `X.Y.Z~beta.N`, and its
metainfo `<release>` has `type="development"`.

## Rationale

- **Testing repositories sit beside the stable ones.** Fedora's
  updates-testing is enabled next to updates (Fedora QA:Updates Testing),
  flathub-beta is a second remote serving the same app ids (Flathub,
  Installation), and `ppa:git-core/candidate` ("For stable releases, go to
  ~git-core/+archive/ppa instead") and
  `ppa:libreoffice/libreoffice-prereleases` ("Defer to
  ~libreoffice/+archive/ubuntu/ppa for stable updates!") each pair with a
  stable PPA. None copies its releases into the testing repository.
- **One version order for the packages.** dpkg, RPM and AppStream sort
  `X.Y.Z~beta.N` below `X.Y.Z` and above the release before it, so a
  tester with both apt or dnf repositories gets 0.1.0 over its betas, and
  0.2.0~beta.1 over 0.1.0. Flatpak branches do not compare versions.
- **Flatpak reaches what the floor excludes, with updates.** The GNOME 51
  runtime carries the libraries 22.04 and 24.04 lack, and a remote updates
  the app where a bundle alone would not, through `flatpak update` and the
  software centres.
- **R2 is a static host outside git.** An OSTree repository grows with
  every commit, which does not belong in the history of the GitHub Pages
  site `updates.tablepro.app` deploys from.
- **One source for every asset.** The Flatpak builds from the tarballs the
  packages build from, so everything `SHA256SUMS` lists comes from them.
- **Our repository is not a Flathub submission.** The linter and
  documentation changes remove the refusal 0018 expected for the home
  exception, but the AI policy still keeps a manifest from this repository
  out of Flathub.

## Consequences

- Before the first tag a maintainer sets up a Launchpad team with both
  PPAs, a COPR group, which needs a Fedora Accounts group, with both
  projects, the R2 bucket, its domain and token, the Flatpak key, and the
  secrets and variables `release-linux.yml` names in its header
  ([releasing.md](../releasing.md#setup-before-the-first-release)).
- Every installed remote trusts the Flatpak key. A new key makes every
  user add the repository again.
- Until 0.1.0 only the beta repositories hold packages. A tester who added
  only the beta one keeps the last beta after 0.1.0 until they add the
  stable one or the next beta ships.
- The Flatpak's build runs every Meson suite in the release profile. CI
  signs it into both repositories with a throwaway key, validates what it
  installs, serves them, and installs and updates the app from its
  `.flatpakref` and from a bundle, installs its `.Debug` extension, and
  switches between the release and beta branches, on Ubuntu 22.04, 24.04
  and 26.04.
- Flatpak keeps the release and the beta as two branches with one set of
  data and never moves between them by version: users choose with
  `flatpak make-current`, unlike apt and dnf, which take the highest version.
- `release-matrix.json` declares the Ubuntu series, Fedora releases and
  architectures; CI builds from it, and a release's assets must be exactly
  those, each matching `SHA256SUMS` and its package's own name, version and
  architecture. GitHub attests every asset's build.
- `release-linux.yml` gathers every asset in one job, which a dry run by
  hand runs too, publishing nothing.
- `check_packaging.py` refuses another pre-release form, a metainfo beta
  without the tilde or without `type="development"`, and holds a beta's
  dates to its release commit.
- The About dialog and the update notice look a beta's notes up by the
  metainfo's spelling.
- A packaging fix goes to the stable PPA only. A beta's fix is the next
  beta.

## Alternatives considered

- **A release published to the beta repositories too**: testers would
  need one repository, but the beta repository would copy the stable one,
  which no testing channel above does.
- **No packages on GitHub**: 0018's choice, which left every other
  distribution with a source build.
- **Bundles alone**: they install anywhere Flatpak runs, but nothing
  updates them.
- **A classic Snap**: possible after a store review, as DBeaver's shows,
  but a second confined format to test the database workflows in; one
  maintained path comes first.
- **A GNOME 46 floor for native 24.04 packages**: it gives up the widgets
  ADR 0015 adopted and still leaves 22.04 out.
- **The `.Devel` id for the Flatpak**: GNOME apps keep it for builds that
  install beside a release, and a release under it would never meet the
  Flathub app.
- **`X.Y.Z-beta.N` in the metainfo**: the release's own entry fails
  validation above it.
- **The Flatpak from the checkout with network access, as the `.Devel`
  manifest builds**: it would not come from the tarballs `SHA256SUMS`
  lists.
