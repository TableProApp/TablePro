//! The order both connection lists render in, and the group headers
//! that go with it.
//!
//! The welcome page and the header popover show the same connections,
//! so they sort them the same way and read the same headers.

use relm4::gtk;
use relm4::gtk::prelude::*;

use tablepro_storage::SavedConnection;

/// Sort the list the way both connection lists show it.
///
/// Ungrouped connections lead, because that is where every connection
/// starts and a user with no groups sees the list they always saw.
/// Groups follow in alphabetical order. Inside each block the order is
/// recency-first with an alphabetical tiebreaker, so the connection
/// opened last is the one nearest the top. Never-opened connections
/// fall to the end of their block and sort by name among themselves.
pub(super) fn sort(connections: &mut [SavedConnection]) {
    connections.sort_by(|a, b| {
        group_key(a)
            .cmp(&group_key(b))
            .then_with(|| recency_key(a).cmp(&recency_key(b)))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
}

/// Ungrouped sorts before every group, and groups sort by name
/// regardless of how they were capitalised.
fn group_key(connection: &SavedConnection) -> (bool, String) {
    match group_of(connection) {
        Some(group) => (true, group.to_lowercase()),
        None => (false, String::new()),
    }
}

/// Newest first, with never-opened last. The timestamp is negated
/// rather than compared backwards so it composes with the keys around
/// it.
fn recency_key(connection: &SavedConnection) -> (bool, i64) {
    match connection.last_opened_at {
        Some(at) => (false, -at.timestamp_millis()),
        None => (true, 0),
    }
}

/// The group as it is shown, which is `None` for a name that is empty
/// or only spaces. A group nobody can see is not a group.
pub(super) fn group_of(connection: &SavedConnection) -> Option<&str> {
    connection
        .group
        .as_deref()
        .map(str::trim)
        .filter(|group| !group.is_empty())
}

/// Every group in the list, in the order the headers appear, without
/// duplicates.
pub(super) fn groups(connections: &[SavedConnection]) -> Vec<String> {
    let mut sorted = connections.to_vec();
    sort(&mut sorted);
    let mut found: Vec<String> = Vec::new();
    for connection in &sorted {
        let Some(group) = group_of(connection) else {
            continue;
        };
        if !found.iter().any(|seen| seen == group) {
            found.push(group.to_owned());
        }
    }
    found
}

/// The header a row needs, given the row before it: the group's name
/// on the first row of each group, and nothing anywhere else.
///
/// `None` for the ungrouped block, which leads the list and needs no
/// heading to say what it is.
pub(super) fn header_for(connections: &[SavedConnection], index: usize, previous: Option<usize>) -> Option<String> {
    let group = group_of(connections.get(index)?)?;
    let before = previous.and_then(|index| connections.get(index)).and_then(group_of);
    match before == Some(group) {
        true => None,
        false => Some(group.to_owned()),
    }
}

/// Install the group headers on a list box whose rows are `connections`
/// in order.
///
/// The header function reads a row's position rather than anything
/// stored on the widget, so the factory that builds the rows does not
/// have to know about groups at all.
pub(super) fn install_group_headers(listbox: &gtk::ListBox, connections: std::rc::Rc<Vec<SavedConnection>>) {
    listbox.set_header_func(move |row, before| {
        let index = usize::try_from(row.index()).unwrap_or(0);
        let previous = before.map(|row| usize::try_from(row.index()).unwrap_or(0));
        match header_for(&connections, index, previous) {
            Some(group) => row.set_header(Some(&group_header(&group))),
            None => row.set_header(gtk::Widget::NONE),
        }
    });
}

/// A group heading in the shape GNOME uses for a list section: a bold
/// caption above the first row, indented to line up with the row's
/// title.
fn group_header(group: &str) -> gtk::Widget {
    let label = gtk::Label::builder()
        .label(group)
        .xalign(0.0)
        .margin_top(12)
        .margin_bottom(6)
        .margin_start(12)
        .margin_end(12)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .build();
    label.add_css_class("heading");
    label.add_css_class("dim-label");
    label.upcast()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};
    use uuid::Uuid;

    fn connection(name: &str, group: Option<&str>, opened_days_ago: Option<i64>) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            use_tls: true,
            read_only: false,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: opened_days_ago.map(|days| {
                Utc.timestamp_opt(1_700_000_000 - days * 86_400, 0)
                    .single()
                    .expect("a time")
            }),
            color: None,
            group: group.map(str::to_owned),
        }
    }

    fn names(connections: &[SavedConnection]) -> Vec<String> {
        connections.iter().map(|saved| saved.name.clone()).collect()
    }

    #[test]
    fn ungrouped_connections_lead_the_list() {
        let mut list = vec![
            connection("in a group", Some("Work"), Some(1)),
            connection("on its own", None, Some(1)),
        ];

        sort(&mut list);

        assert_eq!(names(&list), vec!["on its own", "in a group"]);
    }

    #[test]
    fn groups_follow_in_alphabetical_order_whatever_the_case() {
        let mut list = vec![
            connection("c", Some("work"), Some(1)),
            connection("a", Some("Archive"), Some(1)),
            connection("b", Some("Personal"), Some(1)),
        ];

        sort(&mut list);

        assert_eq!(names(&list), vec!["a", "b", "c"]);
    }

    #[test]
    fn the_connection_opened_last_leads_its_own_group() {
        let mut list = vec![
            connection("older", Some("Work"), Some(9)),
            connection("newer", Some("Work"), Some(1)),
            connection("never", Some("Work"), None),
        ];

        sort(&mut list);

        assert_eq!(names(&list), vec!["newer", "older", "never"]);
    }

    #[test]
    fn never_opened_connections_sort_by_name_among_themselves() {
        let mut list = vec![connection("zeta", None, None), connection("Alpha", None, None)];

        sort(&mut list);

        assert_eq!(names(&list), vec!["Alpha", "zeta"]);
    }

    #[test]
    fn a_group_of_only_spaces_is_no_group_at_all() {
        let mut list = vec![
            connection("blank", Some("   "), Some(1)),
            connection("real", None, Some(2)),
        ];

        sort(&mut list);

        assert_eq!(group_of(&list[0]), None);
        assert_eq!(names(&list), vec!["blank", "real"]);
    }

    #[test]
    fn a_header_sits_on_the_first_row_of_each_group_only() {
        let mut list = vec![
            connection("loose", None, Some(1)),
            connection("a", Some("Work"), Some(1)),
            connection("b", Some("Work"), Some(2)),
            connection("c", Some("Zoo"), Some(1)),
        ];
        sort(&mut list);

        assert_eq!(header_for(&list, 0, None), None, "the ungrouped block needs no heading");
        assert_eq!(header_for(&list, 1, Some(0)), Some("Work".to_owned()));
        assert_eq!(header_for(&list, 2, Some(1)), None);
        assert_eq!(header_for(&list, 3, Some(2)), Some("Zoo".to_owned()));
    }

    #[test]
    fn a_header_lookup_past_the_end_asks_for_nothing() {
        let list = vec![connection("loose", None, Some(1))];

        assert_eq!(header_for(&list, 9, Some(8)), None);
    }

    #[test]
    fn the_group_list_holds_each_name_once_in_header_order() {
        let list = vec![
            connection("a", Some("Work"), Some(1)),
            connection("b", Some("Archive"), Some(1)),
            connection("c", Some("Work"), Some(2)),
            connection("d", None, Some(1)),
        ];

        assert_eq!(groups(&list), vec!["Archive".to_owned(), "Work".to_owned()]);
    }
}
