use std::cell::Cell;
use std::rc::Rc;

use relm4::ComponentSender;
use tablepro_core::sql_syntax::script::LexicalSettings;
use uuid::Uuid;

use super::statement_cursor::Lexing;
use super::{SqlEditor, SqlEditorInput};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct LexingSource {
    connection_id: Option<Uuid>,
    session_id: Option<Uuid>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct KnownLexing(Rc<Cell<Option<(LexingSource, LexicalSettings)>>>);

impl KnownLexing {
    pub(crate) fn settings(&self) -> Option<LexicalSettings> {
        self.0.get().map(|(_, settings)| settings)
    }

    fn settings_from(&self, source: LexingSource) -> Option<LexicalSettings> {
        self.0
            .get()
            .filter(|(known, _)| *known == source)
            .map(|(_, settings)| settings)
    }

    fn remember(&self, source: LexingSource, settings: Option<LexicalSettings>) {
        self.0.set(settings.map(|settings| (source, settings)));
    }

    pub(crate) fn forget(&self) {
        self.0.set(None);
    }
}

impl SqlEditor {
    pub(super) fn lexing_source(&self) -> LexingSource {
        LexingSource {
            connection_id: self.connection_id,
            session_id: self.session.as_ref().map(|session| session.id),
        }
    }

    pub(super) fn lexing<'a>(&self, driver: &'a str) -> Lexing<'a> {
        Lexing {
            driver,
            settings: self.known_lexing.settings_from(self.lexing_source()),
        }
    }

    pub(super) fn read_lexing_then_run(&mut self, sql: String, sender: ComponentSender<Self>) {
        if self.reading_lexing {
            return;
        }
        let origin = crate::services::catalog::CatalogOrigin::capture(self.connection_id, &self.database);
        let Some(conn) = origin.as_ref().and_then(|origin| origin.connection(&self.database)) else {
            self.status.set_label(&crate::tr!("no active connection"));
            return;
        };
        let target = self.statement_target(conn);
        let source = self.lexing_source();
        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        self.reading_lexing = true;
        let reply = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let control = crate::services::operation_control::bounded(timeout_secs);
                    let result = target
                        .lexical_settings(&control)
                        .await
                        .map_err(|error| crate::services::error_text::driver_message(&error));
                    reply.input(SqlEditorInput::LexingRead { source, sql, result });
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_lexing_read(
        &mut self,
        source: LexingSource,
        sql: String,
        result: Result<Option<LexicalSettings>, String>,
        sender: ComponentSender<Self>,
    ) {
        self.reading_lexing = false;
        if source != self.lexing_source() {
            self.status.set_label(&crate::tr!(
                "The connection changed before the script ran. Run it again."
            ));
            return;
        }
        match result {
            Ok(settings) => {
                self.known_lexing.remember(source, settings);
                self.plan_and_run(sql, sender);
            }
            Err(message) => self.status.set_label(
                &crate::tr!("Could not read the session's string settings: {message}").replace("{message}", &message),
            ),
        }
    }

    pub(super) fn on_lexing_refreshed(&mut self, source: LexingSource, settings: Option<LexicalSettings>) {
        if source == self.lexing_source() {
            self.known_lexing.remember(source, settings);
        }
    }
}
