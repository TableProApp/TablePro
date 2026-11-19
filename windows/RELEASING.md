# Releasing

`.github/workflows/release-windows.yml` builds and publishes a Windows release. [ADR 0005](docs/decisions/0005-distribution.md) says why MSIX, self-contained, Native AOT, Artifact Signing and winget, and [ADR 0020](docs/decisions/0020-app-installer-updates.md) why App Installer files, the beta channel and the app's own check. An agent runs these commands when the maintainer says to release; it never creates the tag on its own.

## What a release ships

- `TablePro_<package>_x64_arm64.msixbundle` on the GitHub release, with `SHA256SUMS`: the x64 and Arm64 MSIX in one bundle, signed with Azure Artifact Signing. Windows installs the package for its own architecture.
- Next to it, the channel's App Installer file: `TablePro.appinstaller` for a release, `TablePro-Beta.appinstaller` for a beta. Its `Uri` is the channel's file below, so opening it installs the channel's newest build and keeps the install on that channel.
- The channel's file on `gh-pages`, deployed to `https://updates.tablepro.app/windows/`: a release moves `TablePro.appinstaller`, and `TablePro-Beta.appinstaller` too unless a newer beta is out; a beta moves `TablePro-Beta.appinstaller`. `windows/ci/appinstaller.py channels` refuses to move a channel to a lower version.
- For a release, not a beta: a pull request to microsoft/winget-pkgs that adds `TablePro.TablePro` X.Y.Z, so `winget install TablePro.TablePro` gets it once Microsoft merges it.

## Versions

- A tag is `windows-vX.Y.Z` for a release or `windows-vX.Y.Z-beta.N` for a beta, each of X, Y and Z at most 65535 and N from 1 to 98. There is no other pre-release.
- The package version is `X.Y.Z.N` for a beta and `X.Y.Z.99` for the release: MSIX orders the four numbers, so a beta sorts below its release and above the release before it. `python3 windows/ci/appinstaller.py version <version>` prints it with the channel.
- The tag is the only place the version is written. The workflow sets the package version in `Package.appxmanifest` and passes the tag's version as `-p:Version`, which Settings shows. A local build keeps the csproj's `0.1.0`.

## Setup

The maintainer does these once, in this order: a tag runs the workflow file at the tagged commit, so the rulesets come before any secret. The workflow's header names the same secrets and variables. Until steps 1 to 5 are done, a run builds and checks unsigned packages and publishes nothing.

