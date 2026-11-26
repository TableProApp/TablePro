use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, TimeDelta, Utc};
use jsonwebtoken::errors::ErrorKind;
use jsonwebtoken::{Algorithm, Validation};
use serde::{Deserialize, Serialize};

use crate::entitlement_keys::EntitlementKeys;
use crate::license::License;

pub const TOKEN_TYPE: &str = "tablepro-entitlement+jwt";
const AUDIENCE: &str = "tablepro-app";
// For a local clock that runs behind the server's.
pub const NOT_BEFORE_LEEWAY: TimeDelta = TimeDelta::seconds(300);

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EntitlementError {
    #[error("the entitlement is not a signed token: {0}")]
    Malformed(String),
    #[error("the entitlement is signed with {0}, not EdDSA")]
    Algorithm(String),
    #[error("the token is not an entitlement (typ {0:?})")]
    Type(Option<String>),
    #[error("the entitlement is signed with a key this build does not have ({0:?})")]
    UnknownKey(Option<String>),
    #[error("the entitlement's signature does not verify")]
    Signature,
    #[error("the entitlement is for another audience")]
    Audience,
    #[error("the entitlement was issued by another server")]
    Issuer,
    #[error("the entitlement was issued to another machine")]
    Machine,
    #[error("the entitlement is not valid before {0}")]
    NotYetValid(DateTime<Utc>),
    #[error("the entitlement expired at {0}")]
    Expired(DateTime<Utc>),
}

