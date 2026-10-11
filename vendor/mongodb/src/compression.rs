#[cfg(any(
    feature = "zstd-compression",
    feature = "zlib-compression",
    feature = "snappy-compression"
))]
pub(crate) mod compress;
#[cfg(any(
    feature = "zstd-compression",
    feature = "zlib-compression",
    feature = "snappy-compression"
))]
pub(crate) mod compressors;
pub(crate) mod decompress;

const NOOP_COMPRESSOR_ID: u8 = 0;
#[cfg(feature = "snappy-compression")]
const SNAPPY_COMPRESSOR_ID: u8 = 1;
#[cfg(feature = "zlib-compression")]
const ZLIB_COMPRESSOR_ID: u8 = 2;
#[cfg(feature = "zstd-compression")]
const ZSTD_COMPRESSOR_ID: u8 = 3;
