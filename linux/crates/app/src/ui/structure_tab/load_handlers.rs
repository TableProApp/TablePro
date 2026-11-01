use std::sync::Arc;

use gtk4::glib;
use tablepro_core::ddl::{CharacterSet, TableDraft};
use tablepro_session::{LinkGeneration, OperationError};

use super::character_set_fetch::fetch_character_sets;
use super::context::CharacterSets;
use super::draft_column_object::DraftColumnObject;
use super::structure_fetch::fetch_structure;
use super::{
    LoadInput, LoadedStructure, StructureCommand, StructureEffects, StructureMode, StructureModel,
    StructureRequestKind, StructureTabOutput, items, replace_items,
};
use crate::runtime::{RequestTicket, Stamped};
use crate::ui::tab_load::{ContentPage, LoadFailure, LoadPresentation};

impl StructureModel {
    pub(super) fn on_load(&mut self, input: LoadInput, fx: &mut StructureEffects) {
        match input {
            LoadInput::Start => {
                match self.mode() {
                    StructureMode::Edit => self.read_definition(fx),
                    StructureMode::New => self.read_character_sets(),
                }
                self.sync_add_rows();
                self.regenerate_sql_preview(&self.pending());
            }
            LoadInput::Command(command) => self.on_command(*command, fx),
            LoadInput::LinkChanged(generation) => self.on_link_changed(generation, fx),
            LoadInput::SchemaChanged => {
                // Reading the table again replaces the draft, so a tab
                // with edits of its own keeps them until Discard.
                if self.mode() == StructureMode::Edit {
                    match self.last_dirty {
                        true => self.definition_stale = true,
                        false => self.read_definition(fx),
                    }
                }
            }
            LoadInput::Retry => self.read_definition(fx),
        }
    }

    /// Read the table's definition. A definition on screen stays there
    /// while it is read, and through a failure.
    pub(super) fn read_definition(&mut self, fx: &mut StructureEffects) {
        let presentation = self.load.begin();
        self.present(presentation, fx);
        self.fetch_definition();
    }

    /// Show where the read stands: the spinner, the editor or the error
    /// page, the banner over a definition that could not be read again,
    /// and the tab bar's spinner.
    fn present(&mut self, presentation: LoadPresentation, fx: &mut StructureEffects) {
        match &presentation.page {
            ContentPage::Spinner => self.widgets.inner_stack.set_visible_child_name("loading"),
            ContentPage::Content => self.widgets.inner_stack.set_visible_child_name("editor"),
            ContentPage::Error(failure) => {
                // Inline on the status page: a modal alert would say the
                // same and make the user dismiss it before seeing the
                // page. The page reads its description as markup.
                self.widgets
                    .error_status
                    .set_description(Some(&glib::markup_escape_text(&failure.message())));
                self.widgets.inner_stack.set_visible_child_name("error");
            }
        }
        self.widgets.stale_banner.show(presentation.stale.as_ref());
        if self.tab_loading != presentation.tab_loading {
            self.tab_loading = presentation.tab_loading;
            fx.output(StructureTabOutput::LoadingChanged(presentation.tab_loading));
        }
    }

    /// One read brings columns, indexes and foreign keys from the same
    /// moment, so the tab rebuilds once.
    fn fetch_definition(&mut self) {
        self.issued_on
            .insert(StructureRequestKind::Definition, self.session.link_generation());
        let RequestTicket { stamp, cancel } = self.sequencer.issue(StructureRequestKind::Definition);
        let work = fetch_structure(self.session.clone(), self.table.clone(), cancel);
        let tab = self.this.clone();
        let _delivery = crate::runtime::spawn_and_deliver(&self.tasks, work, move |joined| {
            let value = joined.unwrap_or_else(|failure| {
                Err(LoadFailure::Definition(Arc::new(
                    tablepro_session::OperationError::from(failure),
                )))
            });
            if let Some(tab) = tab.upgrade() {
                tab.send(LoadInput::Command(Box::new(StructureCommand::Loaded(Stamped {
                    stamp,
                    value,
                }))));
            }
        });
    }

    fn on_loaded(&mut self, loaded: LoadedStructure, fx: &mut StructureEffects) {
        let draft = TableDraft::from_definition(&loaded.definition);
        {
            let mut context = self.context.borrow_mut();
            context.dialect = Some(loaded.dialect);
            context.definition = Some(loaded.definition);
        }
        self.show_draft(draft);
        self.sync_add_rows();
        let presentation = self.load.succeed();
        self.present(presentation, fx);
        self.definition_stale = false;
        // The definition is current again, so the diff counts.
        self.refetching = false;
        self.sync_editable();
        self.recompute_dirty_state(fx);
        self.read_character_sets();
    }