// Licenses and the account are for display; only `features` unlocks anything.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntitlementClaims {
    pub iss: String,
    pub aud: String,
    pub sub: String,
    pub jti: String,
    pub iat: i64,
    pub nbf: i64,
    pub exp: i64,
    pub dev: String,
    pub mid: String,
    pub features: Vec<String>,
    pub licenses: Vec<LicenseClaim>,
    pub account: AccountClaim,
    #[serde(default)]
    pub offline: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LicenseClaim {
    pub id: String,
    pub plan: String,
    pub cycle: String,
    pub source: String,
    pub status: String,
    pub renews_at: Option<DateTime<Utc>>,
    pub ends_at: Option<DateTime<Utc>>,
    pub team: Option<TeamClaim>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamClaim {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountClaim {
    pub email: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entitlement {
    token: String,
    claims: EntitlementClaims,
    expires_at: DateTime<Utc>,
    // A company server's license, which cuts the features to its own.
    license: Option<Arc<License>>,
}

#[derive(Deserialize)]
pub(crate) struct Header {
    pub alg: String,
    pub typ: Option<String>,
    pub kid: Option<String>,
}

impl Entitlement {
    // jsonwebtoken reads the system clock and would give `exp` the leeway too, so the times are checked here.
    // `issuer` is the API origin of the server the account signs in to (RFC 8725 section 3.11).
    pub fn verify(
        token: &str,
        keys: &EntitlementKeys,
        issuer: &str,
        machine_id: &str,
        now: DateTime<Utc>,
    ) -> Result<Self, EntitlementError> {
        let header = decode_header(token).map_err(EntitlementError::Malformed)?;
        if header.alg != "EdDSA" {
            return Err(EntitlementError::Algorithm(header.alg));
        }
        if header.typ.as_deref() != Some(TOKEN_TYPE) {
            return Err(EntitlementError::Type(header.typ));
        }
        let key = header
            .kid
            .as_deref()
            .and_then(|kid| keys.get(kid))
            .ok_or_else(|| EntitlementError::UnknownKey(header.kid.clone()))?;
        let claims = jsonwebtoken::decode::<EntitlementClaims>(token, key, &validation(issuer))
            .map_err(|error| match error.kind() {
                ErrorKind::InvalidSignature => EntitlementError::Signature,
                ErrorKind::InvalidAudience => EntitlementError::Audience,
                ErrorKind::InvalidIssuer => EntitlementError::Issuer,
                _ => EntitlementError::Malformed(error.to_string()),
            })?
            .claims;
        if claims.mid != machine_id {
            return Err(EntitlementError::Machine);
        }
        let not_before = timestamp(claims.nbf)?;
        if not_before > now + NOT_BEFORE_LEEWAY {
            return Err(EntitlementError::NotYetValid(not_before));
        }
        let expires_at = timestamp(claims.exp)?;
        if now >= expires_at {
            return Err(EntitlementError::Expired(expires_at));
        }
        Ok(Self {
            token: token.to_owned(),
            claims,
            expires_at,
            license: None,
        })
    }

    pub(crate) fn within(self, license: Arc<License>) -> Self {
        Self {
            license: Some(license),
            ..self
        }
    }

    pub fn license(&self) -> Option<&License> {
        self.license.as_deref()
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    pub fn claims(&self) -> &EntitlementClaims {
        &self.claims
    }

    pub fn expires_at(&self) -> DateTime<Utc> {
        self.expires_at
    }

    pub fn is_current(&self, now: DateTime<Utc>) -> bool {
        now < self.expires_at
    }

    // In the entitlement, and in the company server's license when there is one.
    pub fn includes(&self, feature: &str) -> bool {
        self.claims.features.iter().any(|code| code == feature)
            && self.license.as_ref().is_none_or(|license| license.includes(feature))
    }

    // Whether the server's license still lets an included feature work: past its grace, only the sync features do.
    pub fn license_allows(&self, feature: &str, now: DateTime<Utc>) -> bool {
        self.license.as_ref().is_none_or(|license| license.allows(feature, now))
    }

    // The codes that work now, in the entitlement's order.
    pub fn features_at(&self, now: DateTime<Utc>) -> Vec<String> {
        self.claims
            .features
            .iter()
            .filter(|code| self.includes(code) && self.license_allows(code, now))
            .cloned()
            .collect()
    }
}

pub(crate) fn decode_header(token: &str) -> Result<Header, String> {
    let mut parts = token.split('.');
    let (Some(header), Some(_), Some(_), None) = (parts.next(), parts.next(), parts.next(), parts.next()) else {
        return Err("not three dot-separated parts".to_owned());
    };
    let json = URL_SAFE_NO_PAD
        .decode(header)
        .map_err(|_| "the header is not base64url".to_owned())?;
    serde_json::from_slice(&json).map_err(|error| error.to_string())
}

fn validation(issuer: &str) -> Validation {
    let mut validation = Validation::new(Algorithm::EdDSA);
    validation.validate_exp = false;
    validation.validate_nbf = false;
    validation.required_spec_claims = ["aud", "exp", "iss", "nbf"].into_iter().map(str::to_owned).collect();
    validation.set_audience(&[AUDIENCE]);
    validation.set_issuer(&[issuer]);
    validation
}

fn timestamp(seconds: i64) -> Result<DateTime<Utc>, EntitlementError> {
    DateTime::from_timestamp(seconds, 0).ok_or_else(|| EntitlementError::Malformed(format!("time {seconds}")))
}

#[cfg(test)]
pub(crate) mod test_tokens {
    use chrono::{DateTime, TimeDelta, Utc};

    use super::EntitlementClaims;
    use crate::entitlement_keys::EntitlementKeys;
    pub(crate) use crate::fakes::{ISSUER, MACHINE};

    pub(crate) fn keys() -> EntitlementKeys {
        crate::fakes::keys().expect("the RFC 8037 key")
    }

    pub(crate) fn claims(issued: DateTime<Utc>, lasts: TimeDelta, features: &[&str]) -> EntitlementClaims {
        crate::fakes::claims(issued, lasts, features)
    }

    pub(crate) fn sign(claims: &EntitlementClaims) -> String {
        crate::fakes::sign(claims).expect("a signed token")
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeDelta;
    use serde_json::Value;

    use super::test_tokens::{ISSUER, MACHINE, claims, keys, sign};
    use super::*;

    const VECTORS: &str = include_str!("../tests/data/entitlement_vectors.json");

    #[derive(Deserialize)]
    struct Vectors {
        key: VectorKey,
        machine_id: String,
        now: i64,
        valid: Vec<Valid>,
        invalid: Vec<Invalid>,
    }

    #[derive(Deserialize)]
    struct VectorKey {
        kid: String,
        x: String,
    }

    #[derive(Deserialize)]
    struct Valid {
        name: String,
        token: String,
        claims: Value,
    }

    #[derive(Deserialize)]
    struct Invalid {
        name: String,
        check: String,
        token: String,
    }

    fn vectors() -> (Vectors, EntitlementKeys, DateTime<Utc>) {
        let vectors: Vectors = serde_json::from_str(VECTORS).expect("the vectors");
        let keys = EntitlementKeys::from_public_keys([vectors.key.x.as_str()]).expect("the vectors' key");
        assert_eq!(keys.kids().collect::<Vec<_>>(), [vectors.key.kid.as_str()]);
        let now = DateTime::from_timestamp(vectors.now, 0).expect("the vectors' time");
        (vectors, keys, now)
    }

    fn check(error: &EntitlementError) -> &'static str {
        match error {
            EntitlementError::Malformed(_) => "malformed",
            EntitlementError::Algorithm(_) => "alg",
            EntitlementError::Type(_) => "typ",
            EntitlementError::UnknownKey(_) => "kid",
            EntitlementError::Signature => "signature",
            EntitlementError::Audience => "aud",
            EntitlementError::Issuer => "iss",
            EntitlementError::Machine => "mid",
            EntitlementError::NotYetValid(_) => "nbf",
            EntitlementError::Expired(_) => "exp",
        }
    }

    #[test]
    fn every_valid_vector_passes_and_decodes_to_its_claims() {
        let (vectors, keys, now) = vectors();

        for vector in &vectors.valid {
            let entitlement = Entitlement::verify(&vector.token, &keys, ISSUER, &vectors.machine_id, now)
                .unwrap_or_else(|error| panic!("{}: {error}", vector.name));

            let decoded = serde_json::to_value(entitlement.claims()).expect("the claims as JSON");
            assert_eq!(decoded, vector.claims, "{}", vector.name);
            assert_eq!(entitlement.token(), vector.token, "{}", vector.name);
        }
    }

    #[test]
    fn every_invalid_vector_fails_the_check_it_names() {
        let (vectors, keys, now) = vectors();

        for vector in &vectors.invalid {
            let error =
                Entitlement::verify(&vector.token, &keys, ISSUER, &vectors.machine_id, now).expect_err(&vector.name);

            assert_eq!(check(&error), vector.check, "{}: {error}", vector.name);
        }
    }

    #[test]
    fn the_vectors_cover_alg_typ_kid_signature_exp_and_nbf() {
        let (vectors, ..) = vectors();
        let checks: Vec<&str> = vectors.invalid.iter().map(|vector| vector.check.as_str()).collect();

        for named in ["alg", "typ", "kid", "signature", "aud", "mid", "nbf", "exp"] {
            assert!(checks.contains(&named), "{named}");
        }
    }

    #[test]
    fn nbf_may_be_up_to_five_minutes_ahead_and_no_further() {
        let now = Utc::now();
        let ahead = |seconds| sign(&claims(now + TimeDelta::seconds(seconds), TimeDelta::days(14), &[]));

        let inside = Entitlement::verify(&ahead(300), &keys(), ISSUER, MACHINE, now);
        let beyond = Entitlement::verify(&ahead(301), &keys(), ISSUER, MACHINE, now);

        assert!(inside.is_ok(), "{inside:?}");
        assert!(matches!(beyond, Err(EntitlementError::NotYetValid(_))), "{beyond:?}");
    }

    #[test]
    fn exp_has_no_leeway() {
        let issued = DateTime::from_timestamp(Utc::now().timestamp(), 0).expect("now") - TimeDelta::days(1);
        let token = sign(&claims(issued, TimeDelta::days(1), &[]));
        let expires_at = issued + TimeDelta::days(1);

        let before = Entitlement::verify(&token, &keys(), ISSUER, MACHINE, expires_at - TimeDelta::seconds(1));
        let at = Entitlement::verify(&token, &keys(), ISSUER, MACHINE, expires_at);

        assert!(before.is_ok(), "{before:?}");
        assert_eq!(at, Err(EntitlementError::Expired(expires_at)));
    }

    #[test]
    fn an_entitlement_from_another_server_or_with_no_issuer_is_refused() {
        let now = Utc::now();
        let mut elsewhere = claims(now, TimeDelta::days(14), &[]);
        elsewhere.iss = "https://api.example.com".to_owned();

        let refused = Entitlement::verify(&sign(&elsewhere), &keys(), ISSUER, MACHINE, now);
        let taken = Entitlement::verify(&sign(&elsewhere), &keys(), "https://api.example.com", MACHINE, now);

        assert_eq!(refused, Err(EntitlementError::Issuer));
        assert!(taken.is_ok(), "{taken:?}");
    }

    #[test]
    fn a_company_server_s_license_cuts_the_features_and_past_its_grace_keeps_only_the_sync_features() {
        let now = DateTime::from_timestamp(Utc::now().timestamp(), 0).expect("now");
        let origin = "https://api.example.com";
        let mut granted = claims(
            now,
            TimeDelta::days(14),
            &["team_library", "service_sync", "query_insights", "env_var_references"],
        );
        granted.iss = origin.to_owned();
        let license_claims = crate::fakes::license_claims(
            origin,
            now - TimeDelta::days(380),
            TimeDelta::days(365),
            &["team_library", "service_sync", "query_insights"],
        );
        let license = crate::license::License::verify(
            &crate::fakes::sign_license(&license_claims).expect("a license"),
            &crate::license_keys::LicenseKeys::from_public_keys([crate::fakes::PUBLIC_X]).expect("the key"),
            origin,
            now,
        )
        .expect("a license");
        let in_grace = now;
        let past_grace = license.grace_ends_at().expect("a grace end");

        let entitlement = Entitlement::verify(&sign(&granted), &keys(), origin, MACHINE, now)
            .expect("an entitlement")
            .within(Arc::new(license));

        assert!(!entitlement.includes("env_var_references"));
        assert_eq!(
            entitlement.features_at(in_grace),
            ["team_library", "service_sync", "query_insights"]
        );
        assert_eq!(entitlement.features_at(past_grace), ["team_library", "service_sync"]);
    }

    #[test]
    fn a_token_that_is_not_a_jws_is_malformed() {
        for token in ["", "a.b", "a.b.c.d", "!!!.e30.sig", "e30.e30.sig"] {
            let result = Entitlement::verify(token, &keys(), ISSUER, MACHINE, Utc::now());

            assert!(
                matches!(result, Err(EntitlementError::Malformed(_))),
                "{token:?}: {result:?}"
            );
        }
    }

    #[test]
    fn includes_reads_the_feature_codes() {
        let now = Utc::now();
        let token = sign(&claims(now, TimeDelta::days(14), &["env_var_references"]));

        let entitlement = Entitlement::verify(&token, &keys(), ISSUER, MACHINE, now).expect("a valid token");

        assert!(entitlement.includes("env_var_references"));
        assert!(!entitlement.includes("team_library"));
        assert!(entitlement.is_current(now));
        assert!(!entitlement.is_current(entitlement.expires_at()));
    }
}
