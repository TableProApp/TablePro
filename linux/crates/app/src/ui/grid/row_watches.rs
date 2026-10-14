use std::cell::RefCell;
use std::collections::HashMap;

use gtk4::glib;
use gtk4::prelude::*;

use super::RowObject;

struct RowWatch {
    row: RowObject,
    handler: glib::SignalHandlerId,
}

/// The rows a factory's bound items show. An item is redrawn each time
/// its row's revision moves, until it is unbound.
pub(super) struct RowWatches<W> {
    watches: RefCell<HashMap<W, RowWatch>>,
}

impl<W> Default for RowWatches<W> {
    fn default() -> Self {
        Self {
            watches: RefCell::default(),
        }
    }
}

impl<W> RowWatches<W>
where
    W: IsA<glib::Object>,
{
    /// Show `row` on `item` now and after each of the row's changes.
    pub fn bind(&self, item: &W, row: RowObject, show: impl Fn(&W, &RowObject) + 'static) {
        show(item, &row);
        // The row outlives the item it is bound to, so the handler holds
        // the item weakly.
        let weak = item.downgrade();
        let handler = row.connect_revision_notify(move |row| {
            if let Some(item) = weak.upgrade() {
                show(&item, row);
            }
        });
        if let Some(stale) = self
            .watches
            .borrow_mut()
            .insert(item.clone(), RowWatch { row, handler })
        {
            stale.row.disconnect(stale.handler);
        }
    }

    pub fn unbind(&self, item: &W) {
        // `W` also borrows as a plain object, so the key type is named.
        if let Some(watch) = self.watches.borrow_mut().remove::<W>(item) {
            watch.row.disconnect(watch.handler);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use gtk4 as gtk;

    use super::RowWatches;
    use crate::ui::grid::RowObject;

    #[gtk4::test]
    fn an_item_follows_only_the_row_it_is_bound_to() {
        let watches = RowWatches::default();
        let item = gtk::Label::new(None);
        let (first, second) = (RowObject::draft(1), RowObject::draft(2));
        let shown = Rc::new(RefCell::new(Vec::new()));
        let record = || {
            let shown = shown.clone();
            move |_: &gtk::Label, row: &RowObject| shown.borrow_mut().push(row.draft_id())
        };

        watches.bind(&item, first.clone(), record());
        watches.bind(&item, second.clone(), record());
        first.bump_revision();
        second.bump_revision();
        watches.unbind(&item);
        second.bump_revision();

        assert_eq!(*shown.borrow(), [Some(1), Some(2), Some(2)]);
    }
}
