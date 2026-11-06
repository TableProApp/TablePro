use std::io::Write as _;

use flate2::Compression;
use flate2::write::GzEncoder;

/// A file's bytes gzipped as they arrive, so a `.sql.gz` is written as it
/// is made, never held whole.
pub struct GzipChunks {
    encoder: GzEncoder<Vec<u8>>,
}

impl Default for GzipChunks {
    fn default() -> Self {
        Self::new()
    }
}

impl GzipChunks {
    pub fn new() -> Self {
        Self {
            encoder: GzEncoder::new(Vec::new(), Compression::default()),
        }
    }

    /// The compressed bytes `bytes` made so far, which may be none.
    pub fn compress(&mut self, bytes: &[u8]) -> std::io::Result<Vec<u8>> {
        self.encoder.write_all(bytes)?;
        Ok(std::mem::take(self.encoder.get_mut()))
    }

    /// The rest of the stream and its trailer.
    pub fn finish(self) -> std::io::Result<Vec<u8>> {
        self.encoder.finish()
    }
}

#[cfg(test)]
mod tests {
    use std::io::Read as _;

    use flate2::read::MultiGzDecoder;

    use super::*;

    #[test]
    fn the_chunks_together_are_one_gzip_stream_of_the_input() {
        let mut gzip = GzipChunks::new();
        let mut file = Vec::new();
        let mut expected = Vec::new();
        for part in 0..200 {
            let text = format!("INSERT INTO t VALUES ({part});\n");
            expected.extend_from_slice(text.as_bytes());
            file.extend(gzip.compress(text.as_bytes()).expect("compress"));
        }
        file.extend(gzip.finish().expect("finish"));

        let mut read = String::new();
        MultiGzDecoder::new(file.as_slice())
            .read_to_string(&mut read)
            .expect("a gzip stream");
        assert_eq!(read.as_bytes(), expected.as_slice());
    }
}
