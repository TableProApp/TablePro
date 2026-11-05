# 0033: Beta repositories, and packages on every GitHub release

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

[ADR 0018](0018-ppa-copr-and-flathub-later.md) made a Launchpad PPA and a
COPR project the channels, sent a pre-release to GitHub Releases alone,
kept binary packages off GitHub, and kept no Flatpak manifest but the
development one. Before the first tag the maintainer asked for betas that
testers install the way they install a release, and for packages on every
GitHub release. Checked on 2026-11-05:

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

Every GitHub release and pre-release carries what CI built offline, tested
and installed from that tag's tarballs: the .deb for each Ubuntu series and
the .rpm built on Fedora 44, for amd64 and arm64, a single-file Flatpak
bundle for each architecture, and `SHA256SUMS`, all named after the tag's
version.

The bundle comes from `build-aux/flatpak/app.tablepro.TablePro.json`: the
release profile under the real app id, GNOME 51, built offline from the
same tarballs with every Meson suite run in the sandbox, translations kept
in the app, and the Flathub repository named for the runtime. The `.Devel` manifest stays for development builds,
as GNOME apps keep a `.Devel` id. This manifest serves our bundles only; a
Flathub submission stays one a maintainer writes by hand under Flathub's
policy.

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
- **One version order everywhere.** dpkg, RPM and AppStream sort
  `X.Y.Z~beta.N` below `X.Y.Z` and above the release before it, so a
  tester with both repositories gets 0.1.0 over its betas, and
  0.2.0~beta.1 over 0.1.0.
- **GitHub reaches who the repositories miss**: other distributions
  through the bundle, and machines that cannot add a repository.
- **One source for every asset.** The bundle builds from the tarballs the
  packages build from, so everything `SHA256SUMS` lists comes from them.
- **Our bundle is not a Flathub submission.** The linter and documentation
  changes remove the refusal 0018 expected for the home exception, but the
  AI policy still keeps a manifest from this repository out of Flathub.

## Consequences

- Before the first tag a maintainer sets up a Launchpad team with both
  PPAs, a COPR group, which needs a Fedora Accounts group, with both
  projects, and the secrets and variables `release-linux.yml` names in its
  header ([releasing.md](../releasing.md#setup-before-the-first-release)).
- Until 0.1.0 only the beta repositories hold packages. A tester who added
  only the beta one keeps the last beta after 0.1.0 until they add the
  stable one or the next beta ships.
- A bundle does not update itself. A newer bundle installs over it.
- Each tag's run builds two bundles besides the packages.
  `release-linux.yml` gathers every asset in one job, which a dry run by
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
- **The `.Devel` id for the bundle**: GNOME apps keep it for builds that
  install beside a release, and a release under it would never meet the
  Flathub app.
- **`X.Y.Z-beta.N` in the metainfo**: the release's own entry fails
  validation above it.
- **The bundle from the checkout with network access, as the `.Devel`
  manifest builds**: it would not come from the tarballs `SHA256SUMS`
  lists.
