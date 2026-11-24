# 0047: The Apple apps sign in through the core

- **Status**: Accepted
- **Date**: 2026-11-24

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) gives the Mac an account slice before the self-hosted preview: the Mac uses `tablepro-account` through TableProFFI, signs in to tablepro.app or a company server, and trusts a company server's entitlements only through its license. [0016](0016-tablepro-accounts.md) built the account for loopback redirects, and [0026](0026-the-windows-app-signs-in-through-the-ffi.md) gave a host one refresh token item for every server.

A signed-in Mac holds today:

- its refresh token in the Keychain item `com.TablePro.account.refreshToken`;
- its entitlement in `Account/entitlement.jwt`, whose `dev` claim names its device;
- a machine ID that is the SHA-256 of its hardware UUID, which the license system registered;
- for some, a license key from before accounts.

The `tablepro-macos` client redirects to `app.tablepro:/oauth/callback`, which `ASWebAuthenticationSession` answers, not a listener.

## Decision

The account takes the Mac's seams through the FFI, resolves and discovers the server itself, and verifies a company server's license before any of its entitlements.

| Seam | Mac |
| --- | --- |
| `AppClient` | `AppClient::MACOS`: client `tablepro-macos`, platform `macos`, redirect `Redirect::Scheme("app.tablepro")` |
| Sign-in page | `HostWebAuthenticator::authenticate(url, callback_scheme)`, which returns the callback URL or `HostBrowserError::Cancelled` |
| Machine ID | `AccountConfig::machine_id`, the host's 64 hex characters, through `MachineId::from_hex` |
| Refresh token | tablepro.app's in `SecretItemTag::AccountRefreshToken`, the Keychain item above; any other server's in `AccountRefreshTokenFor { sign_in_key }` |
| Server policy | `managed_server_url` and `allow_other_servers`, each only when `objectIsForced` says so |
| Old entitlement | `legacy_entitlement_file`, the path of `Account/entitlement.jwt` |

### The server

- **Resolution.** A managed URL with `allow_other_servers` false is the server, and `choose_server` is refused with `account.server_managed`. A managed URL that allows others is the default the person may leave. Otherwise the person's choice, then tablepro.app. `AllowOtherAccountServers` alone is ignored and logged, since it hides both tablepro.app and manual entry and leaves nothing.
- **Addresses.** An https origin with no path, user, query or fragment: the API's, which a license names as its `origin`. A bare host is read as https. Http only to a loopback host, `.localhost` included, and only in a development build.
- **Kept beside the account file.** `account-server.json` holds only the choice, so a sign-out keeps it. Choosing another server revokes the sign-in and signs out first; choosing the same one keeps it. `account.json` names its server, and one of another server, as after the organization changed its value, is dropped at launch with that server's refresh token.
- **Discovery.** RFC 9728 metadata at the origin, whose `resource` must be the origin; OpenID Connect discovery at its first authorization server, whose `issuer` must be that server and never tablepro.app's. The OAuth endpoints are https on the issuer's origin, so a server cannot send the person to one sign-in page and the code to another token endpoint; `jwks_uri` is on the API's origin; no request follows a redirect; each answer is capped at 64 KiB. Discovery runs when a run first needs the endpoints and at each sign-in, after the account file has restored what it verifies, honours a 429's `Retry-After`, and is never kept on disk, since a file another process can write must not say where a refresh token goes. tablepro.app keeps its compiled endpoints.
- **Fixed servers.** `ServerSettings::Fixed` is one server for good: tablepro.app for an app that offers no other, as Linux today, or a development stack. `Account::new`, which keeps every sign-in in one secret item, takes only a fixed server, so no choice file can send tablepro.app's token elsewhere.

### The license chain

