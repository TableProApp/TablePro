use std::fmt::Write;

/// The bytes a line shows, as most hex viewers lay them out.
const PER_LINE: usize = 16;

/// `bytes` as offset, hex and ASCII columns, sixteen bytes a line, up to
/// `limit` bytes: a dump of megabytes would stall the main thread laying
/// it out. Says how many bytes it left out.
pub fn hex_dump(bytes: &[u8], limit: usize) -> String {
    let shown = &bytes[..bytes.len().min(limit)];
    let mut dump = String::with_capacity(shown.len().div_ceil(PER_LINE) * 80);
    for (line, chunk) in shown.chunks(PER_LINE).enumerate() {
        let _ = write!(dump, "{:08x}  ", line * PER_LINE);
        for at in 0..PER_LINE {
            match chunk.get(at) {
                Some(byte) => {
                    let _ = write!(dump, "{byte:02x} ");
                }
                None => dump.push_str("   "),
            }
            // A gap halfway, so the eye finds a byte by its offset.
            if at == PER_LINE / 2 - 1 {
                dump.push(' ');
            }
        }
        dump.push_str(" |");
        dump.extend(chunk.iter().map(|byte| match byte {
            0x20..=0x7e => char::from(*byte),
            _ => '.',
        }));
        dump.push_str("|\n");
    }
    let left = bytes.len() - shown.len();
    if left > 0 {
        dump.push_str(&crate::i18n::ngettext_f(
            "… {count} more byte not shown",
            "… {count} more bytes not shown",
            u32::try_from(left).unwrap_or(u32::MAX),
            &[("count", &left.to_string())],
        ));
        dump.push('\n');
    }
    dump.pop();
    dump
}

/// The most pixels the pane decodes: 64 MB once decoded. A file of a
/// few kilobytes can claim a size far past this and take all memory.
const MAX_PREVIEW_PIXELS: u64 = 16 * 1024 * 1024;

/// Whether `bytes` are an image GTK reads, PNG, JPEG, GIF, WebP or BMP,
/// whose header gives a size within the preview's budget. An image whose
/// size the header does not give is never decoded.
pub fn previewable_image(bytes: &[u8]) -> bool {
    image_size(bytes).is_some_and(|(width, height)| {
        width > 0 && height > 0 && u64::from(width) * u64::from(height) <= MAX_PREVIEW_PIXELS
    })
}

/// The width and height an image's header gives, read without decoding.
fn image_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let be32 = |at: usize| {
        bytes
            .get(at..at + 4)
            .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    };
    let le16 = |at: usize| {
        bytes
            .get(at..at + 2)
            .map(|b| u32::from(u16::from_le_bytes([b[0], b[1]])))
    };
    let le24 = |at: usize| bytes.get(at..at + 3).map(|b| u32::from_le_bytes([b[0], b[1], b[2], 0]));
    let le32 = |at: usize| {
        bytes
            .get(at..at + 4)
            .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    };
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") && bytes.get(12..16) == Some(b"IHDR") {
        return be32(16).zip(be32(20));
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return le16(6).zip(le16(8));
    }
    if bytes.starts_with(b"BM") {
        return match le32(14)? {
            // OS/2's header, with 16-bit sizes.
            12 => le16(18).zip(le16(20)),
            // Windows' headers, and OS/2's second. A bottom-up bitmap
            // stores its height as negative; a negative width is no bitmap.
            40 | 52 | 56 | 64 | 108 | 124 => {
                let (width, height) = le32(18).zip(le32(22))?;
                (width > 0 && height != 0 && height != i32::MIN).then(|| (width.unsigned_abs(), height.unsigned_abs()))
            }
            _ => None,
        };
    }
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        return match bytes.get(12..16)? {
            b"VP8X" => le24(24).zip(le24(27)).map(|(w, h)| (w + 1, h + 1)),
            b"VP8L" => {
                let bits = le32(21)?.cast_unsigned();
                Some(((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1))
            }
            b"VP8 " => le16(26).zip(le16(28)).map(|(w, h)| (w & 0x3fff, h & 0x3fff)),
            _ => None,
        };
    }
    if bytes.starts_with(&[0xff, 0xd8]) {
        return jpeg_size(bytes);
    }
    None
}

