# Releasing

`.github/workflows/release-linux.yml` publishes a release or a beta. This page is what a maintainer does around it. [ADR 0018](decisions/0018-ppa-copr-and-flathub-later.md) says why the channels are a Launchpad PPA and a COPR project, and [ADR 0041](decisions/0041-beta-repositories-and-release-packages.md) why betas have their own, why every other distribution gets a Flatpak repository of ours, and what every GitHub release carries.

## Setup before the first release

A repository admin does these once. The workflow's header names the same secrets and variables.

1. **The signing key**, on a machine you trust, kept for uploads only. Launchpad confirms a key by mail encrypted to it, so it needs an encryption subkey too:

   ```sh
   gpg --batch --passphrase '' --quick-generate-key 'TablePro Releases <hello@tablepro.app>' rsa4096 sign never
   gpg --list-secret-keys --with-colons 'TablePro Releases' | awk -F: '$1 == "fpr" { print $10; exit }'
   gpg --batch --passphrase '' --quick-add-key <fingerprint> rsa4096 encr never
   gpg --keyserver hkps://keyserver.ubuntu.com --send-keys <fingerprint>
   gpg --armor --export-secret-keys <fingerprint> > linux-ppa-signing-key.asc
   ```

2. **Launchpad**, signed in as the maintainer whose account will hold the key:
   1. Add the fingerprint at [OpenPGP keys](https://launchpad.net/~/+editpgpkeys) and open the link in the encrypted mail Launchpad sends. Launchpad mails a failed build to the owner of the key that signed the upload, so that account's mail has to reach someone.
   2. [Register a team](https://launchpad.net/people/+newteam) named `tablepro`, with that account a member.
   3. On the team's page, Create a new PPA twice: URL `tablepro`, display name `TablePro`, and URL `tablepro-beta`, display name `TablePro beta`. In the beta one's description, tell testers to add `ppa:tablepro/tablepro` as well.
   4. On each PPA, Edit PPA dependencies: add `~rust-toolchain/ubuntu/staging`. Change details: under Processors, amd64 and arm64, and turn on Build debug symbols and Publish debug symbols.
3. **COPR**:
   1. A COPR group is a Fedora Accounts group, which only Fedora Infrastructure creates: [open a ticket](https://forge.fedoraproject.org/infra/tickets/issues/new) asking for the group `tablepro`, then add the maintainers at [Fedora Accounts](https://accounts.fedoraproject.org).
   2. Sign out of COPR and in again, so it reads the group, and choose Activate this group on [My groups](https://copr.fedorainfracloud.org/groups/list/my).
   3. With `copr-cli` and the API token from [COPR's API page](https://copr.fedorainfracloud.org/api/) in `~/.config/copr`, from the repository root:

      ```sh
      for project in tablepro tablepro-beta; do
          copr-cli create "@tablepro/$project" \
              --chroot fedora-44-x86_64 --chroot fedora-44-aarch64 \
              --chroot fedora-45-x86_64 --chroot fedora-45-aarch64 \
              --follow-fedora-branching on --appstream on
          copr-cli add-package-custom "@tablepro/$project" --name tablepro --webhook-rebuild on \
              --script linux/build-aux/rpm/copr-sources.sh --script-builddeps 'curl rpmdevtools'
      done
      ```

   4. In each project's Settings, tell `tablepro-beta`'s users under Instructions to enable `@tablepro/tablepro` as well, and turn on build failure emails for the admins. Integrations shows the custom webhook URL; add the package name to it: `https://copr.fedorainfracloud.org/webhooks/custom/<id>/<uuid>/tablepro/`.
4. **The Flatpak repository**, in the Cloudflare account that holds the `tablepro.app` zone:
   1. **R2**: under R2 Object Storage, create the bucket `tablepro-flatpak`. Leave its `r2.dev` public URL off.
   2. **The domain**: in the bucket's Settings, under Custom Domains, connect `flatpak.tablepro.app`. Cloudflare adds the DNS record. The release job uploads `repo/` and `beta-repo/` there.
   3. **The token**: under R2, Manage API tokens, create a token with Object Read & Write on `tablepro-flatpak` only. Keep its Access Key ID, its Secret Access Key and the S3 endpoint it shows, `https://<account id>.r2.cloudflarestorage.com`.
   4. **The key**: a key of its own, not the PPA's. Every installed remote trusts it, and a new one makes every user add the repository again, so keep a copy offline:

      ```sh
      gpg --batch --passphrase '' --quick-generate-key 'TablePro Flatpak <hello@tablepro.app>' rsa4096 sign never
      gpg --list-secret-keys --with-colons 'TablePro Flatpak' | awk -F: '$1 == "fpr" { print $10; exit }'
      gpg --armor --export-secret-keys <fingerprint> > linux-flatpak-key.asc
      ```

5. **GitHub**: the `linux-release` environment takes a required reviewer and deploys from `linux-v*` tags and the `main` branch only. The branch is for a [packaging fix](#a-packaging-fix).
   - Secrets in it: `LINUX_PPA_SIGNING_KEY`, the file the first step exported; `LINUX_COPR_WEBHOOK`, the URL of `@tablepro/tablepro`; `LINUX_COPR_WEBHOOK_BETA`, the URL of `@tablepro/tablepro-beta`; `LINUX_FLATPAK_GPG_KEY`, the Flatpak key's file; `LINUX_FLATPAK_R2_ACCESS_KEY_ID` and `LINUX_FLATPAK_R2_SECRET_ACCESS_KEY`, the R2 token's. Then delete the exported key files.
   - Repository variables: `LINUX_PPA` set to `tablepro/tablepro`, `LINUX_PPA_BETA` set to `tablepro/tablepro-beta`, `LINUX_FLATPAK_R2_ENDPOINT` set to the S3 endpoint, `POSTHOG_PROJECT_KEY` set to the project API key (`phc_...`) of the one PostHog project, which the macOS release builds with too. It is public by design, so a variable, not a secret; the .deb, the .rpm and the Flatpak send usage data to it unless the user turns it off ([ADR 0039](decisions/0039-usage-data.md)), and a release fails without it. `LINUX_BRANCH` stays unset unless a release comes from a [maintenance branch](#a-fix-release).

   ```sh
   gh secret set LINUX_PPA_SIGNING_KEY --env linux-release --repo TableProApp/TablePro < linux-ppa-signing-key.asc
   gh secret set LINUX_COPR_WEBHOOK --env linux-release --repo TableProApp/TablePro
   gh secret set LINUX_COPR_WEBHOOK_BETA --env linux-release --repo TableProApp/TablePro
   gh secret set LINUX_FLATPAK_GPG_KEY --env linux-release --repo TableProApp/TablePro < linux-flatpak-key.asc
   gh secret set LINUX_FLATPAK_R2_ACCESS_KEY_ID --env linux-release --repo TableProApp/TablePro
   gh secret set LINUX_FLATPAK_R2_SECRET_ACCESS_KEY --env linux-release --repo TableProApp/TablePro
   gh variable set LINUX_PPA --body tablepro/tablepro --repo TableProApp/TablePro
   gh variable set LINUX_PPA_BETA --body tablepro/tablepro-beta --repo TableProApp/TablePro
   gh variable set LINUX_FLATPAK_R2_ENDPOINT --body 'https://<account id>.r2.cloudflarestorage.com' --repo TableProApp/TablePro
   gh variable set POSTHOG_PROJECT_KEY --repo TableProApp/TablePro
   ```

Until these exist, a tag still builds and checks everything, and each publishing step that lacks its secret or variable fails and publishes nothing.

[README.md](../README.md#install) gives users these PPAs, COPR projects and Flatpak repositories; change it if one gets another name.

## A dry run

Before a tag, run the workflow by hand on the branch it will be on:

```sh
gh workflow run release-linux.yml --ref main -f dry-run=true
```

It checks the version's metadata as the `release-metadata` test does, and builds, tests and installs both packages and the Flatpak on amd64 and arm64. It signs the Flatpak with a throwaway key into both repositories, served on `127.0.0.1`, and on Ubuntu 22.04, 24.04 and 26.04 installs it from there and from a bundle, updates both, and switches between the release and the beta. It keeps every file a tag would publish, `SHA256SUMS` among them, as the run's `linux-release` artifact, checked against `build-aux/packaging/release-matrix.json`. It publishes nothing and needs no reviewer. A new Ubuntu series or Fedora release joins that file, and CI builds it from then on.

### Source archives

`build-aux/packaging/make-sources.sh` calls `make-dist.sh` for the source archive and builds the vendor archive. `make-dist.sh` uses `git archive` on committed workspace, core and Linux files. It refuses uncommitted changes to those inputs. [Core ADR 0001, Decision](../../core/docs/decisions/0001-shared-core.md#decision) is the current archive design; the `meson dist` text in older Linux ADRs is historical. The workflow builds and tests these archives through the package jobs. That is not Meson's automatic dist test.

## A release or a beta

`linux-vX.Y.Z` is a release and `linux-vX.Y.Z-beta.N` a beta; the workflow refuses any other tag. Packages and the metainfo spell a beta `X.Y.Z~beta.N`, which sorts below `X.Y.Z` in dpkg, RPM and AppStream, while the tag and `meson.build` keep the hyphen, since git refuses a tilde.

1. **The release commit**, a pull request titled `chore(release): linux-vX.Y.Z` or `chore(release): linux-vX.Y.Z-beta.N`, sets one version and one date (UTC) everywhere:
   - `version` in `meson.build`: `X.Y.Z` or `X.Y.Z-beta.N`.
   - A new first `<release>` in `data/app.tablepro.TablePro.metainfo.xml.in.in`, with the date, a `<url type="details">` to `https://github.com/TableProApp/TablePro/releases/tag/` and the tag, and a short description. A release's is `version="X.Y.Z"`. A beta's is `version="X.Y.Z~beta.N"` with `type="development"`. A release's entry goes above its betas', which stay.
   - `Version` (`X.Y.Z` or `X.Y.Z~beta.N`), `Release: 1%{?dist}` and a new first `%changelog` entry in `build-aux/rpm/tablepro.spec`, with the same date.
   - A release only: the version's section in `CHANGELOG.md`, from the fragments in `changelog.d/`. From the repository root, with the towncrier venv of the root `RELEASING.md`, Notes: `.venv/bin/towncrier build --dir linux --version X.Y.Z --date YYYY-MM-DD --yes`. It deletes the fragments and stages `CHANGELOG.md`. An X.Y.0 types its lead under the heading, at most 6 plain lines naming what a reader would change their behavior over. A beta adds no section and keeps the fragments, so the release lists them; its notes are a towncrier draft of the fragments at the tag.
   - The `.TH` line of `data/tablepro.1`: the date and `TablePro` with the version as `meson.build` has it.

   The pull request changes only these files and `changelog.d/`. The `release-metadata` Meson test checks that they agree from the commit that sets a beta's version, or adds a release's changelog heading, so the pull request fails before the tag does.
2. **The tag**: `linux-vX.Y.Z` or `linux-vX.Y.Z-beta.N` on the merged commit, pushed the same UTC day. The workflow compares the metainfo date with the commit date. Tags run one at a time, and a tag pushed while another waits cancels that one, so push a tag when no other release run is waiting.
3. **The workflow** checks the tag, builds, tests and installs the packages and the Flatpak as the [dry run](#a-dry-run) does, pulls the published Flatpak repository from R2, signs the new commits into it and bundles them. It attests every file, publishes the packages and bundles on GitHub with the tarballs, the translation template `tablepro.pot`, `SHA256SUMS`, and the version's changelog section as notes, a beta as a pre-release, and checks what the release then serves against `SHA256SUMS`. Then it uploads the Flatpak repository to R2, the signed source package to the PPA, and posts the tag to the COPR project: the stable ones for a release, the beta ones for a beta. A reviewer approves each step that uses the environment.
4. **Afterwards**: watch the Launchpad build page of each series and the COPR build the workflow prints. A failed build there does not fail the workflow. `flatpak remote-info` on the TablePro remote shows the new Flatpak commit.

### Installed-bundle smoke pass

Before announcing a beta, run this on normal GNOME and Plasma desktop sessions with the installed release-profile bundle. The container smoke test is not this pass. Use test databases and test credentials. Record the tag, bundle checksum, architecture, distribution, desktop version, session type, Flatpak version and portal backends in the release PR. Record each result and any issue link for both desktops; leave an unrun check open.

- [ ] Install the bundle, launch it from the app menu and check About's version. Record its origin, branch and commit from `flatpak info app.tablepro.TablePro//beta`.
- [ ] Save a database password, quit and relaunch, then reconnect without re-entering it. Lock the keyring and dismiss its prompt once; retry and unlock it. Repeat for the MCP token and an AI key if those features are used.
- [ ] Open a local SQLite or DuckDB file with the chooser. Run a query and export rows to a chosen folder. Confirm the exported file exists and opens on the host.
- [ ] Open About's help link in the default browser. Complete an export with the window in the background and check its notification and return to the app.
- [ ] Connect to a network database and a local database. Check a local socket where supported, and an SSH tunnel through the host agent. Run a read and a test write, then reconnect.
- [ ] In a disposable desktop session with a required portal backend absent, check the error and recover using [Flatpak connections](troubleshooting.md#flatpak-connections). Restore the backend and repeat the affected secret, chooser or link flow. Record the missing interface and recovery result. Do not disable host security controls to make a check pass.
- [ ] If an earlier beta exists, update it through its origin and repeat launch and secret reload. If a stable branch exists, switch to it and back using [README, Betas](../README.md#betas). Check saved connections and drafts after each switch. Record unavailable earlier versions as not applicable, with the reason.

For a replacement beta, also record the old and new versions and the result of the user recovery path below. A failed or unrun check remains a release gate.

## A partial publish

GitHub publishes before the Flatpak repository, PPA upload and COPR trigger. Those jobs can finish independently. Launchpad and COPR then build outside Actions, so a green workflow alone does not prove availability.

1. Pause announcements, promotion and further tags. Save the run URL and logs. Inspect all four destinations before retrying anything, including after a timeout.
2. Record this table in the release PR, with links and results for every series and architecture in `build-aux/packaging/release-matrix.json`:

   | Destination | Check |
   |---|---|
   | GitHub | Release exists; all expected assets download and match `SHA256SUMS` and their attestations |
   | Flatpak | Public beta repository resolves both app architectures and their debug refs; install and update reach the expected signed commits |
   | PPA | Upload accepted for each series; both architectures built and are available to apt |
   | COPR | Trigger returned a build ID; each target built and is available to dnf |

3. Read the failure before retrying. If a destination accepted nothing and the fault was temporary, retry only that failed publishing job. If GitHub created the release before its download check failed, verify the existing assets instead of rerunning `gh release create`. The job has no resume mode for an existing release; publish beta.N+1 if its failure left downstream jobs blocked. Do not rerun the whole workflow or replace uploaded assets.
4. For an interrupted Flatpak upload, keep the objects already uploaded. Resume the publisher with the same signed repository artifact only if no newer release has published. Its object-before-summary order and final pruning are in `build-aux/packaging/flatpak-publish.sh`. Check the public repository with a fresh install and an update afterwards.
5. For a PPA upload or COPR trigger that may have succeeded, inspect the builder first. Retry a failed external build through that service only when its source is unchanged and the failure was temporary. Never blindly resend all source uploads or the webhook. When Launchpad accepted some series and refused another before taking a file, send only the refused one: download the run's `linux-source-package` artifact, `debsign` that series' `_source.changes` with the PPA key and `dput` it alone, as the `ppa` job does. Rerunning the job sends the accepted series again, which Launchpad rejects by email. If packaging or source must change, or the accepted state cannot be established, publish beta.N+1 through the normal release steps. The stable-only [packaging fix](#a-packaging-fix) dispatch cannot repair a beta.
6. Resume announcements only after all destinations pass and the [installed-bundle smoke pass](#installed-bundle-smoke-pass) is recorded. If the beta itself is bad, withdraw it below instead of completing its publication.

## Withdraw a bad beta

There is no Linux withdrawal workflow. `.github/workflows/withdraw.yml` edits macOS Sparkle and plugin feeds only; do not dispatch it for a Linux tag.

1. Stop announcements and promotion. Cancel pending publication of the bad beta and pause further release approvals while its state is checked. Record every destination already reached using [A partial publish](#a-partial-publish).
2. Mark the GitHub release title `WITHDRAWN: linux-vX.Y.Z-beta.N`. Prepend notes that name the fault, affected installs and the recovery path. Keep its tag, assets, checksums and attestations unchanged. Do not move the tag or upload different bytes under the same version.
3. In Launchpad, delete the affected beta source version from the beta PPA and cancel its pending builds. In COPR, cancel pending builds and remove the affected build's published results from the beta project. Check repository metadata after removal. These actions do not remove a package already installed or cached by a user.
4. If the bad commit reached the Flatpak beta repository, temporarily block public access to `beta-repo/` at its hosting layer while preparing the replacement. Preserve the R2 objects and signed repository history; leave `repo/` alone. Check that the public endpoint no longer serves the bad ref, including through caches. Do not edit signed summaries by hand. Installed copies and downloaded bundles still exist, so the withdrawal notice must tell users to stop using them.
5. Fix the cause in a PR and publish beta.N+1, following [A release or a beta](#a-release-or-a-beta). For Flatpak, keep public access paused until the replacement repository is fully uploaded and checked, then restore access and test a public update. Do not announce it until all four destinations are verified.
6. Test recovery from the withdrawn beta on saved test state. Link the results and replacement release from the withdrawal notice. If no safe build is available yet, tell users to quit TablePro and wait; do not promise a downgrade can read newer state.

### User recovery

Tell users to quit TablePro and copy its [files](troubleshooting.md#where-tablepro-keeps-its-files) before changing versions. A format-upgrade copy covers app state, not changes made to a server database.

Prefer the corrected beta through the same install source in [README, Install](../README.md#install). Repository users update with apt, dnf or Flatpak; users of a GitHub .deb or .rpm download the corrected file. Confirm About shows the replacement version before resuming work.

If the notice offers an earlier tested version, link its exact release and package instructions. Disabling a beta PPA or COPR project does not uninstall or downgrade its package. Switching Flatpak branches does not restore older data. Follow [After a downgrade](troubleshooting.md#after-a-downgrade) for newer-format refusals and restoration, keeping the newer files aside. The maintainer must test that path with the affected versions before recommending it.

## A future Flathub submission

[ADR 0041, Context](decisions/0041-beta-repositories-and-release-packages.md#context) amends the older permission-policy history in ADRs 0008 and 0018. Passing the linter is not permission approval. A maintainer writes the manifest and submission by hand, discloses AI-assisted material as required, and obtains Flathub's permission review under its [current requirements](https://docs.flathub.org/docs/for-app-authors/requirements). A new app enters stable before it can use Flathub beta.

Our existing installs keep their TablePro origin. Adding Flathub or changing the default branch does not migrate that origin. Before offering migration instructions, test an explicit origin change from both our stable and beta installs to the accepted Flathub app. Record the commands and before/after origin, branch and commit from `flatpak info`. Verify updates come from Flathub, secrets still load, saved work survives and rollback works. Keep our repository available until that tested migration is published. Do not promise automatic migration.

## The first release

`main` carries 0.1.0 from before any tag: a metainfo `<release>` and a spec `%changelog` entry for it, and the fragments of every change on the way.

- **Placeholders.** The first beta's release commit replaces the metainfo's 0.1.0 entry and the spec's `0.1.0-1` entry with its own: the beta's entries come first, and 0.1.0 listed below its beta fails `appstreamcli validate`. 0.1.0's release commit adds its entries back above the betas'.
- **Notes.** The fragments from before the first beta record work on builds nobody installed. The first beta's release commit curates `changelog.d/` as a release pull request does (`apple/RELEASING.md`, Cutting a stable or patch, step 4), so that beta's notes and 0.1.0's describe the app:
  - `git rm` every `fixed`, `changed`, `deprecated`, `removed` and `security` fragment, since no Linux release had what they change. The `+ghsa-*` security fragments mirror advisories that list only the macOS and iOS apps as affected, so there is nothing to list under Security ([SECURITY.md](../../SECURITY.md)).
  - Keep each `added` fragment that names something the app does, and `git rm` one a later fragment replaces.

  Fragments after the first beta are news to testers and go into 0.1.0's section as usual. 0.1.0 types its lead like any X.Y.0, and its notes tell testers who added only the beta repository to add the stable one ([README.md](../README.md#install)).

## A packaging fix

A fix to `build-aux/debian` or `build-aux/rpm` that needs no new version, such as a missing dependency. It goes to the stable repositories only; a beta's fix is the next beta. The Flatpak's packaging is its manifest, and a fix to it waits for the next release.

**PPA.** Merge the fix to `main`, then run the workflow by hand on `main`:

```sh
gh workflow run release-linux.yml --ref main -f tag=linux-v0.1.0 -f revision=2
```

It downloads that release's two tarballs, checks them against its `SHA256SUMS`, builds the source package with the packaging from `main` as `0.1.0-0ppa2~YY.MM`, builds and tests the .deb on both architectures, and uploads it to the stable PPA once a reviewer approves. Launchpad accepts the release's own orig tarballs again, and would refuse new ones whose bytes differ. The vendor tarball brings the release's PostHog key with it. Count the revision up for each further upload of the same version. The release's GitHub assets stay as they were.

**COPR.** COPR builds the spec at the tag, so a fix to it goes in by hand. Raise `Release` in `build-aux/rpm/tablepro.spec` on `main` with a `%changelog` entry, then, on Fedora with `copr-cli` signed in, build the source RPM from that spec and submit it:

```sh
spectool --get-files --sources build-aux/rpm/tablepro.spec
rpmbuild -bs --define "_sourcedir $PWD" --define "_srcrpmdir $PWD" build-aux/rpm/tablepro.spec
copr-cli build @tablepro/tablepro tablepro-0.1.0-2.*.src.rpm
```

The next version's release commit sets `Release` back to 1.

## A fix release

0.1.1 is a release like any other, from `main`. When `main` already holds work that should wait for 0.2.0, branch `linux-0.1` from the `linux-v0.1.0` tag, cherry-pick the fixes onto it with their fragments, and open the release pull request into `linux-0.1`, so towncrier builds the section from those fragments only. Set `LINUX_BRANCH` to `linux-0.1` and allow that branch in the environment, push the tag, then set both back. Afterwards cherry-pick the release commit onto `main` in a pull request with the same title: it brings the version, the dates and the section, and deletes the fragments 0.1.1 shipped.

## Downgrades

A build refuses a file in a storage format newer than its own and never writes over it; a file in a format it knows it reads and writes, whichever release wrote it. Before the first write in a newer format, a build keeps a copy of the older file beside it ([storage.md](storage.md#copies-before-a-format-upgrade)). [troubleshooting.md](troubleshooting.md#after-a-downgrade) tells users what they see and how to put a copy back.
