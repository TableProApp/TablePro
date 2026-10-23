//! The diagram as a PNG or SVG file. Both draw the canvas's render
//! nodes into a cairo surface, so a file shows what the screen shows,
//! whole, at 100%, whatever the zoom and scroll.

use gtk4::gsk;

/// A PNG has twice the pixels of the screen at 100%, so it stays sharp
/// on a high-resolution display or when printed.
const PNG_SCALE: f64 = 2.0;
/// Under cairo's own limit of 32,767 pixels a side.
const MAX_PNG_SIDE: f64 = 16_384.0;
/// About 160 MB of pixels while the file is encoded. A larger diagram's
/// PNG gets fewer pixels; its SVG has no such limit.
const MAX_PNG_PIXELS: f64 = 40_000_000.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ImageFormat {
    Png,
    Svg,
}

impl ImageFormat {
    pub(crate) fn from_name(name: &str) -> Option<Self> {
        match name {
            "png" => Some(Self::Png),
            "svg" => Some(Self::Svg),
            _ => None,
        }
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Svg => "svg",
        }
    }

    pub(crate) fn mime_type(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Svg => "image/svg+xml",
        }
    }

    pub(crate) fn filter_name(self) -> String {
        match self {
            Self::Png => crate::i18n::gettext("PNG images"),
            Self::Svg => crate::i18n::gettext("SVG images"),
        }
    }

    /// The file name the save dialog offers: the schema's, with what a
    /// file name cannot hold taken out.
    pub(crate) fn suggested_name(self, schema: Option<&str>) -> String {
        let base: String = schema
            .unwrap_or_default()
            .chars()
            .map(|c| {
                if c == '/' || c == '\\' || c.is_control() {
                    '_'
                } else {
                    c
                }
            })
            .collect();
        let base = base.trim_matches(|c: char| c == '.' || c.is_whitespace());
        match base.is_empty() {
            true => format!("er-diagram.{}", self.name()),
            false => format!("{base}-er-diagram.{}", self.name()),
        }
    }
}

/// How many pixels a PNG of a `width` by `height` diagram gets per unit.
pub(crate) fn png_scale(width: f64, height: f64) -> f64 {
    if width <= 0.0 || height <= 0.0 {
        return PNG_SCALE;
    }
    PNG_SCALE
        .min(MAX_PNG_SIDE / width)
        .min(MAX_PNG_SIDE / height)
        .min((MAX_PNG_PIXELS / (width * height)).sqrt())
}

/// A drawn PNG's pixels, which the encode takes off the GTK thread.
pub(crate) struct Pixels {
    data: Vec<u8>,
    width: i32,
    height: i32,
    stride: i32,
}

