# 0050: A self-hosted license renewal is requested by tablepro.app and signed by the operator

- **Status**: Accepted; amends 0044 and 0045; supersedes the monthly grace of 0046
- **Date**: 2026-11-25

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) licenses a self-hosted install with an offline file signed by an AWS KMS key the SaaS's role cannot use: "Our admin records a license request, audited, and a person signs it." [0045](0045-perpetual-monthly-and-multi-year-licenses.md) sells a monthly term whose files the server fetches from tablepro.app with the installed file as the bearer, and [0046](0046-a-monthly-license-has-7-days-grace.md) gives a monthly file 7 days' grace. Here the operator is the person at TablePro who signs license files, not a customer's admin.

Today Polar sells Enterprise Self-Hosted through checkout links. tablepro-cloud records each paid order and logs a warning, and the operator types every claim into `license sign` and emails the file.

- No record ties a license to its subscription, its origin or the files issued for it.
- Polar names `seats` only on a checkout's order, so renewals and seat changes are recorded without seats. Self-hosted subscriptions are not mirrored.
- Nothing tells the operator a file is due, nothing delivers it, and the fetch is not built.
- Polar charges a renewal when the new period starts. A failed charge is retried 2, 7, 14 and 21 days after the first failure, then Polar revokes the subscription. With 7 days' grace, a monthly customer who pays on the third or fourth retry has pushes refused until the new file lands.

On 2026-11-25 the maintainer decided that tablepro.app works out each renewal from Polar and the operator signs it, and extended a monthly file's grace to cover Polar's retries.

## Decision

tablepro.app works out from Polar's paid state the file each self-hosted license should have, and opens a signing request when it differs from the last one. The operator signs the pending requests on a Mac with KMS under their own AWS session, reaching the host over an SSH key restricted to two commands. The signer checks each request against the license's previous file, and the host verifies each signed file before recording it. The renewal fetch answers only a bearer the SaaS recorded. A customer gets each file from their tablepro.app account, a link in an email, or the fetch. A monthly file has 21 days' grace.

### Request

- The SaaS mirrors Enterprise Self-Hosted subscriptions and paid orders outside its catalog, so nothing on the SaaS grants Team from them.
- The operator binds a paid subscription to a license once with `license bind`, giving the install's origin. A license keeps its `sub`, so an evaluation's or an earlier file's `sub` carries over.
- For each bound license the SaaS works out the file it should have:
  - `exp` 3 days after the latest paid period, as 0045 set;
  - `grace_until` as in Grace below;
  - `seats` from the subscription, not the order;
  - `features` from the product and `origin` from the bind.
- When that differs from the newest file issued or requested, it opens a request that fixes every claim, `jti`, `iat` and `nbf` included, so signing it twice gives the same claims. A newer state cancels the pending request and opens one in its place.
- Every webhook and the daily reconciliation run the same comparison, so order, redelivery and a missed event change nothing.
- Only a paid order moves `exp`, never Polar's cycle event, which fires whether or not the charge succeeds. An end never moves earlier: a refund or a downgrade opens no shorter file.
- The admin watchdog emails the operator while a request waits, and again every 24 hours.

### Sign and record

- The operator runs `ssh <host> requests | tablepro-cloud license sign --requests - | ssh <host> record`.
- The host installs that SSH key with `restrict,command=`, and the command accepts `requests` and `record` only, as the deploy's CI key does. No new internet-facing sign-in, and no database credentials on the Mac.
- `license sign` signs with the KMS license key under the operator's own AWS session. Key custody stays as 0044 set it.
- The signer treats the SaaS as untrusted and checks each request against the license's newest recorded file, which only our key could have signed:
  - that file verifies with the build's keys, a revoked `kid` allowed for this check only, and has the request's `sub`;
  - the same `origin`, `features` and `license_type`, trial to paid allowed;
  - a later `iat`, an `exp` no earlier, `grace_until` 21 days after `exp` on a one-month term and 30 on any other, and seats within the build's limit.
- A first file, or a change of origin or features, needs its own confirmation by name. Otherwise the signer prints one line per request and asks once on the terminal.
- `license record` on the host verifies each signed file as a customer's install would, for the request's origin and with no revoked `kid`. It checks the claims equal the request's, stores the file and audits it with its `kid`, `jti`, digest and signer. A file that differs is refused, and the same file again is already recorded.

### The renewal fetch

