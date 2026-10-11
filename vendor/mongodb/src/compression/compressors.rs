use serde::Serialize;
use std::str::FromStr;

use crate::error::{Error, ErrorKind, Result};

/// The compressors that may be used to compress messages sent to and decompress messages returned
/// from the server. Note that each variant requires enabling a corresponding feature flag.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[non_exhaustive]
pub enum Compressor {
    /// `zstd` compression. See [the `zstd` manual](http://facebook.github.io/zstd/zstd_manual.html)
    /// for more information.
    #[cfg(feature = "zstd-compression")]
    Zstd {
        /// The compression level to use. It is an error to specify a value outside of the
        /// supported compression levels returned by [zstd::compression_level_range]. If no value
        /// is specified, the default value ([zstd::DEFAULT_COMPRESSION_LEVEL]) will be used.
        /// Higher levels correlate to smaller compression but slower performance.
        level: Option<i32>,
    },
    /// `zlib` compression. See [the `zlib` documentation](https://zlib.net/) for more information.
    #[cfg(feature = "zlib-compression")]
    Zlib {
        /// The compression level to use. If no value is specified, the default value
        /// ([flate2::Compression::default]) will be used. Higher levels correlate to smaller
        /// compression but slower performance.
        level: Option<u32>,
    },
    /// `snappy` compression. See [the `snappy` documentation](http://google.github.io/snappy/)
    /// for more information.
    #[cfg(feature = "snappy-compression")]
    Snappy,
}

impl Compressor {
    pub(crate) fn name(&self) -> &'static str {
        match *self {
            #[cfg(feature = "zstd-compression")]
            Compressor::Zstd { .. } => "zstd",
            #[cfg(feature = "zlib-compression")]
            Compressor::Zlib { .. } => "zlib",
            #[cfg(feature = "snappy-compression")]
            Compressor::Snappy => "snappy",
        }
    }

    pub(crate) fn id(&self) -> u8 {
        match self {
            #[cfg(feature = "zstd-compression")]
            Self::Zstd { .. } => super::ZSTD_COMPRESSOR_ID,
            #[cfg(feature = "zlib-compression")]
            Self::Zlib { .. } => super::ZLIB_COMPRESSOR_ID,
            #[cfg(feature = "snappy-compression")]
            Self::Snappy => super::SNAPPY_COMPRESSOR_ID,
        }
    }

    pub(crate) fn validate(&self) -> Result<()> {
        #[cfg(feature = "zstd-compression")]
        if let Self::Zstd { level: Some(level) } = self {
            let valid_levels = zstd::compression_level_range();
            if !valid_levels.contains(level) {
                return Err(ErrorKind::InvalidArgument {
                    message: format!(
                        "Invalid zstd compression level {level}: compression level must be within \
                         the range {valid_levels:?}"
                    ),
                }
                .into());
            }
        }

        #[cfg(feature = "zlib-compression")]
        if let Self::Zlib { level: Some(level) } = self {
            if *level > 9 {
                return Err(ErrorKind::InvalidArgument {
                    message: format!(
                        "Invalid zlib compression level {level}: compression level must be \
                         between 0 and 9 (inclusive)"
                    ),
                }
                .into());
            }
        }

        Ok(())
    }

    #[cfg(feature = "zlib-compression")]
    pub(crate) fn write_zlib_level(&mut self, uri_level: i32) -> Result<()> {
        // This pattern is irrefutable when only zlib-compression is enabled.
        #[allow(irrefutable_let_patterns)]
        if let Compressor::Zlib { ref mut level } = *self {
            if uri_level == -1 {
                *level = None;
            } else {
                let zlib_compression_level =
                    u32::try_from(uri_level).map_err(|_| ErrorKind::InvalidArgument {
                        message: format!(
                            "Invalid zlib compression level specified: {uri_level}\nzlib \
                             compression level must be a nonnegative integer or -1 to use the \
                             default compression level"
                        ),
                    })?;
                *level = Some(zlib_compression_level);
            }
        }
        Ok(())
    }
}

impl FromStr for Compressor {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self> {
        match s.to_lowercase().as_str() {
            #[cfg(feature = "zstd-compression")]
            "zstd" => Ok(Self::Zstd { level: None }),
            #[cfg(feature = "zlib-compression")]
            "zlib" => Ok(Self::Zlib { level: None }),
            #[cfg(feature = "snappy-compression")]
            "snappy" => Ok(Self::Snappy),
            other if other == "zstd" || other == "zlib" || other == "snappy" => {
                Err(ErrorKind::InvalidArgument {
                    message: format!(
                        "Enable the {other}-compression feature flag to use {other} compression"
                    ),
                }
                .into())
            }
            other => Err(ErrorKind::InvalidArgument {
                message: format!("Unsupported compressor: {other}"),
            }
            .into()),
        }
    }
}
