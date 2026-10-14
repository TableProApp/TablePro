use gtk4::gio;
use gtk4::prelude::*;
use tablepro_storage::ConnectionGroupName;

use crate::services::saved_connection_object::SavedConnectionObject;

/// The sections the picker shows for `model`: the connections in no
/// group first, where every connection starts, then each group by name
/// whatever its case. A section with no connection in it is left out.
pub(crate) fn group_sections(model: &gio::ListModel) -> Vec<Option<ConnectionGroupName>> {
    let mut ungrouped = false;
    let mut groups: Vec<ConnectionGroupName> = Vec::new();
    for object in
        (0..model.n_items()).filter_map(|position| model.item(position).and_downcast::<SavedConnectionObject>())
    {
        match object.saved().and_then(|saved| saved.group.clone()) {
            Some(group) if !groups.contains(&group) => groups.push(group),
            Some(_) => {}
            None => ungrouped = true,
        }
    }
    groups.sort_by(|a, b| {
        a.as_str()
            .to_lowercase()
            .cmp(&b.as_str().to_lowercase())
            .then_with(|| a.cmp(b))
    });
    ungrouped
        .then_some(None)
        .into_iter()
        .chain(groups.into_iter().map(Some))
        .collect()
}

#[cfg(test)]
mod tests {
    use tablepro_storage::SavedConnection;
    use uuid::Uuid;

    use super::*;

    fn object(group: Option<&str>) -> SavedConnectionObject {
        SavedConnectionObject::new(SavedConnection {
            id: Uuid::new_v4(),
            name: "n".to_owned(),
            driver_id: "postgres".to_owned(),
            host: "db".to_owned(),
            port: 5432,
            database: "app".to_owned(),
            username: "postgres".to_owned(),
            tls: tablepro_core::TlsConfig::verify_full(),
            read_only: false,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: group.map(|group| ConnectionGroupName::new(group).expect("a group name")),
        })
    }

    fn sections(groups: &[Option<&str>]) -> Vec<Option<String>> {
        let store = gio::ListStore::new::<SavedConnectionObject>();
        for group in groups {
            store.append(&object(*group));
        }
        group_sections(store.upcast_ref())
            .into_iter()
            .map(|section| section.map(String::from))
            .collect()
    }

    #[gtk4::test]
    fn ungrouped_lead_then_groups_by_name_whatever_the_case() {
        assert_eq!(
            sections(&[Some("work"), None, Some("Archive"), Some("work"), None]),
            [None, Some("Archive".to_owned()), Some("work".to_owned())]
        );
    }

    #[gtk4::test]
    fn a_list_of_groups_alone_has_no_ungrouped_section() {
        assert_eq!(sections(&[Some("Work")]), [Some("Work".to_owned())]);
        assert!(sections(&[]).is_empty());
    }
}
