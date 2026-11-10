use super::*;
use crate::services::history_service::HistoryService;
use uuid::Uuid;

pub(super) struct QuerySource {
    pub(super) history: HistoryService,
    pub(super) connection: Uuid,
    pub(super) candidates: Arc<Vec<Candidate>>,
    pub(super) error: Option<String>,
    pub(super) past: Arc<Vec<Candidate>>,
    pub(super) past_error: Option<String>,
}

impl QuickOpen {
    pub(crate) fn include_queries(&self, history: HistoryService, connection: Uuid) {
        self.imp().queries.replace(Some(QuerySource {
            history,
            connection,
            candidates: Arc::default(),
            error: None,
            past: Arc::default(),
            past_error: None,
        }));
        if let Some(widgets) = self.imp().widgets.get() {
            widgets
                .entry
                .set_placeholder_text(Some(&gettext("Search tables, views and queries")));
            widgets
                .entry
                .update_property(&[gtk::accessible::Property::Label(&gettext(
                    "Search tables, views and queries",
                ))]);
            widgets
                .list
                .update_property(&[gtk::accessible::Property::Label(&gettext("Tables, views and queries"))]);
        }
        self.load_queries();
    }

    pub(super) fn load_queries(&self) {
        self.load_past_queries();
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
        let ticket = imp.requests.borrow_mut().issue(Request::Queries);
        let weak = self.downgrade();
        spawn_and_deliver(
            &tasks,
            async move {
                let store = history.ready_store().await.ok_or_else(|| unavailable(&history))?;
                let queries = store.saved_queries().list(Some(connection)).await.map_err(|error| {
                    tracing::warn!(%error, "could not list quick open saved queries");
                    gettext("Could not load saved queries.")
                })?;
                Ok::<_, String>(
                    queries
                        .into_iter()
                        .map(|query| Candidate::SavedQuery {
                            id: query.id,
                            name: query.name,
                        })
                        .collect::<Vec<_>>(),
                )
            },
            move |result| {
                let Some(dialog) = weak.upgrade() else {
                    return;
                };
                if !dialog
                    .imp()
                    .requests
                    .borrow_mut()
                    .accept(Request::Queries, ticket.stamp)
                {
                    return;
                }
                let result = result.unwrap_or_else(|error| {
                    tracing::warn!(%error, "could not read quick open saved queries");
                    Err(gettext("Could not load saved queries."))
                });
                {
                    let mut sources = dialog.imp().queries.borrow_mut();
                    let Some(source) = sources.as_mut() else {
                        return;
                    };
                    match result {
                        Ok(candidates) => {
                            source.candidates = Arc::new(candidates);
                            source.error = None;
                        }
                        Err(error) => source.error = Some(error),
                    }
                }
                dialog.refresh_notice();
                dialog.rebuild_index();
            },
        );
    }

    pub(super) fn choose_query(&self, query: QueryId) {
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
        let ticket = imp.requests.borrow_mut().issue(Request::Pick);
        let weak = self.downgrade();
        spawn_and_deliver(
            &tasks,
            async move {
                let store = history.ready_store().await.ok_or_else(|| unavailable(&history))?;
                match query {
                    QueryId::Saved(id) => match store.saved_queries().get(id).await {
                        Ok(Some(saved)) if saved.connection_id == connection => Ok(saved.query),
                        Ok(_) => Err(gettext("This saved query is no longer available.")),
                        Err(error) => {
                            tracing::warn!(%error, "could not open saved query");
                            Err(gettext("Could not open this saved query."))
                        }
                    },
                    QueryId::Past(id) => match store.fetch_by_ids(&[id]).await {
                        Ok(entries) => entries
                            .into_iter()
                            .find(|entry| entry.connection_id == connection && entry.success)
                            .map(|entry| entry.query)
                            .ok_or_else(|| gettext("This past query is no longer available.")),
                        Err(error) => {
                            tracing::warn!(%error, "could not open past query");
                            Err(gettext("Could not open this past query."))
                        }
                    },
                }
            },
            move |result| {
                let Some(dialog) = weak.upgrade() else {
                    return;
                };
                if !dialog.imp().requests.borrow_mut().accept(Request::Pick, ticket.stamp) {
                    return;
                }
                match result {
                    Ok(Ok(sql)) => dialog.finish_pick(Pick::Query(sql)),
                    result => {
                        let error = match result {
                            Ok(Err(error)) => error,
                            Err(error) => {
                                tracing::warn!(%error, "could not read saved query");
                                gettext("Could not open this saved query.")
                            }
                            Ok(Ok(_)) => return,
                        };
                        if let Some(source) = dialog.imp().queries.borrow_mut().as_mut() {
                            match query {
                                QueryId::Saved(_) => source.error = Some(error),
                                QueryId::Past(_) => source.past_error = Some(error),
                            }
                        }
                        dialog.refresh_notice();
                    }
                }
            },
        );
    }

    pub(super) fn refresh_notice(&self) {
        let Some(widgets) = self.imp().widgets.get() else {
            return;
        };
        let mut errors = Vec::new();
        if self.imp().catalog_error.get() {
            errors.push(gettext("Could not load tables and views."));
        }
        if let Some(source) = self.imp().queries.borrow().as_ref() {
            errors.extend(source.error.clone());
            errors.extend(source.past_error.clone());
        }
        let text = errors.join(" ");
        widgets.banner.set_title(&text);
        widgets.banner.set_revealed(!text.is_empty());
    }
}

pub(super) fn unavailable(history: &HistoryService) -> String {
    history
        .availability()
        .borrow()
        .failure()
        .map(str::to_owned)
        .unwrap_or_else(|| gettext("Saved queries and query history are unavailable."))
}