1. **Rulesets**: add `windows-v*` to the tag rulesets, so its tags never move and only admins create them (`.claude/rules/ci.md`, Required checks).
2. **Artifact Signing**: an Azure Artifact Signing account, its identity validation, and a Public Trust certificate profile ([quickstart](https://learn.microsoft.com/azure/artifact-signing/quickstart)).
3. **An app registration** with the Artifact Signing Certificate Profile Signer role on the account, and a federated credential for GitHub Actions: organization `TableProApp`, repository `TablePro`, entity Environment, name `windows-release` ([Authenticating with OpenID Connect](https://github.com/Azure/artifact-signing-action/blob/v2.0.0/docs/OIDC.md)).
4. **Environment `windows-release`**, deploying from `windows-v*` tags only, with a required reviewer, and the secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`.
5. **Repository variables**:
   - `WINDOWS_SIGNING_ENDPOINT`: the account's regional endpoint, such as `https://eus.codesigning.azure.net/`.
   - `WINDOWS_SIGNING_ACCOUNT` and `WINDOWS_SIGNING_PROFILE`: the account and its certificate profile.
   - `WINDOWS_PUBLISHER`: the certificate profile's subject, exactly as the certificate shows it, such as `CN=Name, O=Name, L=City, S=State, C=Country`. The package's Publisher has to match it, or signing fails. It also fixes the package family name, and Windows takes a package with another publisher for another app, so it never changes after the first release.
6. **Environment `github-pages`**: add the tag pattern `windows-v*` beside `v*` to its deployment branches and tags before the first tag, or the channel files reach `gh-pages` and Pages refuses to deploy them: `gh api --method POST repos/TableProApp/TablePro/environments/github-pages/deployment-branch-policies -f name='windows-v*' -f type=tag`.
7. **Environment `windows-winget`**, deploying from `windows-v*` tags only, with a required reviewer, and the secret `WINGET_TOKEN`: a classic token with the `public_repo` scope ([wingetcreate, token](https://github.com/microsoft/winget-create/blob/main/doc/token.md)). That scope writes to every public repository its account can, so the account is one outside TableProApp whose only use is its fork of microsoft/winget-pkgs.

## A release

1. **Dry run.** It builds, checks, installs and starts both packages as the tag does, writes the channel files into a copy of `gh-pages` and shows the change, and publishes nothing. Pass a beta's version, such as `0.2.0-beta.1`, to dry-run a beta. With `-f sign=true` it signs too, once `windows-release` also allows `main`; never a branch pattern, since whoever writes the branch writes the workflow that runs with the signing secrets.

   ```bash
   gh workflow run release-windows.yml --ref main -f version=X.Y.Z
   ```

2. **The tag**, on a `main` commit whose CI push run is green and whose `deny.toml` ignores no advisory on the grounds that Windows has no release:

   ```bash
   git fetch origin --tags
   gh run list --workflow ci.yml --branch main --event push --commit <commit>
   git tag -s windows-vX.Y.Z -m windows-vX.Y.Z <commit>
   git push origin windows-vX.Y.Z
   ```

   A beta's tag is `windows-vX.Y.Z-beta.N`, from the same kind of commit:

   ```bash
   git tag -s windows-vX.Y.Z-beta.N -m windows-vX.Y.Z-beta.N <commit>
   git push origin windows-vX.Y.Z-beta.N
   ```

3. **The workflow**, `gh run list --workflow release-windows.yml --limit 3`:
   - Builds an MSIX per architecture: Release configuration, the core in Cargo's release profile, Native AOT. It fails when the package's version, architecture or Windows 10 1809 floor is wrong, when it depends on a framework package, when `TablePro.dll` is in it, or when a binary in it imports the VC++ redistributable.
   - Bundles both under the package version, signs the bundle, which signs the packages in it, and writes the channel's App Installer file for it. A reviewer approves the step.
   - Installs the bundle on Windows Server 2022 (x64, build 20348, the oldest Windows a hosted runner has) and Windows 11 (Arm64), and runs `TheInstalledPackageStartsAndKeepsItsFilesInLocalState` from the UI tests on each, in light and dark.
   - For a release, writes the winget manifest and runs `winget validate` on it.
   - Publishes the GitHub release with the bundle, the App Installer file and `SHA256SUMS`, a pre-release for a beta, which a reviewer approves. The repository's latest release stays the macOS one.
   - Moves the channel files on `gh-pages` and deploys Pages, so installs on that channel find the update.
   - For a release, opens the winget-pkgs pull request with wingetcreate, which a reviewer approves.
4. **Afterwards**: check that `https://updates.tablepro.app/windows/TablePro.appinstaller` (or `TablePro-Beta.appinstaller`) names the new version, and watch the winget-pkgs pull request. Its bots validate and install the package, and a label such as `Needs-Author-Feedback` waits for an answer.

## When a run fails

- Nothing reaches users before the GitHub release job. Tags never move: a code fix lands on `main` and ships as the next number.
- The channel files or Pages failed after the GitHub release: `gh run rerun <run> --failed` runs them again; moving a channel to the version it already names changes nothing.
- A runner or network failure: `gh run rerun <run> --failed`.
- winget-pkgs rejects the pull request: fix `windows/ci/winget-manifest.py` on `main`, run it on the published bundle with the family name the install step printed, and submit that folder with `wingetcreate submit`. The release stays as published.
