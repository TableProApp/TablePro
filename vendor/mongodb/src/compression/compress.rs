use crate::{
    error::{ErrorKind, Result},
    options::Compressor,
};

impl Compressor {
    pub(crate) fn compress(&self, flag_bytes: &[u8], section_bytes: &[u8]) -> Result<Vec<u8>> {
        let result = match *self {
            #[cfg(feature = "zstd-compression")]
            Self::Zstd { level } => compress_zstd(level, flag_bytes, section_bytes),
            #[cfg(feature = "zlib-compression")]
            Self::Zlib { level } => compress_zlib(level, flag_bytes, section_bytes),
            #[cfg(feature = "snappy-compression")]
            Self::Snappy => compress_snappy(flag_bytes, section_bytes),
        };

        result.map_err(|error| {
            ErrorKind::Internal {
                message: format!(
                    "Failed to compress message with {} compression: {}",
                    self.name(),
                    error
                ),
            }
            .into()
        })
    }
}

#[cfg(feature = "zstd-compression")]
fn compress_zstd(
    level: Option<i32>,
    flag_bytes: &[u8],
    section_bytes: &[u8],
) -> std::io::Result<Vec<u8>> {
    use std::io::Write;

    use zstd::{Encoder, DEFAULT_COMPRESSION_LEVEL};

    let level = level.unwrap_or(DEFAULT_COMPRESSION_LEVEL);
    let mut encoder = Encoder::new(Vec::new(), level)?;

    encoder.write_all(flag_bytes)?;
    encoder.write_all(section_bytes)?;

    encoder.finish()
}

#[cfg(feature = "zlib-compression")]
fn compress_zlib(
    level: Option<u32>,
    flag_bytes: &[u8],
    section_bytes: &[u8],
) -> std::io::Result<Vec<u8>> {
    use std::io::Write;

    use flate2::{write::ZlibEncoder, Compression};

    let level = match level {
        Some(level) => Compression::new(level),
        None => Compression::default(),
    };
    let mut encoder = ZlibEncoder::new(Vec::new(), level);

    encoder.write_all(flag_bytes)?;
    encoder.write_all(section_bytes)?;

    encoder.finish()
}

#[cfg(feature = "snappy-compression")]
fn compress_snappy(flag_bytes: &[u8], section_bytes: &[u8]) -> std::io::Result<Vec<u8>> {
    use snap::raw::Encoder;

    let mut uncompressed = flag_bytes.to_vec();
    uncompressed.extend_from_slice(section_bytes);

    let mut encoder = Encoder::new();
    Ok(encoder.compress_vec(&uncompressed)?)
}
