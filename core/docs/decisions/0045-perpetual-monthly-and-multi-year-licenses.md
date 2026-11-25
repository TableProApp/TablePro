# 0045: A self-hosted license can be perpetual, monthly or prepaid for several years

- **Status**: Accepted; amends 0044; the grace of a monthly file superseded by 0046; the renewal call's bearer amended by 0050
- **Date**: 2026-11-24

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) licenses a self-hosted install with an offline file that ends at `exp`, and nothing in the install calls tablepro.app at runtime. On 2026-11-24 the maintainer set how Enterprise Self-Hosted sells: yearly, monthly, several years prepaid, or perpetual with a year of maintenance that the customer may extend.

- A perpetual install runs for good on the releases that came out while maintenance was active, and gets no fixes after it lapses.
- A monthly file is too short to install by hand. The server fetches each renewal from tablepro.app only when the customer turns that on, so an air-gapped install buys another type.

Prices, discounts and refunds are in tablepro-cloud's `docs/monetization-roadmap.md` and `docs/design/product.md`, not here.

## Decision

A license file carries either `exp` or a new `maintenance_until` claim. A perpetual file has no `exp` and covers each release dated on or before `maintenance_until`. An operator can turn on one outbound call that fetches newer files for the installed license from tablepro.app. It is off by default, and a monthly file needs it.

### License types

| Type | `exp` | `maintenance_until` | Renewed |
|---|---|---|---|
| Yearly | 3 days after the paid year ends | None | By hand or fetched |
| Several years prepaid | 3 days after the last paid year ends | None | By hand or fetched |
| Monthly | 3 days after the paid month ends | None | Fetched only |
| Perpetual | None | The end of the paid maintenance | By hand or fetched |
| Evaluation (`license_type` `trial`) | 30 days after issue | None | A new file, once |

- A file has exactly one of `exp` and `maintenance_until`. The server, `license install` and the apps refuse a file with both or neither.
- `maintenance_until` is a NumericDate (RFC 7519 section 2), a private claim beside `seats` and `features` (section 4.3).
- A staging install gets its own file for its own `origin`, with the production file's seats and term. No claim marks it.

### Perpetual

- Each release carries its release date, the tagged commit's time, stamped at build as its version is. `tablepro-cloud version` prints both.
- A perpetual file covers a release dated on or before its `maintenance_until`. A patch released after that date is not covered, security fixes included.
- `migrate up` refuses a release the file does not cover, before it changes the schema. `license install` and `serve` refuse it too. Each names the last release date the file covers.
- The check reads no clock. A covered release keeps running after maintenance ends, with no grace, banner or `license_expired`.
- Extending maintenance is a new file with a later `maintenance_until`, installed in place.
- The team portal shows when maintenance ends, and the server logs the 30 days before it as it logs an expiry window.

### Renewal from tablepro.app

- Off by default. The operator turns it on with `LICENSE_RENEWAL=on`. Any type may use it.
- Once a day the server calls `GET https://api.tablepro.app/v2/licenses/latest` with the installed file as its bearer token (RFC 6750). The call goes through the proxy `HTTPS_PROXY` names, as Go's `ProxyFromEnvironment` reads it. It carries nothing else: no seat count, usage or version.
- tablepro.app checks the bearer's signature and `sub`, not its `exp`, so an install in grace still gets its next file. It answers the newest file issued for that `sub` as `application/jwt`. A file is issued only for a paid period, so a lapsed or refunded license gets no newer one.
- The server verifies the answer as it verifies a file installed by hand. It installs it only when its `sub` and `origin` equal the installed file's and its `iat` is later. The install is audited, with the server as the actor.
- A failed call is logged and tried again the next day. The installed file keeps working to its `exp` and grace.
- With renewal on, the banner and the expiry log event start at `exp`, not 30 days before, since a paid renewal arrives before then.

### What does not change

- The file's format, signing key and custody, `typ`, the other claims, offline verification against compiled keys, and the revoked `kid` list.
- Seats as a hard cap pooled across the install, no device cap, and a seat change as a new file.
- 30 days' grace after `exp`. After it, pushes are refused with `license_expired`, and pulls and administration keep working.
- With renewal off, nothing in the install calls tablepro.app, and every type but monthly runs air-gapped.
- No online activation, usage report or telemetry. The renewal call fetches a file, and nothing waits on it.
- The apps verify the license as 0044 says, checking `exp` when the file has one. They do not read `maintenance_until`, which bounds only the server's releases.

## Rationale

- `exp` is optional in RFC 7519, so a perpetual file is a standard JWT that states no false end.
- The tagged commit's time is the same for every build of a tag. A build's own time would move with each rebuild.
- Migrations are forward-only (0044, Releases and upgrades). Refused in `migrate up`, an uncovered upgrade goes back to the previous image with no restore.
- The installed file as the bearer needs no second secret. It grants only its own renewals, for the origin it names.
- The 3 days past the paid period let a daily fetch pick up the next file before the installed one ends, as short-lived certificates are renewed before they expire.

## Consequences

- 0044's "nothing in it calls tablepro.app at runtime" holds only with renewal off. Its out-of-scope phone-home licensing now excepts this opt-in fetch, which reports nothing.
- Anyone holding a copy of a file can fetch its renewals, as anyone holding a copy could already use it. The subscription terms cover both.
- An install that stops paying keeps pushing through the 3 days and the 30 days' grace, monthly included, as any expired file does.
- tablepro-cloud gains the endpoint, the release date stamp, `maintenance_until` in its issuer and verifier, and the checks in `migrate up`, `license install` and `serve`. Its `docs/design` describes them.
- The core's license verifier accepts a file with no `exp` when it has `maintenance_until`.

## Alternatives considered

- **A perpetual file with a far-off `exp`.** The claim would state an end that is not one, and nothing would bound the releases it runs.
- **`maintenance_until` against the clock.** The install would stop when maintenance lapses instead of running for good.
- **A renewal secret issued beside the file, as an OAuth refresh token.** One more secret to store and rotate, guarding files that hold none.
- **Monthly files installed by hand.** An operator task every month, and a missed one is a lapse.
- **tablepro.app pushing files to the server.** It needs a way into the customer's network, which an outbound fetch does not.