- `GET https://api.tablepro.app/v2/licenses/latest` looks the bearer up by its SHA-256 among the files the SaaS recorded. An unknown bearer gets 401 `invalid_token` (RFC 6750). This replaces 0045's check of the bearer's signature and `sub`.
- It answers the newest recorded file of that license, which may be the bearer itself. It reads no `exp`, so an install in grace or past it gets its next file.
- The server side stays as 0045 set it: off by default, `LICENSE_RENEWAL=on`, daily, through `HTTPS_PROXY`, and the answer installed only for the same `sub` and origin with a later `iat`.
- A monthly license requires the fetch. A site that cannot reach tablepro.app buys another term.

### Delivery

- **Account.** A bound license links to the Polar customer's tablepro.app account, created when needed. Billing there lists the account's self-hosted licenses and downloads the newest file of each. Only the buyer sees them for now.
- **Email.** Each recorded file sends the buyer an email that names the license and its dates and links to Billing. The file is never attached.
- **Fetch.** An install with renewal on installs the file within a day.
- The apps read the new file from their server through `GET /v2/license`, as today.

### Grace

- A monthly file's `grace_until` is 21 days after `exp`, in place of 0046's 7. With `exp` 3 days past the paid month, pushes stop 24 days after it ends, 3 days after Polar's last retry.
- Yearly, several years prepaid and evaluation files keep 30 days. A perpetual file still has neither `exp` nor `grace_until`.
- The rest of 0046 stands: the claim, its checks, and `license_expired` past it.

## Rationale

- The SaaS knows who paid for what, and only the signing key makes a file. Kept apart, a compromised SaaS cannot mint a license, as 0044 intends.
- A desired file worked out from Polar's state, not from single events, makes duplicated, late or missed webhooks harmless.
- A request that fixes every claim turns a failed run into a retry: the rest stays pending, and recording the same file twice changes nothing.
- The previous file is the one input the SaaS cannot forge, so the signer checks against it and needs no Polar credential of its own.
- A recorded bearer answers only for files we issued. A file signed by a leaked or retired key fetches nothing. An install whose file a later release revoked still fetches its reissued file and heals within a day, as EST re-enrollment (RFC 7030 section 4.2.2) authenticates a renewal by the certificate it renews.
- 21 days covers Polar's whole retry schedule plus time to sign and fetch, so a customer who pays never sees pushes pause.
- The server and the apps read `grace_until` (0046), so the longer grace changes only the issuer and the signer's check.

## Consequences

- An unpaid monthly customer keeps full use for 24 days after the paid month ends, then pushes stop. Pulls and administration keep working, as for any lapsed file. That is 14 days more than 0046 allowed.
- A failed fetch on a monthly install has 24 days to succeed, not 10.
- 0044's license request is now opened by the SaaS from Polar's state, or by the operator through `license bind` or a reissue.
- A compromised SaaS can open false requests, which the signer limits to licenses we already signed, at the same origin and features, with a later end. What remains is a free month for a real customer, shown to the operator as a request with no Polar order they recognize. It can also withhold files, which the watchdog and support surface, or leak recorded files, copies 0045 already accepts.
- A compromised Mac or AWS session can sign anything, as before. A CloudTrail alert on every `kms:Sign` of the license keys keeps a record apart from `license record`.
- A key rotation signs with the next key, reissues every active license, then ships a release that revokes the old `kid`. An install that upgrades first fetches its reissued file with its recorded, now revoked, bearer.
- Perpetual files fit the same record, with `maintenance_until` set by the operator until maintenance renewals are decided.
- tablepro-cloud gains the subscription mirror, the license record, the watchdog items, the operator commands, the restricted key, the Billing section, the email and the fetch. Its `docs/design` describes them.
- The docs site's licensing and operations pages change once the fetch ships.

## Alternatives considered

- **An HTTPS operator API**, with an OAuth device grant and a passkey to approve. A new internet-facing way in, for a task one person runs from one Mac.
- **The SaaS signs.** Whoever takes the SaaS then mints licenses, which 0044's custody rules out.
- **Pre-signing the next period and holding it until payment.** A valid file for an unpaid period would sit on the SaaS. The grace and a daily reminder leave time to sign after payment.
- **The origin from a checkout field.** It is the one claim no check can confirm. A buyer types it, often before the server has an address, and a typo is a file that installs nowhere.
- **Keeping 7 days' grace.** A customer who pays on Polar's last retry would have pushes refused for 11 days or more, and changes made meanwhile wait on each Mac.