/// The diagram drawn for `format`: a PNG's pixels still to encode, or an
/// SVG document.
pub(crate) enum Drawn {
    Png(Pixels),
    Svg(Vec<u8>),
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum DrawError {
    #[error("there is no diagram to draw")]
    Empty,
    #[error(transparent)]
    Cairo(#[from] cairo::Error),
    #[error("the surface was still in use")]
    Borrow,
    #[error("the SVG stream failed: {0}")]
    Stream(String),
    #[error("the PNG could not be written: {0}")]
    Encode(String),
}

/// Draw `node`, `width` by `height` units, for `format`. Runs on the GTK
/// thread, which the render nodes belong to.
pub(crate) fn draw(node: &gsk::RenderNode, width: f64, height: f64, format: ImageFormat) -> Result<Drawn, DrawError> {
    match format {
        ImageFormat::Png => draw_png(node, width, height).map(Drawn::Png),
        ImageFormat::Svg => draw_svg(node, width, height).map(Drawn::Svg),
    }
}

fn pixels(units: f64, scale: f64) -> i32 {
    (units * scale).ceil().clamp(1.0, MAX_PNG_SIDE) as i32
}

fn draw_png(node: &gsk::RenderNode, width: f64, height: f64) -> Result<Pixels, DrawError> {
    let scale = png_scale(width, height);
    let (pixel_width, pixel_height) = (pixels(width, scale), pixels(height, scale));
    let mut surface = cairo::ImageSurface::create(cairo::Format::ARgb32, pixel_width, pixel_height)?;
    {
        let context = cairo::Context::new(&surface)?;
        context.scale(scale, scale);
        node.draw(&context);
        context.status()?;
    }
    surface.flush();
    let stride = surface.stride();
    let data = surface.data().map_err(|_| DrawError::Borrow)?.to_vec();
    Ok(Pixels {
        data,
        width: pixel_width,
        height: pixel_height,
        stride,
    })
}

fn draw_svg(node: &gsk::RenderNode, width: f64, height: f64) -> Result<Vec<u8>, DrawError> {
    let mut surface = cairo::SvgSurface::for_stream(width, height, Vec::<u8>::new())?;
    surface.set_document_unit(cairo::SvgUnit::Px);
    {
        let context = cairo::Context::new(&surface)?;
        node.draw(&context);
        context.status()?;
    }
    let stream = surface
        .finish_output_stream()
        .map_err(|error| DrawError::Stream(error.error.to_string()))?;
    stream
        .downcast::<Vec<u8>>()
        .map(|bytes| *bytes)
        .map_err(|_| DrawError::Stream("the stream held something else".to_owned()))
}

/// The file's bytes. A PNG is encoded here, which for a large diagram
/// takes long enough that it runs off the GTK thread.
pub(crate) fn encode(drawn: Drawn) -> Result<Vec<u8>, DrawError> {
    let pixels = match drawn {
        Drawn::Svg(bytes) => return Ok(bytes),
        Drawn::Png(pixels) => pixels,
    };
    let surface = cairo::ImageSurface::create_for_data(
        pixels.data,
        cairo::Format::ARgb32,
        pixels.width,
        pixels.height,
        pixels.stride,
    )?;
    let mut bytes = Vec::new();
    surface
        .write_to_png(&mut bytes)
        .map_err(|error| DrawError::Encode(error.to_string()))?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use gtk4::{gdk, graphene};

    use super::*;

    fn square() -> gsk::RenderNode {
        let snapshot = gtk4::Snapshot::new();
        snapshot.append_color(
            &gdk::RGBA::new(0.2, 0.4, 0.6, 1.0),
            &graphene::Rect::new(0.0, 0.0, 30.0, 20.0),
        );
        snapshot.to_node().expect("a node")
    }

    #[test]
    fn a_png_is_twice_the_size_unless_that_is_too_big() {
        assert_eq!(png_scale(1000.0, 800.0), 2.0);
        let big = png_scale(20_000.0, 10_000.0);
        assert!(20_000.0 * big <= MAX_PNG_SIDE + 1.0, "{big}");
        let many = png_scale(6000.0, 6000.0);
        assert!(6000.0 * 6000.0 * many * many <= MAX_PNG_PIXELS * 1.001, "{many}");
    }

    #[test]
    fn the_suggested_name_comes_from_the_schema() {
        assert_eq!(ImageFormat::Png.suggested_name(Some("public")), "public-er-diagram.png");
        assert_eq!(ImageFormat::Svg.suggested_name(None), "er-diagram.svg");
        assert_eq!(ImageFormat::Svg.suggested_name(Some("a/b")), "a_b-er-diagram.svg");
        assert_eq!(ImageFormat::Png.suggested_name(Some("..")), "er-diagram.png");
    }

    #[gtk4::test]
    fn a_png_export_is_a_png_at_twice_the_size() {
        let bytes = encode(draw(&square(), 30.0, 20.0, ImageFormat::Png).expect("drawn")).expect("encoded");

        assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
        let texture = gdk::Texture::from_bytes(&gtk4::glib::Bytes::from(&bytes)).expect("a PNG GTK reads");
        assert_eq!((texture.width(), texture.height()), (60, 40));
    }

    #[gtk4::test]
    fn an_svg_export_is_an_svg_of_the_diagrams_size() {
        let bytes = encode(draw(&square(), 30.0, 20.0, ImageFormat::Svg).expect("drawn")).expect("encoded");

        let text = String::from_utf8(bytes).expect("SVG is text");
        assert!(text.contains("<svg"), "{text}");
        assert!(
            text.contains("width=\"30px\"") || text.contains("width=\"30\""),
            "{text}"
        );
    }
}
