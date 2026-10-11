use crate::error::{ErrorKind, Result};

pub(crate) fn decrypt_private_key(pem_data: &[u8], password: &[u8]) -> Result<Vec<u8>> {
    let pems = pem::parse_many(pem_data).map_err(|error| ErrorKind::InvalidTlsConfig {
        message: format!("Could not parse pemfile: {error}"),
    })?;
    let mut iter = pems
        .into_iter()
        .filter(|pem| pem.tag() == "ENCRYPTED PRIVATE KEY");
    let encrypted_bytes = match iter.next() {
        Some(pem) => pem.into_contents(),
        None => {
            return Err(ErrorKind::InvalidTlsConfig {
                message: "No encrypted private keys found".into(),
            }
            .into())
        }
    };
    let encrypted_key = pkcs8::EncryptedPrivateKeyInfo::<pkcs8::der::asn1::OctetString>::try_from(
        encrypted_bytes.as_slice(),
    )
    .map_err(|error| ErrorKind::InvalidTlsConfig {
        message: format!("Invalid encrypted private key: {error}"),
    })?;
    let decrypted_key =
        encrypted_key
            .decrypt(password)
            .map_err(|error| ErrorKind::InvalidTlsConfig {
                message: format!("Failed to decrypt private key: {error}"),
            })?;
    Ok(decrypted_key.as_bytes().to_vec())
}