- After sign-in and at each entitlement refresh: `GET /v2/license`, verified offline against the license keys the build ships, current and next, minus the revoked `kid` list. It checks `alg`, `typ` `license+jwt`, `iss` `https://tablepro.app`, `aud` `tablepro-app`, `origin`, `nbf` with 300 seconds of leeway, exactly one of `exp` and `maintenance_until`, and `grace_until` with `exp` only and later than it ([0046](0046-a-monthly-license-has-7-days-grace.md)).
- Then the JWKS from `jwks_uri`, each Ed25519 key kept by its RFC 7638 thumbprint. Entitlements verify against those keys only, with `iss` the API origin.
- Features are the entitlement's cut to the license's. Past `grace_until` only `team_library` works and the rest read `Expired`, so the Mac pulls and exports while the server refuses pushes (0044, Expiry). A perpetual license never ends for the apps (0045).
- The license and JWKS are kept in `account.json` and verified again at each launch, so a restore without the network still works and a `kid` revoked by an update admits nothing. An HMAC keyed with the refresh token, rewritten at each rotation, binds them to the sign-in, so keys another process wrote into the file admit nothing.
- A newly verified license applies to the entitlement held at once, before its keys load and before the next entitlement comes, and one that no longer verifies drops the entitlement it admitted.
- Every entitlement's `iss` is checked: `https://api.tablepro.app` for tablepro.app, the API origin for a development stack.

### The Mac's flows

- **Sign-in.** The authorization URL carries `redirect_uri` `app.tablepro:/oauth/callback`. The callback must come back on that scheme and path with this request's `state`. A cancel from either side ends only the wait, and a sign-in a later one or a sign-out superseded is revoked, as 0016 says.
- **License key.** An RFC 8693 token exchange with tablepro-cloud's subject token type (its api.md, Legacy key exchange), then the idempotent `POST /v2/devices` and the entitlement. `invalid_grant` is `account.sign_in_refused`. A company server never gets a key and refuses with `account.server_unsupported`, as it does an offline file.
- **Adoption.** With no `account.json` and an `entitlement.jwt`, the core opens the production Keychain item. With a token, the Mac is signed in: the device and account come from the entitlement when it verifies for this machine, expired or not, `account.json` is written, then `entitlement.jwt` is deleted. With no token, an offline file the Mac imported without signing in, still valid for this machine, becomes the account file's offline file; anything else is deleted and the Mac starts signed out. With a locked Keychain both wait for the next launch. A company server adopts nothing.
- **Bearer.** `access_token` and `access_token_rejected` give the Team Library and share clients, which stay generated Swift, the bearer and the `/v2` base.
- **Shared links.** A `tablepro://share` link names no server and only tablepro.app makes them, so it is read from tablepro.app whatever company server is signed in, and that server never sees its token or password.
- **Leaving a server.** Choosing another server revokes the sign-in on the one left, finding its endpoints first when this run started offline.
- **Sign-out causes.** `AccountListener::signed_out` says why: asked, refused, device removed or server changed.

### Development builds

`account_url`, `api_url`, `entitlement_keys` and `license_keys` are refused with `ffi.account_config` in a release build. The fields stay in every build, since a field behind `cfg` would make the two builds' bindings differ.

## Consequences

- `SecretItemTag` gains a variant with a field, so C# reads it as a class hierarchy. The Windows `ISecretStore` takes a `SecretItem` record with the sign-in key, and its tests ask for the keyed item on a development stack.
- `AccountSettings` takes a `ServerSettings` in place of endpoints and keys; the Linux app passes tablepro.app or its development stack.
- A release build trusts the two license keys whose private halves are the KMS keys of 0044, Key custody: `Yo4CIBJnxzUMSLPnsLId8ngVVe5xuZgHkOU9Z-Hgo04`, current, and `J5yCP_8iTKHyXvyYQ9y4-D2-Z_U4hbtGDvwkfzv57R0`, next. Test keys reach only a development build.
- RFC 9207's `iss` in the authorization response is not checked yet, a stated preview risk 0044 keeps as a release gate. A company server that names another company's account server can still receive that server's access tokens until it is.
- The iOS app takes the same seams once it has an account.

## Alternatives considered

- **The choice in the host's defaults.** Each app would resolve the policy its own way, and a sign-out could not tell which server's token to remove.
- **A managed URL always forced.** `AllowOtherAccountServers` would then mean nothing.
- **A `jwks_uri` on any https origin.** The keys must come from the server whose license names that origin.
- **Discovery kept on disk for offline launches.** Whoever writes the file would choose the token endpoint; a refresh needs the network anyway.
- **`dev` read from the exchanged access token.** `POST /v2/devices` answers the device the exchange registered, as clients.md has the Mac do.
- **One host item for every server.** A company server's rotated token would overwrite tablepro.app's, and presenting the old one again revokes its family.
