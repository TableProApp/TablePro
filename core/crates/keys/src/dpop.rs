// DPoP proofs (RFC 9449 section 4.2) as ADR 0051 profiles them: a JWS (RFC 7515) signed with the
// device's DSK, `alg` `Ed25519` (RFC 9864) and an OKP `jwk` (RFC 8037). ADR 0056's framing does not apply.

use crate::KeysError;
use crate::b64;
use crate::crypto;
use crate::json::push_string;
use crate::keys::Ed25519Seed;

#[derive(Debug, Clone, Copy)]
pub struct DpopRequest<'a> {
    pub method: &'a str,
    // The request URI; the query and fragment are left out of `htu`.
    pub url: &'a str,
    pub access_token: &'a str,
    // Seconds since the Unix epoch.
    pub iat: u64,
    // The server's `DPoP-Nonce`, once it sent one.
    pub nonce: Option<&'a str>,
}

pub fn htu(url: &str) -> Result<String, KeysError> {
    let mut url = url::Url::parse(url).map_err(|_| KeysError::encoding("DPoP URL"))?;
    url.set_query(None);
    url.set_fragment(None);
    Ok(url.into())
}

pub fn proof(dsk: &Ed25519Seed, request: DpopRequest<'_>) -> Result<String, KeysError> {
    proof_with_jti(dsk, request, crypto::random_array()?)
}

pub fn proof_with_jti(dsk: &Ed25519Seed, request: DpopRequest<'_>, jti: [u8; 16]) -> Result<String, KeysError> {
    let mut header =
        String::from("{\"typ\":\"dpop+jwt\",\"alg\":\"Ed25519\",\"jwk\":{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"x\":");
    push_string(&mut header, &b64::encode(&dsk.public()?.0));
    header.push_str("}}");

    let mut claims = String::from("{\"jti\":");
    push_string(&mut claims, &b64::encode(&jti));
    claims.push_str(",\"htm\":");
    push_string(&mut claims, request.method);
    claims.push_str(",\"htu\":");
    push_string(&mut claims, &htu(request.url)?);
    claims.push_str(&format!(",\"iat\":{},\"ath\":", request.iat));
    push_string(
        &mut claims,
        &b64::encode(&crypto::sha256(request.access_token.as_bytes())),
    );
    if let Some(nonce) = request.nonce {
        claims.push_str(",\"nonce\":");
        push_string(&mut claims, nonce);
    }
    claims.push('}');

    let signing_input = format!("{}.{}", b64::encode(header.as_bytes()), b64::encode(claims.as_bytes()));
    let signature = dsk.sign(signing_input.as_bytes())?;
    Ok(format!("{signing_input}.{}", b64::encode(&signature.0)))
}

#[cfg(test)]
mod tests {
    use super::{DpopRequest, htu, proof_with_jti};
    use crate::b64;
    use crate::json::{Members, parse};
    use crate::keys::{Ed25519Public, Ed25519Seed, Signature};

    #[test]
    fn htu_drops_the_query_and_fragment() {
        assert_eq!(
            htu("https://Sync.Example.com:443/v2/sync/scopes/personal/changes?cursor=x#y").unwrap(),
            "https://sync.example.com/v2/sync/scopes/personal/changes"
        );
    }

    #[test]
    fn a_proof_verifies_under_the_jwk_it_carries() {
        let dsk = Ed25519Seed::from_bytes([1; 32]);
        let request = DpopRequest {
            method: "POST",
            url: "https://sync.example.com/v2/sync/scopes/personal/changes",
            access_token: "token",
            iat: 1_764_000_000,
            nonce: Some("n-1"),
        };
        let proof = proof_with_jti(&dsk, request, [2; 16]).unwrap();
        let parts: Vec<&str> = proof.split('.').collect();
        assert_eq!(parts.len(), 3);
        let header = parse(&b64::decode(parts[0]).unwrap()).unwrap();
        let mut header_members = Members::of(&header).unwrap();
        assert_eq!(header_members.string("alg").unwrap(), "Ed25519");
        assert_eq!(header_members.string("typ").unwrap(), "dpop+jwt");
        let claims = parse(&b64::decode(parts[1]).unwrap()).unwrap();
        let mut claim_members = Members::of(&claims).unwrap();
        assert_eq!(claim_members.string("nonce").unwrap(), "n-1");
        assert_eq!(claim_members.integer("iat").unwrap(), 1_764_000_000);
        let signature = Signature(b64::decode_exact(parts[2]).unwrap());
        let public: Ed25519Public = dsk.public().unwrap();
        assert_eq!(
            public.verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature),
            Ok(())
        );
    }
}
