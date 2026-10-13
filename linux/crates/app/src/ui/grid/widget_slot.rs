use gtk4 as gtk;
use gtk4::prelude::*;

use super::inline_edit::EditSnapshot;

pub(super) struct WidgetSlot<T: 'static> {
    key: &'static str,
    _phantom: std::marker::PhantomData<T>,
}

impl<T: 'static> WidgetSlot<T> {
    const fn new(key: &'static str) -> Self {
        Self {
            key,
            _phantom: std::marker::PhantomData,
        }
    }

    pub(super) fn set(&self, widget: &impl IsA<gtk::Widget>, value: T) {
        unsafe { widget.set_data(self.key, value) };
    }

    pub(super) fn take(&self, widget: &impl IsA<gtk::Widget>) -> Option<T> {
        unsafe { widget.steal_data::<T>(self.key) }
    }
}

impl<T: 'static + Copy> WidgetSlot<T> {
    pub(super) fn get(&self, widget: &impl IsA<gtk::Widget>) -> Option<T> {
        unsafe { widget.data::<T>(self.key).map(|p| *p.as_ref()) }
    }
}

pub(super) const POSITION_SLOT: WidgetSlot<u32> = WidgetSlot::new("tp-position");
pub(super) const SNAPSHOT_SLOT: WidgetSlot<EditSnapshot> = WidgetSlot::new("tp-snapshot");
pub(super) const COLUMN_SLOT: WidgetSlot<usize> = WidgetSlot::new("tp-column");
/// Set while the bind drives a check button, which would otherwise echo
/// back as a CellEdited of the value it just drew.
pub(super) const SUPPRESS_SLOT: WidgetSlot<bool> = WidgetSlot::new("tp-suppress-toggle");
/// The cell's open editor popover. Unbind pops it down, or the recycled
/// cell is finalized with a GtkPopover child still in it.
pub(super) const POPOVER_SLOT: WidgetSlot<gtk::Popover> = WidgetSlot::new("tp-popover");
/// Set while an IME composition is in flight: focus moving to the IME
/// popover ends the edit, and committing then would send the text from
/// before the composition.
pub(super) const PREEDIT_SLOT: WidgetSlot<bool> = WidgetSlot::new("tp-preedit-active");
