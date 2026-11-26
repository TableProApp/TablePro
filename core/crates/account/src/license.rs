use chrono::{DateTime, Utc};
use jsonwebtoken::errors::ErrorKind;
use jsonwebtoken::{Algorithm, Validation};
use serde::{Deserialize, Serialize};

use crate::entitlement::{NOT_BEFORE_LEEWAY, decode_header};
use crate::license_keys::LicenseKeys;

pub const LICENSE_TYPE: &str = "license+jwt";
// Every license file is signed by TablePro, whichever server holds it (core ADR 0044, Licensing).
pub const LICENSE_ISSUER: &str = "https://tablepro.app";
const AUDIENCE: &str = "tablepro-app";
// What a license keeps past its grace, as the server's `LapsedFeature` does (0051, Gates): pulls go on and only key-object
// writes are taken.
pub const KEPT_PAST_GRACE: [&str; 2] = ["service_sync", "team_library"];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LicenseError {
    #[error("the server has no license installed")]
    NotInstalled,
    #[error("the license is not a signed token: {0}")]
    Malformed(String),
    #[error("the license is signed with {0}, not EdDSA")]
    Algorithm(String),
    #[error("the token is not a license (typ {0:?})")]
    Type(Option<String>),
    #[error("the license is signed with a key this build does not have ({0:?})")]
    UnknownKey(Option<String>),
    #[error("the license is signed with a revoked key ({0})")]
    Revoked(String),
    #[error("the license's signature does not verify")]
    Signature,
    #[error("the license is not for TablePro's apps")]
    Audience,
    #[error("the license is not TablePro's")]
    Issuer,
    #[error("the license is for another server ({0})")]
    Origin(String),
    #[error("the license's term does not hold together: {0}")]
    Term(&'static str),
    #[error("the license is not valid before {0}")]
    NotYetValid(DateTime<Utc>),
}

impl LicenseError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotInstalled => "account.license_not_installed",
            Self::Origin(_) => "account.license_other_server",
            Self::NotYetValid(_) => "account.license_not_yet_valid",
            Self::UnknownKey(_) | Self::Revoked(_) => "account.license_untrusted",
            Self::Malformed(_)
            | Self::Algorithm(_)
            | Self::Type(_)
            | Self::Signature
            | Self::Audience
            | Self::Issuer
            | Self::Term(_) => "account.license_invalid",
        }
    }
}

