//! Copies from the grids: rendered off the GTK thread by the core, and put
//! on the clipboard as their own type beside plain text.

mod clipboard_copy;
mod clipboard_writer;
mod copy_renderer;

use crate::services::grid::RowSnapshot;

pub(crate) use clipboard_copy::{copy_payload, copy_rows, copy_text, put_text};
pub(crate) use clipboard_writer::ClipboardError;
pub(crate) use copy_renderer::render_copy;
pub(crate) use tablepro_core::grid::clipboard::{CELLS_MIME_TYPE, ClipboardFormat, ClipboardPayload};
#[cfg(test)]
use tablepro_core::grid::copy::render;
pub(crate) use tablepro_core::grid::copy::{CopyError, CopyKind};

/// The grid's copy requests, over the app's row snapshots.
pub(crate) type CopyRequest = tablepro_core::grid::copy::CopyRequest<RowSnapshot>;
pub(crate) type InsertCopy = tablepro_core::grid::copy::InsertCopy<RowSnapshot>;
pub(crate) type InClauseRows = tablepro_core::grid::copy::InClauseRows<RowSnapshot>;
pub(crate) type InsertRow = tablepro_core::grid::copy::InsertRow<RowSnapshot>;

#[cfg(test)]
mod tests;
