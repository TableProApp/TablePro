//! Copies from the grids: rendered off the GTK thread, and put on the
//! clipboard as their own type beside plain text.

mod clipboard_copy;
mod clipboard_format;
mod clipboard_payload;
mod clipboard_writer;
mod copy_renderer;

pub(crate) use clipboard_copy::{copy_payload, copy_rows, copy_text};
pub(crate) use clipboard_format::ClipboardFormat;
pub(crate) use clipboard_payload::ClipboardPayload;
pub(crate) use clipboard_writer::ClipboardError;
#[cfg(test)]
use copy_renderer::render;
pub(crate) use copy_renderer::{CopyError, CopyKind, CopyRequest, InClauseRows, InsertCopy, InsertRow, render_copy};

#[cfg(test)]
mod tests;