    /// Read the server's character sets once the dialect says the rows
    /// list them. They stay for the tab's life once read; a failed read
    /// is asked again with the next definition or reconnect.
    pub(super) fn read_character_sets(&mut self) {
        let wanted = {
            let context = self.context.borrow();
            context.offers_character_sets() && !matches!(context.character_sets, CharacterSets::Read(_))
        };
        if !wanted || self.sequencer.is_pending(StructureRequestKind::CharacterSets) {
            return;
        }
        let RequestTicket { stamp, cancel } = self.sequencer.issue(StructureRequestKind::CharacterSets);
        let work = fetch_character_sets(self.session.clone(), cancel);
        let tab = self.this.clone();
        let _delivery = crate::runtime::spawn_and_deliver(&self.tasks, work, move |joined| {
            let value = joined.unwrap_or_else(|failure| Err(Arc::new(OperationError::from(failure))));
            if let Some(tab) = tab.upgrade() {
                tab.send(LoadInput::Command(Box::new(StructureCommand::CharacterSetsRead(
                    Stamped { stamp, value },
                ))));
            }
        });
    }

    /// The rows list the character sets as they are built, so the column
    /// rows are built again, and the Options page refilled.
    fn on_character_sets(&mut self, value: Result<Vec<CharacterSet>, Arc<OperationError>>) {
        let lists_columns = {
            let mut context = self.context.borrow_mut();
            context.character_sets = match value {
                Ok(sets) => CharacterSets::Read(sets.into()),
                Err(_) => CharacterSets::Unreadable,
            };
            context.capabilities().column_collations
        };
        self.show_table_options();
        if lists_columns {
            replace_items(&self.columns, items::<DraftColumnObject>(&self.columns));
        }
    }

    /// With a definition on screen it stays, under the banner. A read
    /// after a committed save keeps the draft locked: the definition on
    /// screen is from before the save, so the draft's diff against it
    /// would offer the saved changes again.
    fn on_load_failed(&mut self, failure: LoadFailure, fx: &mut StructureEffects) {
        let presentation = self.load.fail(failure);
        let content_kept = !matches!(presentation.page, ContentPage::Error(_));
        self.present(presentation, fx);
        if content_kept {
            return;
        }
        // A retry from the error page must not find dirty tracking still
        // frozen.
        self.refetching = false;
        self.sync_editable();
    }

    fn on_command(&mut self, command: StructureCommand, fx: &mut StructureEffects) {
        let (stamp, value) = match command {
            StructureCommand::Loaded(Stamped { stamp, value }) => (stamp, value),
            StructureCommand::CharacterSetsRead(Stamped { stamp, value }) => {
                if self.sequencer.accept(StructureRequestKind::CharacterSets, stamp) {
                    self.failed.record(StructureRequestKind::CharacterSets, &value);
                    self.on_character_sets(value);
                }
                return;
            }
        };
        if !self.sequencer.accept(StructureRequestKind::Definition, stamp) {
            return;
        }
        self.failed.record(StructureRequestKind::Definition, &value);
        match value {
            Ok(loaded) => self.on_loaded(loaded, fx),
            Err(failure) => {
                self.on_load_failed(failure, fx);
                let issued = self.issued_on.get(&StructureRequestKind::Definition).copied();
                if issued.is_some_and(|issued| self.session.link_generation() > issued) {
                    self.retry_failed(fx);
                }
            }
        }
    }

    /// The session reconnected: a draft takes the new connection's
    /// dialect, and a read that failed is asked again.
    fn on_link_changed(&mut self, generation: LinkGeneration, fx: &mut StructureEffects) {
        if generation <= self.link_generation {
            return;
        }
        self.link_generation = generation;
        if self.mode() == StructureMode::New {
            self.context.borrow_mut().dialect = self.session.current_dialect();
            self.rebuild_rows();
            self.sync_add_rows();
            self.recompute_dirty_state(fx);
            self.read_character_sets();
        }
        self.retry_failed(fx);
    }

    fn retry_failed(&mut self, fx: &mut StructureEffects) {
        let failed = self.failed.take();
        if failed.contains(&StructureRequestKind::Definition) {
            self.read_definition(fx);
        }
        if failed.contains(&StructureRequestKind::CharacterSets) {
            self.read_character_sets();
        }
    }
}
