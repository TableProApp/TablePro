# 0048: A self-hosted install signs in through an OIDC or a SAML 2.0 IdP

- **Status**: Accepted; step-up amended by 0051
- **Date**: 2026-11-24

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) signs a self-hosted install's people in with OIDC through coreos/go-oidc. It sends a SAML directory through a broker the customer runs, and lists SAML in tablepro-cloud as out of scope. On 2026-11-24 the maintainer decided that tablepro-cloud accepts SAML 2.0 itself. A customer signs its people in to another product through AWS IAM Identity Center customer managed SAML applications, and will not run Cognito or another broker.

- Identity Center connects an outside web application over SAML 2.0, from an organization instance only. Its OAuth 2.0 customer managed applications serve trusted identity propagation to AWS services, not sign-in to an application.
- Identity Center:
  - ignores AuthnRequest signatures;
  - sends no Single Logout to SAML applications;
  - signs with the active one of up to two certificates per application;
  - starts an SP-initiated sign-in from its portal tile through the application's start URL.
- The apps sign in through the server's own OAuth flow (0016, 0044). The IdP only authenticates the person inside that flow, so no app changes.
- SAML's Response arrives as a cross-site POST, like Apple's form_post. tablepro-cloud keeps such an answer under the state it names and checks the browser only on the GET that follows. A review of this design found that a victim's answer can then be kept under an attacker's state and finish the attacker's sign-in.
- Go's SAML libraries had many advisories in 2026.
  - crewjam/saml published 12 on 2026-11-07, six of them high or critical, all fixed by v0.6.1. It took 233 days to ship goxmldsig's signature bypass fix.
  - gosaml2 v0.12.0 still decrypts RSA PKCS#1 v1.5 key transport.

## Decision

An install signs in through one IdP, which the operator configures over OIDC or over SAML 2.0. SAML is a second upstream provider, `saml`, on the same sign-in path as `oidc`. It is SAML 2.0 Web Browser SSO, SP-initiated only, through crewjam/saml's `ServiceProvider`.

- **Selection.** Exactly one of `OIDC_ISSUER` and `SAML_IDP_ENTITY_ID`. For either protocol, the admin group is `IDP_ADMIN_GROUP_ID` and the button's name is `IDP_DISPLAY_NAME`.
- **SP-initiated only.**
  - The server sends an unsigned AuthnRequest over HTTP-Redirect, which Identity Center's metadata lists beside HTTP-POST. Its RelayState is the sign-in's state and its ID is the sign-in's nonce.
  - One ACS takes the Response over HTTP-POST. An unsolicited Response is refused.
  - Identity Center's tile opens the server's start URL.
- **Browser binding.**
  - A posted answer, SAML's Response or Apple's form_post, is kept only when the POST carries the answer key of the browser that started the sign-in.
  - The key is a `__Host-` cookie with SameSite=None, set at the start, one per browser. The state keeps its hash.
  - The GET that follows still checks the session's binding, and finishes only an answer kept with the key.
- **Trust.**
  - The IdP's metadata is a credential the operator installs, never fetched.
  - The server trusts every signing certificate in it, plus any the operator adds for a rotation.
  - The Response or its assertion must be signed by one of them. SHA-1 and RSA keys under 2048 bits are refused.
- **Checks.**
  - crewjam's checks run on the bytes the signature covers: one `#ID` Reference; Issuer; Destination and Recipient against the ACS; Audience against the SP's entity ID; the time window; InResponseTo against the request this browser started.
  - The SP holds no key, so an EncryptedAssertion is refused.
- **Replay.** A sign-in's state is single use and bound to the browser that started it, at the POST and at the GET. Assertion IDs are kept in Postgres until they expire.
- **Identity.** The IdP's entity ID and the NameID, whose format must be `persistent`. Email stays contact data (0044).
- **Admin.** With `IDP_ADMIN_GROUP_ID` set, the IdP's group decides the admins at each sign-in, through SAML's `groups` attribute or OIDC's groups claim, and the portal shows roles read-only. Without it, the owner makes a member an admin, or an admin a member, in the portal, each change audited, and a sign-in keeps the role. The owner stays owner either way.
- **Session.** SAML gives no refresh token, so the cap for an IdP without one always applies. Every app session's cap counts from the portal sign-in that approved the app, not from the first token of its family. `SessionNotOnOrAfter` is not read.
- **Library.** crewjam/saml at exactly v0.6.3, with goxmldsig v1.6.1 and etree v1.8.1, pinned in go.mod. Their advisories are watched by hand, since the Go vulnerability database lacks most of 2026's.

