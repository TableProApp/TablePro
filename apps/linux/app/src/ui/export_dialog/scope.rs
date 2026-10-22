use relm4::adw::prelude::*;
use relm4::{adw, gtk};
use tablepro_core::QueryResult;

use super::PagedExport;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ExportScope {
    TablePage { filtered: bool },
    QueryResult,
    QueryRerun,
}

pub(super) fn build(
    scope: ExportScope,
    result: &QueryResult,
    paged: Option<&PagedExport>,
) -> (adw::PreferencesGroup, Option<adw::ComboRow>) {
    let group = adw::PreferencesGroup::builder().title(crate::tr!("Scope")).build();
    if let ExportScope::TablePage { filtered } = scope {
        let labels = [
            crate::tr!("Current table page"),
            crate::tr!("All matching table rows (unavailable)"),
        ];
        let choices = gtk::StringList::new(&labels.iter().map(String::as_str).collect::<Vec<_>>());
        let choice = adw::ComboRow::builder()
            .title(crate::tr!("Rows to export"))
            .model(&choices)
            .build();
        let page_description = if filtered {
            crate::tr!("{n} loaded rows from the active table filter").replace("{n}", &result.rows.len().to_string())
        } else {
            crate::tr!("{n} loaded rows from the current page").replace("{n}", &result.rows.len().to_string())
        };
        choice.set_subtitle(&page_description);
        choice.connect_selected_notify(move |choice| {
            choice.set_subtitle(&if choice.selected() == 0 {
                page_description.clone()
            } else {
                super::file::snapshot_refusal_message().to_string()
            });
        });
        group.add(&choice);
        return (group, Some(choice));
    }
    let title = match scope {
        ExportScope::QueryRerun => crate::tr!("All query rows (run again)"),
        _ => crate::tr!("Loaded query result"),
    };
    let subtitle = match scope {
        ExportScope::QueryRerun => {
            crate::tr!("Runs the same query again through its guarded connection and session. Data may have changed.")
        }
        _ => super::format_subtitle(result, paged),
    };
    group.add(&adw::ActionRow::builder().title(title).subtitle(subtitle).build());
    (group, None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn table_scope_cannot_enable_unqualified_snapshot_export() {
        adw::init().unwrap();
        let result = QueryResult {
            columns: Vec::new(),
            rows: vec![Vec::new()],
            truncated: true,
        };
        let (group, choice) = build(ExportScope::TablePage { filtered: true }, &result, None);
        let choice = choice.unwrap();
        assert_eq!(group.title(), "Scope");
        assert_eq!(choice.selected(), 0);
        let page_description = choice.subtitle();
        choice.set_selected(1);
        assert_ne!(choice.subtitle(), page_description);
        assert_eq!(
            choice.subtitle().unwrap().to_string(),
            super::super::file::snapshot_refusal_message()
        );
        choice.set_selected(0);
        assert_eq!(choice.subtitle(), page_description);
        let (_, query_choice) = build(ExportScope::QueryResult, &result, None);
        assert!(query_choice.is_none());
    }
}
