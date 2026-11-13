# 0025: The Windows app signs in to its TablePro account through the FFI

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

[0016](0016-tablepro-accounts.md) put the account in `tablepro-account` and left the Windows app to adopt it through `ffi` once tablepro-cloud registered a Windows client. On 2026-11-13 the maintainer decided that Windows gets account sign-in in the share-links round, since a share link needs a signed-in account. tablepro-cloud registers the public client `tablepro-windows`, with a loopback redirect on any port as `tablepro-linux` has, and the device platform `windows` (its `docs/design/clients.md`, Windows).

## Decision

`ffi` builds the account from `tablepro-account` and passes in what Windows does its own way:

| Seam | Windows app |
| --- | --- |
| `RefreshTokenVault` | the Core's own secret store: the generic credential `TablePro/account-refresh-token` in Credential Manager under `Core::with_system_secrets`, or the host's `SecretItemTag::AccountRefreshToken` under `Core::new` |
| `BrowserLauncher` | the `HostBrowser` callback, on a thread the core lets block |
| `MachineId` | `MachineId::derive_machine_guid` of `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`, read from the 64-bit registry view with `RegGetValueW` |
| `AppClient` | `AppClient::WINDOWS`: client `tablepro-windows`, platform `windows` |
| `AccountSettings::account_file` | the path the app gives in `AccountConfig` |

- **Machine ID.** HMAC-SHA256 keyed with `app.tablepro.TablePro` over the 16 bytes the GUID's 32 hex digits write, in the order they are written, as 64 lowercase hex characters: Linux's rule for `/etc/machine-id`, so the same 16 bytes name the same device on both. The written order, not the mixed-endian layout of a Windows `GUID` struct, since the value is text in the registry and nothing reads it as a struct. A host off Windows gives the GUID in `AccountConfig::machine_guid`.
- **The object.** `Core::open_account(config, browser, listener)` returns an `AccountService`, which restores the last sign-in and runs the refresh schedule until it is dropped. Its calls are the account's: sign-in with a `CancelToken` that ends only the wait for the browser, sign-out, refresh, the refresh past the device limit, profile, devices, remove device, and `feature_access`.
- **Status.** `status()` is a snapshot record: the state, the entitlement's account, features and licenses, its expiry and the problem with its code or the devices that hold the license. `AccountListener::status_changed` only signals, on a runtime thread, as `RunListener` does; the app reads `status()` on its own thread.
- **Errors.** `From<AccountError> for CoreError` keeps `AccountError::code()`. A cancelled sign-in is `CoreError::Cancelled`. A refusal keeps the server's problem code and detail in `ErrorInfo::server`.

## Consequences

- `SecretItemTag` gains `AccountRefreshToken`, which only the account asks for; `tablepro_core::credentials::SecretItem` does not, so the Linux keyring keeps its own item ([0016](0016-tablepro-accounts.md), Alternatives).
- The C# bindings change with the new objects, records and callbacks, and the Windows app words every `account.*` code.
- The Mac keeps its own Swift account service; its client's redirect is a custom scheme this crate does not listen on.

## Alternatives considered

- **The app reads MachineGuid in C# and passes the text in, as Linux reads `/etc/machine-id`.** The registry view and the parsing are then the app's to get right, and the GUID would cross the FFI on every start. The core already holds the Windows calls for Credential Manager.
- **A separate `HostTokenVault` callback for the refresh token.** The Core already owns the secret store each host chose; one more callback would let the token land in a different store from every other secret.