The variables, credentials and Identity Center steps are in tablepro-cloud's `docs/design/operations.md`, Self-hosted profile, Sign-in.

### What this changes in 0044

- **Hosting.** Identity runs OIDC or SAML sign-in. The first sign-in through the install's IdP that redeems the claim code becomes the owner.
- **Sign-in and SSO.** SAML is accepted directly, keyed by (entity ID, NameID). The admin group is matched at each sign-in, and for OIDC also at each upstream revalidation; an install without one has the admins its owner sets. Only LDAP goes through a broker.
- **Deprovisioning.** A SAML install never revalidates. A disable at its IdP reaches the apps within `SESSION_MAX_AGE_WITHOUT_IDP_REFRESH` of the last IdP sign-in, plus one access token. The team API tokens the person created and the invitation links they were handed stay until someone removes them in the portal.
- **Step-up.** SAML's form of it is ForceAuthn with a fresh AuthnInstant. It is held for the same release gate as `max_age=0`.
- **Out of scope.** SAML leaves the list. LDAP and SCIM in tablepro-cloud stay on it.

## Rationale

- crewjam/saml is the one maintained Go SP that:
  - refuses PKCS#1 v1.5;
  - ships the InResponseTo, audience, Recipient, Destination and replay checks;
  - trusts several certificates at once and refuses SHA-1.

  gosaml2 v0.12.0 leaves InResponseTo, replay and audience to the caller. hashicorp/cap/saml has no tag and wraps gosaml2.
- SP-initiated sign-in ties each Response to a request this browser started. An app's pending OAuth authorization needs exactly that. An unsolicited Response belongs to no request, so whoever holds one could sign any browser in. Identity Center's start URL keeps its tile working.
- The binding is checked where the answer arrives. RFC 6749 section 10.12: "The client MUST implement CSRF protection for its redirection URI." For SAML that endpoint is the ACS.
  - The session cookie is SameSite=Lax, which a cross-site POST does not carry. The check needs its own cookie with SameSite=None.
  - crewjam's own samlsp tracks requests in SameSite=None cookies and accepts only the posting browser's request IDs. ASP.NET Core's correlation cookie for OIDC and WS-Federation is SameSite=None for the same reason.
  - The `__Host-` prefix keeps a sibling subdomain from planting a key in a victim's browser.
- InResponseTo does a nonce's job: it ties the signed answer to the request. Storing the request ID as the sign-in's nonce reuses 0044's single-use sign-in state and its constant-time nonce check.
- A metadata file the operator installs is the IdP's trust anchor. crewjam does not verify metadata signatures. Identity Center reaches a service provider with a new certificate only when its admin carries it there.
- Identity Center gives SAML applications no encryption setting, so an SP key would be a credential with nothing to do.
- One IdP keeps one (issuer, subject) namespace and one source of roles.
- A NameID in `persistent` format is SAML's stable identifier, the counterpart of OIDC's `sub`. Identity Center sends `${user:subject}` in that format.
- An IdP group is the customer's own list of admins, so it stays authoritative when set. Not every install maps groups, and without them the owner would be the only admin, so the owner sets them then.
- The cap counts from the IdP sign-in because the apps send no `max_age`. A family started late in a portal session would otherwise outlive the IdP sign-in by up to twice the cap.

## Consequences

- tablepro-cloud gains:
  - crewjam/saml and a provider adapter;
  - an ACS that bypasses cross-origin protection as Apple's callback does, and checks the answer key instead;
  - an SP metadata endpoint;
  - `answer_key_hash` and `answer_key_matched` columns on `auth_states`, and a `saml_assertions` table pruned daily;
  - a daily log event for an IdP certificate within 30 days of expiry;
  - a Keycloak SAML IdP in its tests.
