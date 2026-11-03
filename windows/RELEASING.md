# Releasing

`.github/workflows/release-windows.yml` builds and publishes a Windows release. [ADR 0005](docs/decisions/0005-distribution.md) says why MSIX, self-contained, Native AOT, Artifact Signing and winget. An agent runs these commands when the maintainer says to release; it never creates the tag on its own.

## What a release ships

- `TablePro_X.Y.Z.0_x64_arm64.msixbundle` on the `windows-vX.Y.Z` GitHub release, with `SHA256SUMS`: the x64 and Arm64 MSIX in one bundle, signed with Azure Artifact Signing. Windows installs the package for its own architecture.
- A pull request to microsoft/winget-pkgs that adds `TablePro.TablePro` X.Y.Z, so `winget install TablePro.TablePro` gets it once Microsoft merges it.

## Versions

- A tag is `windows-vX.Y.Z`, each number at most 65535. The package version is `X.Y.Z.0`.
- There is no pre-release tag. MSIX orders versions by their four numbers, so a beta could not sort below its stable.
- The tag is the only place the version is written. The workflow sets it in `Package.appxmanifest` and passes `-p:Version`, which Settings shows. A local build keeps the csproj's `0.1.0`.

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
6. **Environment `windows-winget`**, deploying from `windows-v*` tags only, with a required reviewer, and the secret `WINGET_TOKEN`: a classic token with the `public_repo` scope ([wingetcreate, token](https://github.com/microsoft/winget-create/blob/main/doc/token.md)). That scope writes to every public repository its account can, so the account is one outside TableProApp whose only use is its fork of microsoft/winget-pkgs.

## A release

1. **Dry run.** It builds, checks, installs and starts both packages as the tag does, and publishes nothing. With `-f sign=true` it signs too, once `windows-release` also allows `main`; never a branch pattern, since whoever writes the branch writes the workflow that runs with the signing secrets.

   ```bash
   gh workflow run release-windows.yml --ref main -f version=X.Y.Z
   ```

2. **The tag**, on a `main` commit whose CI push run is green:

   ```bash
   git fetch origin --tags
   gh run list --workflow ci.yml --branch main --event push --commit <commit>
   git tag -s windows-vX.Y.Z -m windows-vX.Y.Z <commit>
   git push origin windows-vX.Y.Z
   ```

3. **The workflow**, `gh run list --workflow release-windows.yml --limit 3`:
   - Builds an MSIX per architecture: Release configuration, the core in Cargo's release profile, Native AOT. It fails when the package's version, architecture or Windows 10 1809 floor is wrong, when it depends on a framework package, when `TablePro.dll` is in it, or when a binary in it imports the VC++ redistributable.
   - Bundles both and signs the bundle, which signs the packages in it. A reviewer approves the step.
   - Installs the bundle on Windows Server 2022 (x64, build 20348, the oldest Windows a hosted runner has) and Windows 11 (Arm64), and runs `TheInstalledPackageStartsAndKeepsItsFilesInLocalState` from the UI tests on each, in light and dark.
   - Writes the winget manifest and runs `winget validate` on it.
   - Publishes the GitHub release, which a reviewer approves. The repository's latest release stays the macOS one.
   - Opens the winget-pkgs pull request with wingetcreate, which a reviewer approves.
4. **Afterwards**: watch the winget-pkgs pull request. Its bots validate and install the package, and a label such as `Needs-Author-Feedback` waits for an answer.

## When a run fails

- Nothing reaches users before the GitHub release job. Tags never move: a code fix lands on `main` and ships as the next number.
- A runner or network failure: `gh run rerun <run> --failed`.
- winget-pkgs rejects the pull request: fix `windows/ci/winget-manifest.py` on `main`, run it on the published bundle with the family name the install step printed, and submit that folder with `wingetcreate submit`. The release stays as published.
