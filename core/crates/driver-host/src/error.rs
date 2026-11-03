#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PluginError {
    #[error("{path} carries no signature")]
    Unsigned { path: String },
    #[error("the signature of {path} is not trusted: {detail}")]
    Untrusted { path: String, detail: String },
    #[error("{path} is signed by {subject}, which this app does not trust for drivers")]
    WrongSigner { path: String, subject: String },
    #[error("this platform has no check for a driver's signature yet")]
    TrustUnavailable,
    #[error("{path} could not be loaded: {detail}")]
    LoadFailed { path: String, detail: String },
    #[error("{path} is built for another processor")]
    WrongArchitecture { path: String },
    #[error("{path} is not a TablePro driver: {detail}")]
    NotADriver { path: String, detail: String },
    #[error("driver {id} speaks ABI {major}.x, this app speaks {host}.x")]
    AbiUnsupported { id: String, major: u16, host: u16 },
    #[error("driver {id} was built to abort on a panic, which would end the app")]
    PanicAbort { id: String },
    #[error("driver {id} did not start: {detail}")]
    OpenFailed { id: String, detail: String },
    #[error("the file's checksum is {found}, not the {expected} the catalog lists")]
    ChecksumMismatch { expected: String, found: String },
    #[error("the file holds driver {found} {found_version}, not {expected} {expected_version}")]
    WrongDriver {
        expected: String,
        expected_version: String,
        found: String,
        found_version: String,
    },
    #[error("no release of driver {id} runs on this computer")]
    NoRelease { id: String },
    #[error("the driver catalog could not be read: {detail}")]
    Manifest { detail: String },
    #[error("no driver {id} is installed")]
    NotInstalled { id: String },
    #[error("driver call failed with status {status}: {message}")]
    Call {
        status: i32,
        codes: Vec<String>,
        message: String,
    },
    #[error("{detail}")]
    Io { detail: String },
}

impl PluginError {
    // Stable across releases, for an app outside Rust that words the error itself.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unsigned { .. } => "plugin.unsigned",
            Self::Untrusted { .. } => "plugin.untrusted",
            Self::WrongSigner { .. } => "plugin.wrong_signer",
            Self::TrustUnavailable => "plugin.trust_unavailable",
            Self::LoadFailed { .. } => "plugin.load_failed",
            Self::WrongArchitecture { .. } => "plugin.wrong_architecture",
            Self::NotADriver { .. } => "plugin.not_a_driver",
            Self::AbiUnsupported { .. } => "plugin.abi_unsupported",
            Self::PanicAbort { .. } => "plugin.panic_abort",
            Self::OpenFailed { .. } => "plugin.open_failed",
            Self::ChecksumMismatch { .. } => "plugin.checksum_mismatch",
            Self::WrongDriver { .. } => "plugin.wrong_driver",
            Self::NoRelease { .. } => "plugin.no_release",
            Self::Manifest { .. } => "plugin.manifest_invalid",
            Self::NotInstalled { .. } => "plugin.not_installed",
            Self::Call { .. } => "plugin.call_failed",
            Self::Io { .. } => "plugin.io",
        }
    }

    pub(crate) fn io(what: &str, error: &std::io::Error) -> Self {
        Self::Io {
            detail: format!("{what}: {error}"),
        }
    }
}
