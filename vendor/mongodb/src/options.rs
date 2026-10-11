//! Contains all of the types needed to specify options to MongoDB operations.
//!
//! Most of the options structs in this module use the
//! [`typed-builder`](https://crates.io/crates/typed-builder) crate to derive a type-safe builder
//! API on them. For example, to create an instance of
//! [`FindOptions`](struct.FindOptions.html) with only `limit` and `batch_size` set, the builder
//! API can be used as follows:
//!
//! ```rust
//! use mongodb::options::FindOptions;
//!
//! let options = FindOptions::builder()
//!                   .limit(20)
//!                   .batch_size(5)
//!                   .build();
//! ```

#[cfg(feature = "in-use-encryption")]
pub use crate::action::csfle::{DataKeyOptions, EncryptOptions};
#[cfg(any(
    feature = "zstd-compression",
    feature = "zlib-compression",
    feature = "snappy-compression"
))]
pub use crate::compression::compressors::Compressor;
pub use crate::{
    change_stream::options::*,
    client::{
        auth::{oidc, *},
        options::*,
    },
    coll::options::*,
    collation::*,
    concern::*,
    db::options::*,
    gridfs::options::*,
    index::options::*,
    search_index::options::*,
    selection_criteria::*,
};

/// Merges the options from src into dst.
macro_rules! merge_options {
    ($src:expr, $dst:expr, [$( $field:ident ),+] ) => {
        $(
            if let Some(ref option) = $src.$field {
                if !$dst.$field.is_some() {
                    $dst.$field = Some(option.clone());
                }
            }
        )+
    };
}
