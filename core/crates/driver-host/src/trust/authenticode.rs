// WinVerifyTrust checks the signature, the chain and the code-signing purpose, not who signed. The signer's subject
// and its issuer are matched here, read from the same verified state, so they are the certificates that were checked.

use std::fs::File;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::path::Path;

use windows_sys::Win32::Foundation::{
    CERT_E_REVOCATION_FAILURE, CRYPT_E_REVOCATION_OFFLINE, HANDLE, HWND, INVALID_HANDLE_VALUE, TRUST_E_NOSIGNATURE,
    TRUST_E_PROVIDER_UNKNOWN, TRUST_E_SUBJECT_FORM_UNKNOWN,
};
use windows_sys::Win32::Security::Cryptography::{
    CERT_CONTEXT, CERT_NAME_STR_REVERSE_FLAG, CERT_X500_NAME_STR, CertNameToStrW, X509_ASN_ENCODING,
};
use windows_sys::Win32::Security::WinTrust::{
    WINTRUST_ACTION_GENERIC_VERIFY_V2, WINTRUST_DATA, WINTRUST_FILE_INFO, WTD_CACHE_ONLY_URL_RETRIEVAL,
    WTD_CHOICE_FILE, WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT, WTD_REVOKE_NONE, WTD_REVOKE_WHOLECHAIN,
    WTD_STATEACTION_CLOSE, WTD_STATEACTION_VERIFY, WTD_UI_NONE, WTHelperGetProvCertFromChain,
    WTHelperGetProvSignerFromChain, WTHelperProvDataFromStateData, WinVerifyTrust,
};

use sha2::{Digest, Sha256};

use super::{Purpose, Signer};
use crate::error::PluginError;

pub(super) fn verify(file: &File, path: &Path, signers: &[Signer], purpose: Purpose) -> Result<(), PluginError> {
    let found = match signed_by(file, path, purpose) {
        // No answer about revocation offline: the signature and chain still hold, as when a file is loaded.
        Err(Failure::Status(status)) if is_revocation_unknown(status) && purpose == Purpose::Install => {
            tracing::warn!(path = %path.display(), status, "no revocation answer for a driver's certificate");
            signed_by(file, path, Purpose::Load)
        }
        other => other,
    }
    .map_err(|failure| failure.into_error(path))?;
    let trusted = signers.iter().any(|signer| {
        signer.subject == found.subject && signer.issuer_sha256.eq_ignore_ascii_case(&found.issuer_sha256)
    });
    if trusted {
        Ok(())
    } else {
        Err(PluginError::WrongSigner {
            path: path.display().to_string(),
            subject: found.subject,
        })
    }
}

enum Failure {
    Status(i32),
    NoSigner,
}

impl Failure {
    fn into_error(self, path: &Path) -> PluginError {
        let path = path.display().to_string();
        match self {
            Self::Status(TRUST_E_NOSIGNATURE | TRUST_E_SUBJECT_FORM_UNKNOWN | TRUST_E_PROVIDER_UNKNOWN) => {
                PluginError::Unsigned { path }
            }
            Self::Status(status) => PluginError::Untrusted {
                path,
                detail: format!("WinVerifyTrust returned {status:#010x}"),
            },
            Self::NoSigner => PluginError::Untrusted {
                path,
                detail: "the signature names no signer certificate".to_owned(),
            },
        }
    }
}

fn is_revocation_unknown(status: i32) -> bool {
    status == CERT_E_REVOCATION_FAILURE || status == CRYPT_E_REVOCATION_OFFLINE
}

fn signed_by(file: &File, path: &Path, purpose: Purpose) -> Result<Signer, Failure> {
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let mut file_info = WINTRUST_FILE_INFO {
        cbStruct: size_of::<WINTRUST_FILE_INFO>() as u32,
        pcwszFilePath: wide.as_ptr(),
        hFile: file.as_raw_handle() as HANDLE,
        pgKnownSubject: std::ptr::null_mut(),
    };
    let mut data = WINTRUST_DATA {
        cbStruct: size_of::<WINTRUST_DATA>() as u32,
        dwUIChoice: WTD_UI_NONE,
        dwUnionChoice: WTD_CHOICE_FILE,
        dwStateAction: WTD_STATEACTION_VERIFY,
        ..WINTRUST_DATA::default()
    };
    data.Anonymous.pFile = &raw mut file_info;
    match purpose {
        Purpose::Install => {
            data.fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN;
            data.dwProvFlags = WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT;
        }
        Purpose::Load => {
            data.fdwRevocationChecks = WTD_REVOKE_NONE;
            data.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
        }
    }
    let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    // INVALID_HANDLE_VALUE: no interactive user, so WinVerifyTrust never shows UI.
    let no_window = INVALID_HANDLE_VALUE as HWND;
    let status = unsafe { WinVerifyTrust(no_window, &raw mut action, (&raw mut data).cast()) };
    let signer = if status == 0 {
        unsafe { signer_of(data.hWVTStateData) }.ok_or(Failure::NoSigner)
    } else {
        Err(Failure::Status(status))
    };
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    unsafe { WinVerifyTrust(no_window, &raw mut action, (&raw mut data).cast()) };
    signer
}

// The chain runs from the signing certificate up; a self-signed one is its own issuer.
unsafe fn signer_of(state: HANDLE) -> Option<Signer> {
    let provider = unsafe { WTHelperProvDataFromStateData(state) };
    if provider.is_null() {
        return None;
    }
    let chain = unsafe { WTHelperGetProvSignerFromChain(provider, 0, 0, 0) };
    if chain.is_null() {
        return None;
    }
    let leaf = unsafe { WTHelperGetProvCertFromChain(chain, 0).as_ref() }?.pCert;
    let issuer = unsafe { WTHelperGetProvCertFromChain(chain, 1).as_ref() }.map_or(leaf, |issuer| issuer.pCert);
    Some(Signer {
        subject: unsafe { subject_of(leaf) }?,
        issuer_sha256: unsafe { sha256_of(issuer) }?,
    })
}

unsafe fn sha256_of(certificate: *const CERT_CONTEXT) -> Option<String> {
    let certificate = unsafe { certificate.as_ref() }?;
    if certificate.pbCertEncoded.is_null() {
        return None;
    }
    let encoded = unsafe { std::slice::from_raw_parts(certificate.pbCertEncoded, certificate.cbCertEncoded as usize) };
    Some(
        Sha256::digest(encoded)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    )
}

unsafe fn subject_of(certificate: *const CERT_CONTEXT) -> Option<String> {
    let info = unsafe { certificate.as_ref()?.pCertInfo.as_ref() }?;
    let flags = CERT_X500_NAME_STR | CERT_NAME_STR_REVERSE_FLAG;
    let length = unsafe { CertNameToStrW(X509_ASN_ENCODING, &info.Subject, flags, std::ptr::null_mut(), 0) };
    if length <= 1 {
        return None;
    }
    let mut text = vec![0u16; length as usize];
    let written = unsafe { CertNameToStrW(X509_ASN_ENCODING, &info.Subject, flags, text.as_mut_ptr(), length) };
    text.truncate((written as usize).saturating_sub(1));
    Some(String::from_utf16_lossy(&text))
}
