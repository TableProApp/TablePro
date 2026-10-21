use super::stream_pages::{StreamPageCache, StreamTerminal};
use super::*;
use relm4::ComponentSender;

pub(super) struct ActiveStream {
    generation: u64,
    identity: StatementIdentity,
    sql_preview: String,
    export_query: Option<crate::ui::export_dialog::StreamExportQuery>,
    cache: StreamPageCache,
    error: Option<String>,
}

impl ActiveStream {
    fn outcome(&self, terminal: StreamTerminal) -> StatementOutcome {
        StatementOutcome {
            identity: self.identity,
            sql_preview: self.sql_preview.clone(),
            elapsed_ms: 0,
            kind: StatementOutcomeKind::Streamed(Box::new(self.cache.snapshot(terminal, self.export_query.clone()))),
            pinned: false,
        }
    }
}

fn take_stream_for_generation(streaming: &mut Option<ActiveStream>, generation: u64) -> Option<ActiveStream> {
    if streaming.as_ref().is_some_and(|stream| stream.generation == generation) {
        return streaming.take();
    }
    None
}

impl SqlEditor {
    pub(super) fn on_stream_started(
        &mut self,
        generation: u64,
        identity: StatementIdentity,
        sql_preview: String,
        export_query: Option<crate::ui::export_dialog::StreamExportQuery>,
        accepted: tokio::sync::oneshot::Sender<bool>,
    ) {
        if !self.run_generation.accepts(generation) {
            let _ = accepted.send(false);
            return;
        }
        self.streaming = Some(ActiveStream {
            generation,
            identity,
            sql_preview,
            export_query,
            cache: StreamPageCache::default(),
            error: None,
        });
        if self.results_holder.first_child().is_none() {
            let loading = waiting_for_stream_page();
            self.show_pins_above(&loading);
        }
        let _ = accepted.send(true);
    }

    pub(super) fn on_stream_page(
        &mut self,
        generation: u64,
        sequence: u64,
        page: std::sync::Arc<QueryResult>,
        accepted: tokio::sync::oneshot::Sender<bool>,
    ) {
        if !self.run_generation.accepts(generation) {
            let _ = accepted.send(false);
            return;
        }
        let (outcome, total_rows) = {
            let Some(stream) = self.streaming.as_mut().filter(|stream| stream.generation == generation) else {
                let _ = accepted.send(false);
                return;
            };
            if let Err(error) = stream.cache.append(sequence, page) {
                let message = match error {
                    stream_pages::PageAppendError::OutOfOrder => {
                        crate::tr!("A streamed result page arrived out of order.")
                    }
                    stream_pages::PageAppendError::SchemaChanged => {
                        crate::tr!("The result columns changed between pages.")
                    }
                    stream_pages::PageAppendError::InvalidRowWidth => {
                        crate::tr!("A result page did not match its columns.")
                    }
                };
                stream.error = Some(message);
                let _ = accepted.send(false);
                return;
            }
            (stream.outcome(StreamTerminal::Loading), stream.cache.total_rows())
        };
        let shown = self.pinned.show(vec![outcome.clone()]);
        self.refresh_pin_button();
        let target = super::stream_view::LiveStreamTarget {
            grid_sender: &self.grid_sender,
            connection_id: self.connection_id,
            database: self.database.clone(),
            settings_store: self.result_view_settings.clone(),
        };
        let updated = match &outcome.kind {
            StatementOutcomeKind::Streamed(result) => {
                super::stream_view::update_live_stream(&self.results_holder, &outcome, result, &target)
            }
            _ => false,
        };
        if updated {
            self.status
                .set_label(&crate::tr!("Received {n} rows").replace("{n}", &total_rows.to_string()));
            let _ = accepted.send(true);
            return;
        }
        clear_results_box(&self.results_holder);
        render_outcomes(
            &self.results_holder,
            &shown,
            &self.grid_sender,
            self.connection_id,
            self.database.clone(),
            self.result_view_settings.clone(),
        );
        self.status
            .set_label(&crate::tr!("Received {n} rows").replace("{n}", &total_rows.to_string()));
        let _ = accepted.send(true);
    }