- Apple's form_post takes the same answer key. That closes the same gap on the SaaS, and ships before the SAML code. During that deploy, an Apple sign-in started or answered on the previous release is refused once.
- A browser that refuses the account host's cookies cannot sign in with Apple or SAML. It could not finish any sign-in before either, since the session is a cookie.
- `IdentityProvider.Exchange` takes the sign-in's nonce, and every provider adapter changes signature. `OIDC_ADMIN_GROUP_ID` and `OIDC_DISPLAY_NAME` are renamed before any install uses them, and the old names stop the server.
- A SAML install signs people in again at least every `SESSION_MAX_AGE_WITHOUT_IDP_REFRESH`. An admin group change takes effect at the next sign-in.
- Rotating the IdP's signing certificate is an operator step with a restart. An expired certificate refuses every sign-in.
- An OIDC IdP that gives no refresh token gets the same, shorter cap.
- Moving an install to another protocol or IdP changes every identity's issuer and subject. Nothing re-keys them, and email never links them. An IdP that keeps the same issuer and subject over the other protocol signs the same people in, and their identities drop the refresh tokens the new protocol cannot use.
- Identity Center sends `${user:subject}` as the user name, so a renamed user signs in as a new person, refused while the old account keeps the address. It signs both the Response and the assertion.
- crewjam/saml has one maintainer and a November 2026 rewrite with little production use behind it. We keep a real Identity Center Response as a test fixture, watch crewjam/saml, goxmldsig and etree for advisories, and move to v0.6.4 once it is tagged and reviewed.

## Alternatives considered

- **OIDC only, with Cognito or Keycloak as a broker.** The customer will not run one. A broker also answers refreshes from its own session, so a disable at the directory reaches the apps late.
- **gosaml2, hashicorp/cap/saml, or our own SP on goxmldsig as Dex builds.** See Rationale. Our own SP would rewrite the signature profile and checks crewjam has.
- **A fork of crewjam/saml, as Grafana, Teleport and Rancher run.** Forks lag the fixes, which left them on versions the 2026 advisories affect.
- **Checking the browser only on the GET after the POST.** The first draft of this design. A victim's Response could be kept under an attacker's state. The attacker's GET could then beat the victim's own GET, or win outright when a sibling subdomain makes a proxy refuse the victim's GET with oversized Lax cookies.
- **A one-time handle in the 303 Location, with every cookie Lax.** It closes the gap too. No SP library does it, and it checks at the GET what RFC 6749 checks at the endpoint the answer arrives at.
- **The portal session cookie as SameSite=None.** It would send the signed-in session with every cross-site request to the portal API. A narrow cookie that only the two answer routes read keeps Lax for everything else.
- **IdP-initiated sign-in.** No request binds the Response, and an app's authorization cannot continue from it.
- **The metadata URL, fetched and refreshed.** An outbound call that trusts whatever the URL serves next. A file is pinned and works air-gapped.
- **Both protocols on one install.** Two identity namespaces for one directory, and nothing a customer asked for.
- **Honoring `SessionNotOnOrAfter`.** Identity Center's one-hour default would send each app back through the browser every hour. It would also need an end per portal session and per token family.
- **Signed AuthnRequests or encrypted assertions.** Identity Center ignores the first and offers no setting for the second.

## Sources

