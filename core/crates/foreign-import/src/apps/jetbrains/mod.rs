// What every JetBrains IDE shares: its credential store, the KeePass file it can keep secrets in, the
// path macros in its XML, and how that XML is read.

mod credential_store;
mod inner_stream;
mod kdbx;
mod path_macros;
#[cfg(test)]
pub(crate) mod test_kdbx;
pub(crate) mod xml;

pub(crate) use credential_store::{CredentialStore, Lookup};
pub(crate) use path_macros::expand;
