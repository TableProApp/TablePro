# winget manifests

The three YAML files here are templates for the `TableProApp.TablePro` package in [winget-pkgs](https://github.com/microsoft/winget-pkgs). Each `{{Name}}` is filled per release.

## How a release fills them

1. A stable `windows-vX.Y.Z` tag runs `release-windows.yml`.
2. Its `publish` job runs `windows/packaging/winget-manifest.ps1` on the signed release files. The script writes the SHA-256 of each MSIX and zip, the digest of each MSIX signature, the package family name from the signing certificate, the release date and the release notes link.
3. The filled manifests are the `winget-manifests` artifact of that run, laid out as `manifests/t/TableProApp/TablePro/X.Y.Z/`.

A beta fills nothing: winget lists stable releases only.

## Submitting

The first release, from the downloaded artifact:

```powershell
winget validate --manifest manifests\t\TableProApp\TablePro\X.Y.Z
winget install --manifest manifests\t\TableProApp\TablePro\X.Y.Z
wingetcreate submit manifests\t\TableProApp\TablePro\X.Y.Z
```

Every later release can submit the artifact the same way, or let wingetcreate compute the hashes from the release URLs:

```powershell
wingetcreate update TableProApp.TablePro --version X.Y.Z --submit `
  --urls https://github.com/TableProApp/TablePro/releases/download/windows-vX.Y.Z/TablePro-X.Y.Z-x64.msix `
         https://github.com/TableProApp/TablePro/releases/download/windows-vX.Y.Z/TablePro-X.Y.Z-arm64.msix `
         https://github.com/TableProApp/TablePro/releases/download/windows-vX.Y.Z/TablePro-X.Y.Z-x64.zip `
         https://github.com/TableProApp/TablePro/releases/download/windows-vX.Y.Z/TablePro-X.Y.Z-arm64.zip
```

winget accepts only a signed MSIX, so a release built without the signing certificate cannot be submitted.
