# Releasing

`.github/workflows/release-linux.yml` publishes a release. This page is what a maintainer does around it. [ADR 0018](decisions/0018-ppa-copr-and-flathub-later.md) says why the channels are a Launchpad PPA and a COPR project.

## Setup before the first release

A repository admin does these once. The workflow's header names the same secrets and variables.

1. **Environment** `linux-release`: a required reviewer, and deployments from `linux-v*` tags and the `main` branch only. The branch is for a [packaging fix](#a-packaging-fix). Two secrets in it:
   - `LINUX_PPA_SIGNING_KEY`: the ASCII-armored OpenPGP secret key, with no passphrase, that signs the uploads.
   - `LINUX_COPR_WEBHOOK`: the custom webhook URL from the COPR project's Integrations page, ending in `/tablepro/`.
2. **Variables**: `LINUX_PPA`, the PPA as `owner/name`. `LINUX_BRANCH` stays unset unless a release comes from a [maintenance branch](#a-fix-release).
3. **Tag ruleset**: add `refs/tags/linux-v*` to the ruleset that lets only admins create release tags. Today it covers `refs/tags/v*` alone, so anyone with write access could start a release.
4. **Launchpad**: a team that owns the PPA, and the PPA with a dependency on `~rust-toolchain/staging`, amd64 and arm64 turned on under its processors, and debug symbol publishing on (Launchpad's admins turn it on when the PPA's settings do not offer it). Register the signing key's public half on an account in the team. Launchpad mails a failed build to the owner of the key that signed the upload, so that account's mail has to reach someone.
5. **COPR**: a project with the Fedora 44 x86_64 and aarch64 chroots, following Fedora branching, with AppStream metadata generation on, and a package named `tablepro` with the custom source method from `build-aux/rpm/copr-sources.sh` (the command is in its header). Turn on build failure emails for the project's admins.

[README.md](../README.md#install) gives users `ppa:tablepro/tablepro` and `@tablepro/tablepro`; change it if the PPA or the COPR project gets another name.

## A release

1. **The release commit**, a pull request titled `chore(release): linux-vX.Y.Z`, sets one version and one date (UTC) everywhere:
   - `version` in `meson.build`.
   - A new first `<release>` in `data/app.tablepro.TablePro.metainfo.xml.in.in`, with the date and a short description.
   - `Version`, `Release: 1%{?dist}` and a new first `%changelog` entry in `build-aux/rpm/tablepro.spec`, with the same date.
   - The version's section in `CHANGELOG.md`, from the fragments in `changelog.d/`. From the repository root, with the towncrier venv of the root `RELEASING.md`, Notes: `.venv/bin/towncrier build --dir linux --version X.Y.Z --date YYYY-MM-DD --yes`. It deletes the fragments and stages `CHANGELOG.md`. An X.Y.0 types its lead under the heading, at most 6 plain lines naming what a reader would change their behavior over.
   - The `.TH` line of `data/tablepro.1`: the date and `TablePro X.Y.Z`.

   The pull request changes only these files and `changelog.d/`; PR title refuses anything else. The `release-metadata` Meson test checks that they agree once the changelog heading exists, so the pull request fails before the tag does.
2. **The tag**: `linux-vX.Y.Z` on the merged commit, pushed the same UTC day. The workflow compares the metainfo date with the commit date.
3. **The workflow** checks the tag, builds and tests both packages on amd64 and arm64, publishes the GitHub release with the tarballs and the version's changelog section as notes, uploads the signed source package to the PPA, and posts the tag to COPR. A reviewer approves each step that uses the environment.
4. **Afterwards**: watch the Launchpad build page of each series and the COPR build the workflow prints. A failed build there does not fail the workflow.

A tag such as `linux-v0.2.0-rc.1` publishes a GitHub pre-release with the tarballs only, and skips the PPA and COPR. Its commit sets the version and the dates but adds no `CHANGELOG.md` section and keeps the fragments, so the stable release lists them; the pre-release notes are a towncrier draft of the fragments at the tag.

## A packaging fix

A fix to `build-aux/debian` or `build-aux/rpm` that needs no new version, such as a missing dependency.

**PPA.** Merge the fix to `main`, then run the workflow by hand on `main`:

```sh
gh workflow run release-linux.yml --ref main -f tag=linux-v0.1.0 -f revision=2
```

It downloads that release's two tarballs, checks them against its `SHA256SUMS`, builds the source package with the packaging from `main` as `0.1.0-0ppa2~YY.MM`, builds and tests the .deb on both architectures, and uploads it once a reviewer approves. Launchpad accepts the release's own orig tarballs again, and would refuse new ones whose bytes differ. Count the revision up for each further upload of the same version.

**COPR.** COPR builds the spec at the tag, so a fix to it goes in by hand. Raise `Release` in `build-aux/rpm/tablepro.spec` on `main` with a `%changelog` entry, then, on Fedora with `copr-cli` signed in, build the source RPM from that spec and submit it:

```sh
spectool --get-files --sources build-aux/rpm/tablepro.spec
rpmbuild -bs --define "_sourcedir $PWD" --define "_srcrpmdir $PWD" build-aux/rpm/tablepro.spec
copr-cli build <owner>/tablepro tablepro-0.1.0-2.*.src.rpm
```

The next version's release commit sets `Release` back to 1.

## A fix release

0.1.1 is a release like any other, from `main`. When `main` already holds work that should wait for 0.2.0, branch `linux-0.1` from the `linux-v0.1.0` tag, cherry-pick the fixes onto it with their fragments, and open the release pull request into `linux-0.1`, so towncrier builds the section from those fragments only. Set `LINUX_BRANCH` to `linux-0.1` and allow that branch in the environment, push the tag, then set both back. Afterwards cherry-pick the release commit onto `main` in a pull request with the same title: it brings the version, the dates and the section, and deletes the fragments 0.1.1 shipped.

## Downgrades

An older build never writes over what a newer one stored; it refuses it until the user resets it or upgrades again. [troubleshooting.md](troubleshooting.md#after-a-downgrade) tells users what they see.