// A license file's claims (core ADRs 0044, 0045 and 0046). It has exactly one of `exp` and `maintenance_until`, and
// `grace_until` with `exp` only. The apps read `exp` and `grace_until`; `maintenance_until` bounds the server's releases.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LicenseClaims {
    pub iss: String,
    pub sub: String,
    pub jti: String,
    pub iat: i64,
    pub nbf: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exp: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maintenance_until: Option<i64>,
    // When pushes stop, which the issuer sets: 7 days after `exp` on a monthly file, 30 on any other.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grace_until: Option<i64>,
    pub license_type: String,
    pub seats: u32,
    pub features: Vec<String>,
    pub origin: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LicenseState {
    Active,
    // Past `exp`, until the grace ends: every feature still works.
    Grace { ends_at: DateTime<Utc> },
    // Past the grace: pulls of the sync features, and key-object writes.
    Lapsed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct License {
    token: String,
    claims: LicenseClaims,
}

impl License {
    // Offline, against the license keys this build ships. A file past its `exp` still verifies: its state says how
    // far past.
    pub fn verify(token: &str, keys: &LicenseKeys, origin: &str, now: DateTime<Utc>) -> Result<Self, LicenseError> {
        let header = decode_header(token).map_err(LicenseError::Malformed)?;
        if header.alg != "EdDSA" {
            return Err(LicenseError::Algorithm(header.alg));
        }
        if header.typ.as_deref() != Some(LICENSE_TYPE) {
            return Err(LicenseError::Type(header.typ));
        }
        if let Some(kid) = header.kid.as_deref().filter(|kid| keys.is_revoked(kid)) {
            return Err(LicenseError::Revoked(kid.to_owned()));
        }
        let key = header
            .kid
            .as_deref()
            .and_then(|kid| keys.get(kid))
            .ok_or_else(|| LicenseError::UnknownKey(header.kid.clone()))?;
        let claims = jsonwebtoken::decode::<LicenseClaims>(token, key, &validation())
            .map_err(|error| match error.kind() {
                ErrorKind::InvalidSignature => LicenseError::Signature,
                ErrorKind::InvalidAudience => LicenseError::Audience,
                ErrorKind::InvalidIssuer => LicenseError::Issuer,
                _ => LicenseError::Malformed(error.to_string()),
            })?
            .claims;
        if claims.origin.trim_end_matches('/') != origin {
            return Err(LicenseError::Origin(claims.origin));
        }
        if claims.seats == 0 {
            return Err(LicenseError::Malformed("a license has at least one seat".to_owned()));
        }
        if claims.exp.is_some() == claims.maintenance_until.is_some() {
            return Err(LicenseError::Term("exactly one of exp and maintenance_until"));
        }
        match (claims.exp, claims.grace_until) {
            (Some(exp), Some(grace_until)) if grace_until > exp => {}
            (None, None) => {}
            _ => return Err(LicenseError::Term("grace_until after exp, and only with it")),
        }
        let not_before = timestamp(claims.nbf)?;
        if not_before > now + NOT_BEFORE_LEEWAY {
            return Err(LicenseError::NotYetValid(not_before));
        }
        for at in [claims.exp, claims.grace_until].into_iter().flatten() {
            timestamp(at)?;
        }
        Ok(Self {
            token: token.to_owned(),
            claims,
        })
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    pub fn claims(&self) -> &LicenseClaims {
        &self.claims
    }

    // None for a perpetual license, which never ends for the apps.
    pub fn expires_at(&self) -> Option<DateTime<Utc>> {
        self.claims.exp.and_then(|exp| DateTime::from_timestamp(exp, 0))
    }

    pub fn grace_ends_at(&self) -> Option<DateTime<Utc>> {
        self.claims.grace_until.and_then(|at| DateTime::from_timestamp(at, 0))
    }

    pub fn state(&self, now: DateTime<Utc>) -> LicenseState {
        match (self.expires_at(), self.grace_ends_at()) {
            (Some(expires_at), _) if now < expires_at => LicenseState::Active,
            (Some(_), Some(ends_at)) if now < ends_at => LicenseState::Grace { ends_at },
            (Some(_), _) => LicenseState::Lapsed,
            (None, _) => LicenseState::Active,
        }
    }

    pub fn includes(&self, feature: &str) -> bool {
        self.claims.features.iter().any(|code| code == feature)
    }

    // Whether the license lets a feature work now: false past the grace, except for the sync features it keeps.
    pub fn allows(&self, feature: &str, now: DateTime<Utc>) -> bool {
        self.includes(feature) && (KEPT_PAST_GRACE.contains(&feature) || self.state(now) != LicenseState::Lapsed)
    }
}

fn validation() -> Validation {
    let mut validation = Validation::new(Algorithm::EdDSA);
    validation.validate_exp = false;
    validation.validate_nbf = false;
    validation.required_spec_claims = ["aud", "iss", "nbf"].into_iter().map(str::to_owned).collect();
    validation.set_audience(&[AUDIENCE]);
    validation.set_issuer(&[LICENSE_ISSUER]);
    validation
}

fn timestamp(seconds: i64) -> Result<DateTime<Utc>, LicenseError> {
    DateTime::from_timestamp(seconds, 0).ok_or_else(|| LicenseError::Malformed(format!("time {seconds}")))
}

#[cfg(test)]
mod tests {
    use chrono::TimeDelta;
    use serde::Deserialize;

    use super::*;
    use crate::fakes;

    const ORIGIN: &str = "https://api.example.com";
    const VECTORS: &str = include_str!("../tests/data/license_vectors.json");

    #[derive(Deserialize)]
    struct Vectors {
        keys: Vec<VectorKey>,
        revoked_kids: Vec<String>,
        origin: String,
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
        claims: serde_json::Value,
        state: String,
    }

    #[derive(Deserialize)]
    struct Invalid {
        name: String,
        check: String,
        token: String,
    }

    // tablepro-cloud's vectors: the RFC 8037 key and one whose kid the verifier refuses.
    fn vectors() -> (Vectors, LicenseKeys, DateTime<Utc>) {
        let vectors: Vectors = serde_json::from_str(VECTORS).expect("the vectors");
        let keys = vectors.revoked_kids.iter().fold(
            LicenseKeys::from_public_keys(vectors.keys.iter().map(|key| key.x.as_str())).expect("the vectors' keys"),
            |keys, kid| keys.revoking(kid),
        );
        for key in &vectors.keys {
            assert!(keys.get(&key.kid).is_some(), "{}", key.kid);
        }
        let now = DateTime::from_timestamp(vectors.now, 0).expect("the vectors' time");
        (vectors, keys, now)
    }

    fn check(error: &LicenseError) -> &'static str {
        match error {
            LicenseError::NotInstalled => "installed",
            LicenseError::Malformed(_) => "claims",
            LicenseError::Algorithm(_) => "alg",
            LicenseError::Type(_) => "typ",
            LicenseError::UnknownKey(_) => "kid",
            LicenseError::Revoked(_) => "revoked",
            LicenseError::Signature => "signature",
            LicenseError::Audience => "aud",
            LicenseError::Issuer => "iss",
            LicenseError::Origin(_) => "origin",
            LicenseError::Term(_) => "term",
            LicenseError::NotYetValid(_) => "nbf",
        }
    }

    fn state(state: LicenseState) -> &'static str {
        match state {
            LicenseState::Active => "active",
            LicenseState::Grace { .. } => "grace",
            LicenseState::Lapsed => "lapsed",
        }
    }

    #[test]
    fn every_valid_vector_passes_decodes_to_its_claims_and_is_in_its_state() {
        let (vectors, keys, now) = vectors();

        for vector in &vectors.valid {
            let license = License::verify(&vector.token, &keys, &vectors.origin, now)
                .unwrap_or_else(|error| panic!("{}: {error}", vector.name));

            let mut expected = vector.claims.clone();
            if let serde_json::Value::Object(claims) = &mut expected {
                claims.remove("aud");
            }
            assert_eq!(
                serde_json::to_value(license.claims()).expect("the claims"),
                expected,
                "{}",
                vector.name
            );
            assert_eq!(state(license.state(now)), vector.state, "{}", vector.name);
        }
    }

    #[test]
    fn every_invalid_vector_fails_the_check_it_names() {
        let (vectors, keys, now) = vectors();

        for vector in &vectors.invalid {
            let error = License::verify(&vector.token, &keys, &vectors.origin, now).expect_err(&vector.name);

            assert_eq!(check(&error), vector.check, "{}: {error}", vector.name);
        }
    }

    #[test]
    fn the_vectors_cover_every_check() {
        let (vectors, ..) = vectors();
        let checks: Vec<&str> = vectors.invalid.iter().map(|vector| vector.check.as_str()).collect();

        for named in [
            "alg",
            "typ",
            "revoked",
            "kid",
            "signature",
            "iss",
            "aud",
            "origin",
            "claims",
            "term",
            "nbf",
        ] {
            assert!(checks.contains(&named), "{named}");
        }
    }

    fn keys() -> LicenseKeys {
        LicenseKeys::from_public_keys([fakes::PUBLIC_X]).expect("the RFC 8037 key")
    }

    fn verify(claims: &LicenseClaims, now: DateTime<Utc>) -> Result<License, LicenseError> {
        License::verify(&fakes::sign_license(claims).expect("a token"), &keys(), ORIGIN, now)
    }

    #[test]
    fn a_license_verifies_for_its_origin_and_no_other() {
        let now = Utc::now();
        let claims = fakes::license_claims(ORIGIN, now, TimeDelta::days(365), &["team_library"]);

        let held = verify(&claims, now).expect("a license");
        let elsewhere = License::verify(held.token(), &keys(), "https://api.other.example", now);

        assert_eq!(held.state(now), LicenseState::Active);
        assert_eq!(elsewhere, Err(LicenseError::Origin(ORIGIN.to_owned())));
    }

    #[test]
    fn grace_lasts_until_the_file_s_grace_until_30_days_after_exp_or_7_on_a_monthly_file() {
        let issued = DateTime::from_timestamp(Utc::now().timestamp(), 0).expect("now");
        let yearly = verify(
            &fakes::license_claims(
                ORIGIN,
                issued,
                TimeDelta::days(365),
                &["team_library", "service_sync", "query_insights"],
            ),
            issued,
        )
        .expect("a license");
        let mut monthly_claims = fakes::license_claims(ORIGIN, issued, TimeDelta::days(30), &["team_library"]);
        monthly_claims.grace_until = monthly_claims.exp.map(|exp| exp + TimeDelta::days(7).num_seconds());
        let monthly = verify(&monthly_claims, issued).expect("a license");
        let exp = yearly.expires_at().expect("an exp");
        let monthly_exp = monthly.expires_at().expect("an exp");

        assert_eq!(yearly.state(exp - TimeDelta::seconds(1)), LicenseState::Active);
        assert_eq!(
            yearly.state(exp),
            LicenseState::Grace {
                ends_at: exp + TimeDelta::days(30)
            }
        );
        assert!(matches!(
            yearly.state(exp + TimeDelta::days(30) - TimeDelta::seconds(1)),
            LicenseState::Grace { .. }
        ));
        assert_eq!(yearly.state(exp + TimeDelta::days(30)), LicenseState::Lapsed);
        assert_eq!(monthly.state(monthly_exp + TimeDelta::days(7)), LicenseState::Lapsed);
        assert!(matches!(
            monthly.state(monthly_exp + TimeDelta::days(6)),
            LicenseState::Grace { .. }
        ));
        let lapsed = exp + TimeDelta::days(31);
        assert!(yearly.allows("team_library", lapsed));
        assert!(yearly.allows("service_sync", lapsed));
        assert!(!yearly.allows("query_insights", lapsed));
        assert!(yearly.allows("query_insights", exp + TimeDelta::days(29)));
        assert!(!yearly.allows("env_var_references", issued));
    }

    #[test]
    fn a_perpetual_license_has_no_end_for_the_apps_and_a_file_with_ends_that_disagree_is_refused() {
        let now = Utc::now();
        let mut perpetual = fakes::license_claims(ORIGIN, now, TimeDelta::days(365), &["team_library"]);
        perpetual.maintenance_until = perpetual.exp.take();
        perpetual.grace_until = None;
        let mut both = perpetual.clone();
        both.exp = both.maintenance_until;
        let mut neither = perpetual.clone();
        neither.maintenance_until = None;
        let mut graceless = fakes::license_claims(ORIGIN, now, TimeDelta::days(365), &[]);
        graceless.grace_until = None;
        let mut grace_first = fakes::license_claims(ORIGIN, now, TimeDelta::days(365), &[]);
        grace_first.grace_until = grace_first.exp;
        let mut perpetual_grace = perpetual.clone();
        perpetual_grace.grace_until = perpetual.maintenance_until;

        let held = verify(&perpetual, now).expect("a perpetual license");

        assert_eq!((held.expires_at(), held.grace_ends_at()), (None, None));
        assert_eq!(held.state(now + TimeDelta::days(3650)), LicenseState::Active);
        for refused in [both, neither, graceless, grace_first, perpetual_grace] {
            assert!(
                matches!(verify(&refused, now), Err(LicenseError::Term(_))),
                "{refused:?}"
            );
        }
    }

    #[test]
    fn the_issuer_type_key_and_time_are_checked() {
        let now = Utc::now();
        let claims = fakes::license_claims(ORIGIN, now, TimeDelta::days(365), &["team_library"]);
        let mut other_issuer = claims.clone();
        other_issuer.iss = "https://api.example.com".to_owned();
        let ahead = fakes::license_claims(ORIGIN, now + TimeDelta::seconds(301), TimeDelta::days(365), &[]);
        let as_entitlement = fakes::sign(&fakes::claims(now, TimeDelta::days(1), &[])).expect("a token");

        let revoked = License::verify(
            &fakes::sign_license(&claims).expect("a token"),
            &keys().revoking(fakes::KID),
            ORIGIN,
            now,
        );
        let unknown = License::verify(
            &fakes::sign_license(&claims).expect("a token"),
            &LicenseKeys::release(),
            ORIGIN,
            now,
        );

        assert_eq!(verify(&other_issuer, now), Err(LicenseError::Issuer));
        assert!(matches!(verify(&ahead, now), Err(LicenseError::NotYetValid(_))));
        assert!(matches!(
            License::verify(&as_entitlement, &keys(), ORIGIN, now),
            Err(LicenseError::Type(_))
        ));
        assert_eq!(revoked, Err(LicenseError::Revoked(fakes::KID.to_owned())));
        assert!(matches!(unknown, Err(LicenseError::UnknownKey(_))));
        assert_eq!(revoked.unwrap_err().code(), "account.license_untrusted");
    }
}