/// A JPEG's size, from the first start-of-frame segment, read the way a
/// decoder walks the segments: fill bytes skipped, markers with no length
/// stepped over. Anything else it cannot follow says no size.
fn jpeg_size(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut at = 2;
    loop {
        if *bytes.get(at)? != 0xff {
            return None;
        }
        // Any number of 0xFF may pad before a marker.
        while *bytes.get(at + 1)? == 0xff {
            at += 1;
        }
        let marker = *bytes.get(at + 1)?;
        match marker {
            // TEM, and RST0 to RST7, stand alone.
            0x01 | 0xd0..=0xd7 => {
                at += 2;
                continue;
            }
            // A second start of image, or the scan or the end before any
            // frame: no size a decoder would agree on.
            0x00 | 0xd8 | 0xd9 | 0xda => return None,
            _ => {}
        }
        let length = usize::from(u16::from_be_bytes([*bytes.get(at + 2)?, *bytes.get(at + 3)?]));
        if length < 2 {
            return None;
        }
        // SOF0 to SOF15, but for DHT (C4), JPG (C8) and DAC (CC).
        if (0xc0..=0xcf).contains(&marker) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
            let height = u16::from_be_bytes([*bytes.get(at + 5)?, *bytes.get(at + 6)?]);
            let width = u16::from_be_bytes([*bytes.get(at + 7)?, *bytes.get(at + 8)?]);
            return Some((u32::from(width), u32::from(height)));
        }
        at = at.checked_add(2 + length)?;
    }
}

#[cfg(test)]
mod tests {
    use super::{hex_dump, previewable_image};

    #[test]
    fn a_dump_lays_out_offset_hex_and_ascii() {
        let bytes: Vec<u8> = b"Hello, TablePro!\x00\x01\xff".to_vec();

        assert_eq!(
            hex_dump(&bytes, 1_024),
            "00000000  48 65 6c 6c 6f 2c 20 54  61 62 6c 65 50 72 6f 21  |Hello, TablePro!|\n\
             00000010  00 01 ff                                          |...|"
        );
    }

    #[test]
    fn a_dump_past_its_limit_says_what_it_left_out() {
        let dump = hex_dump(&[0u8; 40], 32);

        assert_eq!(dump.lines().count(), 3);
        assert!(dump.ends_with("… 8 more bytes not shown"), "{dump}");
    }

    #[test]
    fn an_empty_value_dumps_to_nothing() {
        assert_eq!(hex_dump(&[], 1_024), "");
    }

    /// A PNG's signature and header claiming `width` × `height`.
    fn png_claiming(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
        bytes.extend_from_slice(&width.to_be_bytes());
        bytes.extend_from_slice(&height.to_be_bytes());
        bytes
    }

    #[test]
    fn an_image_is_previewed_only_within_its_pixel_budget() {
        assert!(previewable_image(&png_claiming(4_096, 4_096)));
        assert!(
            !previewable_image(&png_claiming(50_000, 50_000)),
            "a decompression bomb"
        );
        assert!(!previewable_image(&png_claiming(0, 10)));
        assert!(previewable_image(b"GIF89a\x40\x00\x20\x00"));
        assert!(previewable_image(&[
            0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x20, 0x00, 0x40,
        ]));
        let mut webp = b"RIFF\x00\x00\x00\x00WEBPVP8X".to_vec();
        webp.extend_from_slice(&[0; 8]);
        webp.extend_from_slice(&[0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
        assert!(!previewable_image(&webp), "a WebP of 16,777,216 pixels a side");
        assert!(!previewable_image(b"RIFF\x00\x00\x00\x00WAVEfmt "));
        assert!(!previewable_image(b"%PDF-1.7"));
        assert!(!previewable_image(&[0xff, 0xd8, 0xff]), "a JPEG with no frame");
        assert!(
            previewable_image(&[
                0xff, 0xd8, 0xff, 0xff, 0xff, 0xe0, 0x00, 0x02, 0xff, 0xd0, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x20,
                0x00, 0x40,
            ]),
            "fill bytes and a standalone marker before the frame"
        );
        assert!(
            !previewable_image(&[
                0xff, 0xd8, 0xff, 0xe0, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x20, 0x00, 0x40
            ]),
            "a segment shorter than its own length field"
        );
        let bitmap = |header: u32, width: i32, height: i32| {
            let mut bytes = b"BM".to_vec();
            bytes.extend_from_slice(&[0; 12]);
            bytes.extend_from_slice(&header.to_le_bytes());
            bytes.extend_from_slice(&width.to_le_bytes());
            bytes.extend_from_slice(&height.to_le_bytes());
            bytes
        };
        assert!(previewable_image(&bitmap(40, 64, -32)), "a top-down bitmap");
        assert!(!previewable_image(&bitmap(40, -64, 32)), "a negative width");
        assert!(!previewable_image(&bitmap(40, 64, i32::MIN)));
        assert!(!previewable_image(&bitmap(64_000, 64, 32)), "an unknown header");
        let mut os2 = b"BM".to_vec();
        os2.extend_from_slice(&[0; 12]);
        os2.extend_from_slice(&12u32.to_le_bytes());
        os2.extend_from_slice(&[0x40, 0x00, 0x20, 0x00]);
        assert!(previewable_image(&os2), "an OS/2 bitmap, 16-bit sizes");
        assert!(!previewable_image(&[]));
    }
}
