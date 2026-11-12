use std::collections::HashSet;

use tablepro_storage::QueryHistory;
use tablepro_storage::query_history::{HistoryPageRequest, HistoryQuery, StatusFilter};
use uuid::Uuid;

use super::query_source::unavailable;
use super::*;

const PAST_QUERIES: usize = 100;

impl QuickOpen {
    pub(super) fn load_past_queries(&self) {
        let imp = self.imp();
        let Some((history, connection)) = imp
            .queries
            .borrow()
            .as_ref()
            .map(|source| (source.history.clone(), source.connection))
        else {
            return;
        };
        let Some(tasks) = imp.context.borrow().as_ref().map(|context| context.tasks.clone()) else {
            return;
        };
        let ticket = imp.requests.borrow_mut().issue(Request::Past);
        let weak = self.downgrade();
        spawn_and_deliver(
            &tasks,
            async move {
                let store = history.ready_store().await.ok_or_else(|| unavailable(&history))?;
                read_past_queries(&store, connection).await
            },
            move |result| {
                let Some(dialog) = weak.upgrade() else {
                    return;
                };
                if !dialog.imp().requests.borrow_mut().accept(Request::Past, ticket.stamp) {
                    return;
                }
                let result = result.unwrap_or_else(|error| {
                    tracing::warn!(%error, "could not read quick open history");
                    Err(gettext("Could not load past queries."))
                });
                {
                    let mut sources = dialog.imp().queries.borrow_mut();
                    let Some(source) = sources.as_mut() else {
                        return;
                    };
                    match result {
                        Ok(candidates) => {
                            source.past = Arc::new(candidates);
                            source.past_error = None;
                        }
                        Err(error) => source.past_error = Some(error),
                    }
                }
                dialog.refresh_notice();
                dialog.rebuild_index();
            },
        );
    }
}

pub(super) async fn read_past_queries(store: &QueryHistory, connection: Uuid) -> Result<Vec<Candidate>, String> {
    let mut query = HistoryQuery::from_input("");
    query.connection = Some(connection);
    query.status = StatusFilter::Succeeded;
    let page = store
        .search_page(&query, HistoryPageRequest::first(PAST_QUERIES))
        .await
        .map_err(|error| {
            tracing::warn!(%error, "could not list quick open history");
            gettext("Could not load past queries.")
        })?;
    let mut seen: HashSet<Arc<str>> = HashSet::new();
    Ok(page
        .entries
        .into_iter()
        .filter_map(|entry| {
            let sql: Arc<str> = Arc::from(entry.query);
            let name = sql
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())?
                .chars()
                .take(120)
                .collect();
            if !seen.insert(sql.clone()) {
                return None;
            }
            Some(Candidate::PastQuery {
                id: entry.id,
                name,
                sql,
            })
        })
        .collect())
}
