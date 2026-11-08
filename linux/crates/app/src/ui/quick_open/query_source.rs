use super::*;
use crate::services::history_service::HistoryService;
use uuid::Uuid;

pub(super) struct QuerySource {
    history: HistoryService,
    connection: Uuid,
    pub(super) candidates: Arc<Vec<Candidate>>,
    error: Option<String>,
}

impl QuickOpen {
    pub(crate) fn include_saved_queries(&self, history: HistoryService, connection: Uuid) {
        self.imp().queries.replace(Some(QuerySource {
            history,
            connection,
            candidates: Arc::default(),
            error: None,
        }));
        if let Some(widgets) = self.imp().widgets.get() {
            widgets
                .entry
                .set_placeholder_text(Some(&gettext("Search tables, views and saved queries")));
            widgets
                .entry
                .update_property(&[gtk::accessible::Property::Label(&gettext(
                    "Search tables, views and saved queries",
                ))]);
            widgets
                .list
                .update_property(&[gtk::accessible::Property::Label(&gettext(
                    "Tables, views and saved queries",
                ))]);
        }
        self.load_queries();
    }

    pub(super) fn load_queries(&self) {
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

    pub(super) fn choose_query(&self, id: i64) {
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
                match store.saved_queries().get(id).await {
                    Ok(Some(query)) if query.connection_id == connection => Ok(query.query),
                    Ok(_) => Err(gettext("This saved query is no longer available.")),
                    Err(error) => {
                        tracing::warn!(%error, "could not open saved query");
                        Err(gettext("Could not open this saved query."))
                    }
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
                            source.error = Some(error);
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
        let query_error = self
            .imp()
            .queries
            .borrow()
            .as_ref()
            .and_then(|source| source.error.clone());
        let text = match (self.imp().catalog_error.get(), query_error) {
            (true, Some(query)) => gettext_f("Could not load tables and views. {error}", &[("error", &query)]),
            (true, None) => gettext("Could not load tables and views."),
            (false, Some(query)) => query,
            (false, None) => String::new(),
        };
        widgets.banner.set_title(&text);
        widgets.banner.set_revealed(!text.is_empty());
    }
}

fn unavailable(history: &HistoryService) -> String {
    history
        .availability()
        .borrow()
        .failure()
        .map(str::to_owned)
        .unwrap_or_else(|| gettext("Saved queries are unavailable."))
}
