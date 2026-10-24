use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_storage::SavedConnection;
use tablepro_storage::query_history::HistoryConnection;
use uuid::Uuid;

use crate::i18n::gettext;

/// The connection filter's choices: All Connections, then each
/// connection the history has entries for. A saved connection shows the
/// name it has now; one deleted or never saved shows the name its latest
/// run had. A clone shares the same choices.
#[derive(Clone)]
pub(crate) struct ConnectionFilterModel {
    ids: Rc<RefCell<Vec<Option<Uuid>>>>,
    labels: gtk::StringList,
}

impl ConnectionFilterModel {
    pub(crate) fn new() -> Self {
        Self {
            ids: Rc::new(RefCell::new(vec![None])),
            labels: gtk::StringList::new(&[gettext("All Connections").as_str()]),
        }
    }

    /// One label per choice, in the order of the ids.
    pub(crate) fn labels(&self) -> &gtk::StringList {
        &self.labels
    }

    pub(crate) fn fill(&self, connections: &[HistoryConnection], saved: &[SavedConnection]) {
        let mut listed: Vec<(String, Uuid)> = connections
            .iter()
            .map(|connection| {
                let name = saved
                    .iter()
                    .find(|saved| saved.id == connection.id)
                    .map_or(&connection.name, |saved| &saved.name);
                (name.clone(), connection.id)
            })
            .collect();
        listed.sort_by_cached_key(|(name, id)| (name.to_lowercase(), *id));
        let ids: Vec<Option<Uuid>> = std::iter::once(None)
            .chain(listed.iter().map(|(_, id)| Some(*id)))
            .collect();
        let unchanged = *self.ids.borrow() == ids
            && listed
                .iter()
                .zip(1..)
                .all(|((name, _), position)| self.labels.string(position).is_some_and(|label| label == name.as_str()));
        // A splice drops the drop-down's selection, so the filter would
        // move for a list that did not change.
        if unchanged {
            return;
        }
        // The ids go first: the splice notifies the drop-down, and what
        // it reads then has to match the labels.
        self.ids.replace(ids);
        let names: Vec<&str> = listed.iter().map(|(name, _)| name.as_str()).collect();
        self.labels.splice(1, self.labels.n_items().saturating_sub(1), &names);
    }

    /// `None` for All Connections, and for a position past the end.
    pub(crate) fn id_at(&self, position: u32) -> Option<Uuid> {
        self.ids.borrow().get(position as usize).copied().flatten()
    }

    pub(crate) fn position_of(&self, id: Uuid) -> Option<u32> {
        self.ids
            .borrow()
            .iter()
            .position(|listed| *listed == Some(id))
            .and_then(|position| u32::try_from(position).ok())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn saved(id: Uuid, name: &str) -> SavedConnection {
        SavedConnection {
            id,
            name: name.to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn labels(model: &ConnectionFilterModel) -> Vec<String> {
        (0..model.labels().n_items())
            .filter_map(|position| model.labels().string(position))
            .map(String::from)
            .collect()
    }

    #[gtk4::test]
    fn saved_connections_show_their_current_name_in_order() {
        let (renamed, unsaved) = (Uuid::new_v4(), Uuid::new_v4());
        let model = ConnectionFilterModel::new();

        model.fill(
            &[
                HistoryConnection {
                    id: renamed,
                    name: "zeta".to_owned(),
                },
                HistoryConnection {
                    id: unsaved,
                    name: "Scratch".to_owned(),
                },
            ],
            &[saved(renamed, "alpha"), saved(Uuid::new_v4(), "No history")],
        );

        assert_eq!(labels(&model), ["All Connections", "alpha", "Scratch"]);
        assert_eq!(model.id_at(0), None);
        assert_eq!(model.id_at(1), Some(renamed));
        assert_eq!(model.position_of(unsaved), Some(2));
        assert_eq!(model.id_at(3), None);
    }

    #[gtk4::test]
    fn filling_with_the_same_connections_leaves_the_labels_alone() {
        let model = ConnectionFilterModel::new();
        let listed = [HistoryConnection {
            id: Uuid::new_v4(),
            name: "alpha".to_owned(),
        }];
        model.fill(&listed, &[]);
        let changes = std::rc::Rc::new(std::cell::Cell::new(0));
        let counted = changes.clone();
        model
            .labels()
            .connect_items_changed(move |_, _, _, _| counted.set(counted.get() + 1));

        model.fill(&listed, &[]);
        assert_eq!(changes.get(), 0, "an unchanged list was spliced");

        model.fill(&listed, &[saved(listed[0].id, "renamed")]);
        assert_eq!(changes.get(), 1);
        assert_eq!(labels(&model), ["All Connections", "renamed"]);
    }
}
