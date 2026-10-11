use crate::error::{ErrorKind, Result};

/// Decompresses the given message with the decompression algorithm indicated by the given
/// ID. Returns an error if decompression fails or if the ID is unsupported.
pub(crate) fn decompress_message(message: &[u8], compressor_id: u8) -> Result<Vec<u8>> {
    if compressor_id == super::NOOP_COMPRESSOR_ID {
        return Ok(message.into());
    }

    #[cfg(feature = "zstd-compression")]
    if compressor_id == super::ZSTD_COMPRESSOR_ID {
        return decompress_zstd(message);
    }

    #[cfg(feature = "zlib-compression")]
    if compressor_id == super::ZLIB_COMPRESSOR_ID {
        return decompress_zlib(message);
    }

    #[cfg(feature = "snappy-compression")]
    if compressor_id == super::SNAPPY_COMPRESSOR_ID {
        return decompress_snappy(message);
    }

    Err(ErrorKind::InvalidResponse {
        message: format!("Unsupported compressor ID returned from the server: {compressor_id}"),
    }
    .into())
}

#[cfg(feature = "zstd-compression")]
fn decompress_zstd(message: &[u8]) -> Result<Vec<u8>> {
    let mut decompressed = Vec::new();
    zstd::stream::copy_decode(message, &mut decompressed).map_err(|error| ErrorKind::Internal {
        message: format!("Could not decompress message with zstd: {error}"),
    })?;
    Ok(decompressed)
}

#[cfg(feature = "zlib-compression")]
fn decompress_zlib(message: &[u8]) -> Result<Vec<u8>> {
    use std::io::Write;

    use flate2::write::ZlibDecoder;

    let mut decoder = ZlibDecoder::new(Vec::new());
    decoder.write_all(message)?;
    decoder.finish().map_err(|error| {
        ErrorKind::Internal {
            message: format!("Could not decompress message with zlib: {error}"),
        }
        .into()
    })
}

#[cfg(feature = "snappy-compression")]
fn decompress_snappy(message: &[u8]) -> Result<Vec<u8>> {
    use snap::raw::Decoder;

    let mut decoder = Decoder::new();
    decoder.decompress_vec(message).map_err(|error| {
        ErrorKind::Internal {
            message: format!("Could not decompress message with snappy: {error}"),
        }
        .into()
    })
}