- Organization instance only: https://docs.aws.amazon.com/singlesignon/latest/userguide/identity-center-instances.html, row "SAML 2.0 customer managed applications": Yes for the management account, No for member and standalone accounts. https://docs.aws.amazon.com/singlesignon/latest/userguide/customermanagedapps.html: "If your application supports SAML 2.0, you can connect it to an organization instance of IAM Identity Center."
- OAuth apps are for propagation: same page, "you can use the trusted identity propagation feature of IAM Identity Center to enable your application to request access to data in AWS services on behalf of your users."
- No request signature checks: https://docs.aws.amazon.com/singlesignon/latest/userguide/customermanagedapps-saml2-oauth2.html: "IAM Identity Center does not support validating signatures of incoming SAML authentication requests from SAML applications."
- No Single Logout: https://docs.aws.amazon.com/singlesignon/latest/userguide/authconcept.html: "Additionally, it doesn't send SAML Single Logout to SAML 2.0 applications that use IAM Identity Center as an identity provider."
- Two certificates: https://docs.aws.amazon.com/singlesignon/latest/userguide/rotatecert.html: "An application can have up to two certificates assigned to it. IAM Identity Center will use the certification that is set as active to sign all SAML assertions."
- Start URL: https://docs.aws.amazon.com/singlesignon/latest/userguide/appproperties.html: "The typical use is for an application that supports only service provider (SP)-initiated binding."
- HTTP-Redirect: an Identity Center application's metadata lists `SingleSignOnService` with HTTP-POST and HTTP-Redirect at one `/saml/assertion/<id>` URL, as committed in AWS's own sample, https://github.com/awslabs/data-solutions-framework-on-aws/blob/6ef8db802da6c949a061aa13759968d4736c5479/examples/opensearch-quickstart/stacks/resources/saml_metadata.xml#L14-L15. Amazon Cognito, which AWS documents as an Identity Center application, sends its request "in a URL parameter of the `HTTP GET` request" (https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-saml-idp-things-to-know.html).
- Session duration: same page, "For SAML 2.0, this is used to set the SessionNotOnOrAfter date of the SAML assertion's element saml2:AuthNStatement." Default: https://aws.amazon.com/blogs/big-data/configure-saml-federation-for-amazon-opensearch-serverless-with-aws-iam-identity-center/: "For Session duration, choose 1 hour (the default value)."
- Persistent subject: https://repost.aws/knowledge-center/cognito-user-pool-iam-integration: "enter ${user:subject}. For Format, enter Persistent."
- Binding at the redirection endpoint: https://www.rfc-editor.org/rfc/rfc6749#section-10.12: "This is typically accomplished by requiring any request sent to the redirection URI endpoint to include a value that binds the request to the user-agent's authenticated state".
- Lax and POST: https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie: "The request uses a safe method: in particular, this excludes POST, PUT, and DELETE." The `__Host-` prefix, same page: "This guarantees that such cookies are only sent to the host that set them, and not to any other host on the domain."
- crewjam's tracker: https://github.com/crewjam/saml/blob/v0.6.3/samlsp/request_tracker_cookie.go#L18-L23: "The cookie must be sent back by the browser when the IDP POSTs the SAML response to the ACS URL, which is a cross-site request."
- ASP.NET Core: https://learn.microsoft.com/en-us/aspnet/core/security/samesite: "The POST based redirects trigger the SameSite browser protections, so SameSite is disabled for these components." `RemoteAuthenticationOptions.CorrelationCookie` defaults to `None`.
- Replay: https://docs.oasis-open.org/security/saml/v2.0/saml-profiles-2.0-os.pdf, 4.1.4.5: "The service provider MUST ensure that bearer assertions are not replayed, by maintaining the set of used ID values for the length of time for which the assertion would be considered valid".
- Key size: https://doi.org/10.6028/NIST.SP.800-131Ar2: "Private-key lengths providing less than 112 bits of security shall not be used to generate digital signatures."
- PKCS#1 v1.5: https://github.com/crewjam/saml/security/advisories/GHSA-c422-f7gx-f42q: "`PKCS1v15` is no longer registered". https://github.com/russellhaering/gosaml2/blob/v0.12.0/types/encrypted_key.go#L164-L165 calls `rsa.DecryptPKCS1v15`.
- Metadata signatures: https://github.com/crewjam/saml/blob/v0.6.3/samlsp/fetch_metadata.go#L44: "ParseMetadata does not check a signature on the metadata, so the metadata must come from a source the caller trusts."
- 233 days: https://github.com/crewjam/saml/security/advisories/GHSA-ppgc-j585-q4j4: "Every release before v0.5.2 required a version of `github.com/russellhaering/goxmldsig` affected by CVE-2026-33487". goxmldsig fixed it on 2026-03-18, and crewjam PR #664 merged 2026-11-06.