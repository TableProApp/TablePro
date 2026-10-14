use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use tablepro_storage::query_history::StatusFilter;
use uuid::Uuid;

use super::connection_filter::ConnectionFilterModel;
use super::history_filter_state::{HistoryFilterState, TimeWindow};
use crate::i18n::gettext;

const STATUSES: [(&str, StatusFilter); 4] = [
    ("any", StatusFilter::Any),
    ("succeeded", StatusFilter::Succeeded),
    ("failed", StatusFilter::Failed),
    ("cancelled", StatusFilter::Cancelled),
];

/// The filters under the search bar, in a box that wraps them onto more
/// lines when the dialog is narrow.
pub(crate) struct HistoryFilters {
    root: adw::WrapBox,
    connection: gtk::DropDown,
    status: adw::ToggleGroup,
    window: gtk::DropDown,
    connections: ConnectionFilterModel,
}

impl HistoryFilters {
    pub(crate) fn new(connections: &ConnectionFilterModel) -> Self {
        let connection = gtk::DropDown::new(Some(connections.labels().clone()), None::<gtk::Expression>);
        // Search matches the label the list shows for each connection.
        connection.set_expression(Some(gtk::PropertyExpression::new(
            gtk::StringObject::static_type(),
            None::<gtk::Expression>,
            "string",
        )));
        connection.set_enable_search(true);
        label(&connection, &gettext("Connection"));

        let status = adw::ToggleGroup::new();
        for (name, text) in STATUSES.iter().map(|(name, _)| *name).zip([
            gettext("All"),
            gettext("Succeeded"),
            gettext("Failed"),
            gettext("Cancelled"),
        ]) {
            status.add(adw::Toggle::builder().name(name).label(text).build());
        }
        status.set_active_name(Some("any"));
        label(&status, &gettext("Status"));

        let window_labels = [
            gettext("Any Time"),
            gettext("Today"),
            gettext("Last 7 Days"),
            gettext("Last 30 Days"),
        ];
        let window_labels: Vec<&str> = window_labels.iter().map(String::as_str).collect();
        let window = gtk::DropDown::from_strings(&window_labels);
        label(&window, &gettext("Time window"));

        let root = adw::WrapBox::builder()
            .child_spacing(6)
            .line_spacing(6)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        root.append(&connection);
        root.append(&status);
        root.append(&window);
        Self {
            root,
            connection,
            status,
            window,
            connections: connections.clone(),
        }
    }

    pub(crate) fn root(&self) -> &adw::WrapBox {
        &self.root
    }

    /// The connection drop-down's choices.
    pub(crate) fn connections(&self) -> &ConnectionFilterModel {
        &self.connections
    }

    pub(crate) fn state(&self) -> HistoryFilterState {
        read_state(&self.connection, &self.status, &self.window, &self.connections)
    }

    /// `f` runs with the new state whenever any filter changes.
    pub(crate) fn connect_changed(&self, f: impl Fn(HistoryFilterState) + 'static) {
        let f = Rc::new(f);
        // Weak, since each handler lives on one of the widgets it reads.
        let (connection, status, window) = (
            self.connection.downgrade(),
            self.status.downgrade(),
            self.window.downgrade(),
        );
        let connections = self.connections.clone();
        let changed = Rc::new(move || {
            if let (Some(connection), Some(status), Some(window)) =
                (connection.upgrade(), status.upgrade(), window.upgrade())
            {
                f(read_state(&connection, &status, &window, &connections));
            }
        });
        let notify = changed.clone();
        self.connection.connect_selected_notify(move |_| notify());
        let notify = changed.clone();
        self.status.connect_active_name_notify(move |_| notify());
        self.window.connect_selected_notify(move |_| changed());
    }

    /// Put the connection filter on `id`, or on All Connections when the
    /// history has nothing for it.
    pub(crate) fn select_connection(&self, id: Option<Uuid>) {
        let position = id.and_then(|id| self.connections.position_of(id)).unwrap_or(0);
        self.connection.set_selected(position);
    }

    #[cfg(test)]
    pub(crate) fn controls(&self) -> (gtk::DropDown, adw::ToggleGroup, gtk::DropDown) {
        (self.connection.clone(), self.status.clone(), self.window.clone())
    }
}

fn read_state(
    connection: &gtk::DropDown,
    status: &adw::ToggleGroup,
    window: &gtk::DropDown,
    connections: &ConnectionFilterModel,
) -> HistoryFilterState {
    let active = status.active_name();
    HistoryFilterState {
        connection: connections.id_at(connection.selected()),
        status: STATUSES
            .iter()
            .find(|(name, _)| active.as_deref() == Some(*name))
            .map_or(StatusFilter::Any, |(_, status)| *status),
        window: TimeWindow::ALL
            .get(window.selected() as usize)
            .copied()
            .unwrap_or_default(),
    }
}

/// The controls have no visible label of their own, so a screen reader
/// is told what each one filters by.
fn label(widget: &impl IsA<gtk::Widget>, text: &str) {
    let widget = widget.upcast_ref::<gtk::Widget>();
    widget.update_property(&[gtk::accessible::Property::Label(text)]);
    widget.set_tooltip_text(Some(text));
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;

    #[gtk4::test]
    fn toggle_emits_failed_status() {
        let filters = HistoryFilters::new(&ConnectionFilterModel::new());
        let seen: Rc<RefCell<Vec<HistoryFilterState>>> = Rc::default();
        let sink = seen.clone();
        filters.connect_changed(move |state| sink.borrow_mut().push(state));
        let (_, status, _) = filters.controls();

        status.set_active_name(Some("failed"));

        assert_eq!(
            seen.borrow().last().map(|state| state.status),
            Some(StatusFilter::Failed)
        );
        assert_eq!(filters.state().status, StatusFilter::Failed);
    }

    #[gtk4::test]
    fn the_time_window_drop_down_names_each_window() {
        let filters = HistoryFilters::new(&ConnectionFilterModel::new());
        let (_, _, window) = filters.controls();

        window.set_selected(1);

        assert_eq!(filters.state().window, TimeWindow::Today);
        assert_eq!(
            filters.state(),
            HistoryFilterState {
                window: TimeWindow::Today,
                ..HistoryFilterState::default()
            }
        );
    }
}