    pub(super) fn on_stream_finished(
        &mut self,
        generation: u64,
        terminal: StreamTerminal,
        sender: &ComponentSender<Self>,
    ) {
        let Some((run_terminal, context)) = self.finish_run(generation, sender) else {
            return;
        };
        let elapsed = SystemTime::now()
            .duration_since(context.started_at)
            .map(|duration| duration.as_millis() as i64)
            .unwrap_or(0);
        let timed_out = (context.timeout_secs, context.sql.clone());
        let stream = take_stream_for_generation(&mut self.streaming, generation);
        let terminal = stream
            .as_ref()
            .and_then(|stream| stream.error.clone())
            .map_or(terminal, StreamTerminal::Failed);
        let rows = stream.as_ref().map(|stream| stream.cache.total_rows() as i64);
        let outcome = stream.map(|stream| {
            let mut outcome = stream.outcome(terminal.clone());
            outcome.elapsed_ms = elapsed.max(0) as u128;
            outcome
        });
        let history_outcome = match &terminal {
            StreamTerminal::Complete => Outcome::Success,
            StreamTerminal::Cancelled => Outcome::Cancelled,
            StreamTerminal::TimedOut => Outcome::Error(crate::tr!("Query timed out")),
            StreamTerminal::Failed(message) => Outcome::Error(message.clone()),
            StreamTerminal::Loading => Outcome::Error(crate::tr!("Stream ended before completion")),
        };
        let outcomes = outcome.into_iter().collect::<Vec<_>>();
        self.mark_statements(&context, run_terminal.replace_ui, &outcomes);
        self.record_history(context, elapsed, rows.filter(|rows| *rows > 0), history_outcome);
        if !run_terminal.replace_ui {
            return;
        }
        self.cancel_token = None;
        match &terminal {
            StreamTerminal::Complete => self
                .status
                .set_label(&crate::tr!("done in {ms} ms").replace("{ms}", &elapsed.max(0).to_string())),
            StreamTerminal::Cancelled => self.status.set_label(&crate::tr!("cancelled")),
            StreamTerminal::TimedOut => {
                self.status.set_label(&crate::tr!("timed out"));
                self.offer_longer_timeout(timed_out.0, timed_out.1);
            }
            StreamTerminal::Failed(message) => self.status.set_label(message),
            StreamTerminal::Loading => self.status.set_label(&crate::tr!("error")),
        }
        let shown = self.pinned.show(outcomes);
        self.refresh_pin_button();
        clear_results_box(&self.results_holder);
        render_outcomes(
            &self.results_holder,
            &shown,
            &self.grid_sender,
            self.connection_id,
            self.database.clone(),
            self.result_view_settings.clone(),
        );
    }
}

fn waiting_for_stream_page() -> adw::StatusPage {
    adw::StatusPage::builder()
        .title(crate::tr!("Waiting for result pages"))
        .icon_name("content-loading-symbolic")
        .vexpand(true)
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stale_run_completion_keeps_the_newer_stream() {
        let mut streaming = Some(ActiveStream {
            generation: 2,
            identity: StatementIdentity::default(),
            sql_preview: "SELECT 2".into(),
            export_query: None,
            cache: StreamPageCache::default(),
            error: None,
        });

        assert!(take_stream_for_generation(&mut streaming, 1).is_none());
        assert_eq!(streaming.as_ref().map(|stream| stream.generation), Some(2));
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_stream_waits_with_a_loading_status_page() {
        relm4::adw::init().unwrap();
        let page = waiting_for_stream_page();

        assert_eq!(page.title(), "Waiting for result pages");
        assert_eq!(page.icon_name().as_deref(), Some("content-loading-symbolic"));
    }
}
