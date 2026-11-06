use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use chrono::{DateTime, TimeDelta, Utc};
use jsonwebtoken::{Algorithm, EncodingKey, Header};

use crate::entitlement::{AccountClaim, Entitlement, EntitlementClaims, TOKEN_TYPE};
use crate::entitlement_keys::{EntitlementKeys, KeyError};

// RFC 8037 appendix A.1, the key tablepro-cloud's vectors use.
const PRIVATE_PKCS8: &str = "MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g";
pub const PUBLIC_X: &str = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo";
pub const KID: &str = "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k";
pub const MACHINE: &str = "e4338b8603de2523305fdfcb87319be2033974658ad97f0c975834d209715658";

pub fn keys() -> Result<EntitlementKeys, KeyError> {
    EntitlementKeys::from_public_keys([PUBLIC_X])
}

pub fn claims(issued: DateTime<Utc>, lasts: TimeDelta, features: &[&str]) -> EntitlementClaims {
    EntitlementClaims {
        iss: "https://api.tablepro.app".to_owned(),
        aud: "tablepro-app".to_owned(),
        sub: "acct_01k8d6wk00f8xsr79e7x052rkk".to_owned(),
        jti: "019a1a6e-9e50-7f80-8162-000000000009".to_owned(),
        iat: issued.timestamp(),
        nbf: issued.timestamp(),
        exp: (issued + lasts).timestamp(),
        dev: "dev_01k8d6wpggfd68tbhz818p4ww4".to_owned(),
        mid: MACHINE.to_owned(),
        features: features.iter().map(|code| (*code).to_owned()).collect(),
        licenses: Vec::new(),
        account: AccountClaim {
            email: "dat@example.com".to_owned(),
            name: "Dat".to_owned(),
        },
        offline: false,
    }
}

pub fn sign(claims: &EntitlementClaims) -> Result<String, String> {
    let mut header = Header::new(Algorithm::EdDSA);
    header.typ = Some(TOKEN_TYPE.to_owned());
    header.kid = Some(KID.to_owned());
    let der = STANDARD.decode(PRIVATE_PKCS8).map_err(|error| error.to_string())?;
    jsonwebtoken::encode(&header, claims, &EncodingKey::from_ed_der(&der)).map_err(|error| error.to_string())
}

// Verified at `iat`, so a token that has expired since still makes one.
pub fn entitlement(claims: &EntitlementClaims) -> Result<Entitlement, String> {
    let keys = keys().map_err(|error| error.to_string())?;
    let issued = DateTime::from_timestamp(claims.iat, 0).ok_or("iat is out of range")?;
    Entitlement::verify(&sign(claims)?, &keys, &claims.mid, issued).map_err(|error| error.to_string())
}
