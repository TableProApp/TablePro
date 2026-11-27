// The setup guide's rules (core ADR 0057), apart from GTK so the gate and the steps are tested as data.

use std::time::Duration;

use tablepro_foreign_import::{ForeignApp, ForeignSource, SourceAvailability};
use uuid::Uuid;

use crate::i18n::{gettext_f, pgettext};

// An answer later than this would change a choice the user is already reading.
pub(crate) const PROBE_LIMIT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SetupGate {
    pub opened_from_menu: bool,
    pub library_ready: bool,
    pub connections: usize,
    pub seen: bool,
    pub first_picker_window: bool,
}

pub(crate) fn should_show(gate: &SetupGate) -> bool {
    gate.opened_from_menu || (gate.first_picker_window && gate.library_ready && gate.connections == 0 && !gate.seen)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SetupStep {
    Origin,
    Import,
    FirstConnection,
    Options,
}

impl SetupStep {
    #[cfg(test)]
    fn next(self) -> Option<Self> {
        match self {
            Self::Origin => Some(Self::Import),
            Self::Import => Some(Self::FirstConnection),
            Self::FirstConnection => Some(Self::Options),
            Self::Options => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FirstConnectionChoice {
    NewConnection,
    Sample,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SetupEnding {
    Open(Uuid),
    Select(Vec<Uuid>),
    NewConnection,
    Sample,
    Stay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OriginChoice {
    OtherApp,
    ConnectionsFile,
    StartFresh,
}

impl OriginChoice {
    // The file card leaves the guide for the file import, which is no step of the guide.
    pub(crate) fn next_step(self) -> Option<SetupStep> {
        match self {
            Self::OtherApp => Some(SetupStep::Import),
            Self::ConnectionsFile => None,
            Self::StartFresh => Some(SetupStep::FirstConnection),
        }
    }
}

// An app read from a picked file is available on every computer, so it says nothing about this one.
fn apps_with_data(probed: &[ForeignSource]) -> Vec<ForeignApp> {
    probed
        .iter()
        .filter(|source| source.availability == SourceAvailability::Available && !source.picks_file())
        .map(|source| source.app)
        .collect()
}

pub(crate) fn found_subtitle(apps: &[ForeignApp]) -> String {
    let names: Vec<&str> = apps.iter().map(|app| app.display_name()).collect();
    gettext_f("Found on this computer: {apps}", &[("apps", &name_list(&names))])
}

fn name_list(names: &[&str]) -> String {
    match names {
        [] => String::new(),
        [one] => (*one).to_owned(),
        [rest @ .., last] => {
            let rest = rest.join(&pgettext("list separator", ", "));
            // Translators: {names} is one or more names joined by the list separator, {last} the final one.
            gettext_f("{names} and {last}", &[("names", &rest), ("last", last)])
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ImportSource {
    // Another app's own store on this computer: the user's own data.
    ThisComputer,
    // A connections file, a link or an export the user picked, which anyone could have sent.
    FileOrLink,
}

pub(crate) fn import_source(app: ForeignApp) -> ImportSource {
    match app.picked_file_extensions() {
        Some(_) => ImportSource::FileOrLink,
        None => ImportSource::ThisComputer,
    }
}

// Rule 2 of the ending, which an import from a menu applies to its own ids too; a file or link never connects.
pub(crate) fn handoff(ids: &[Uuid], source: ImportSource) -> SetupEnding {
    match (ids, source) {
        ([], _) => SetupEnding::Stay,
        ([one], ImportSource::ThisComputer) => SetupEnding::Open(*one),
        (many, _) => SetupEnding::Select(many.to_vec()),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SetupFlow {
    shown: Vec<SetupStep>,
    origin: OriginChoice,
    origin_chosen: bool,
    found: Vec<ForeignApp>,
    recorded: Option<FirstConnectionChoice>,
    imported: Vec<Uuid>,
    imported_from: ImportSource,
}

impl SetupFlow {
    pub(crate) fn new() -> Self {
        Self {
            shown: vec![SetupStep::Origin],
            origin: OriginChoice::StartFresh,
            origin_chosen: false,
            found: Vec::new(),
            recorded: None,
            imported: Vec::new(),
            imported_from: ImportSource::ThisComputer,
        }
    }

    pub(crate) fn origin(&self) -> OriginChoice {
        self.origin
    }

    pub(crate) fn choose_origin(&mut self, origin: OriginChoice) {
        self.origin = origin;
        self.origin_chosen = true;
    }

    // Pressing the pill chooses the card it runs, even the one selected from the start.
    pub(crate) fn continue_from_origin(&mut self) -> OriginChoice {
        self.origin_chosen = true;
        self.origin
    }

    // Only a suggestion: the user still presses the pill, and a card they chose first stays chosen.
    pub(crate) fn probe_answered(&mut self, elapsed: Duration, probed: &[ForeignSource]) -> bool {
        let found = apps_with_data(probed);
        if elapsed > PROBE_LIMIT || self.origin_chosen || self.shown != [SetupStep::Origin] || found.is_empty() {
            return false;
        }
        self.origin = OriginChoice::OtherApp;
        self.found = found;
        true
    }

    pub(crate) fn found(&self) -> &[ForeignApp] {
        &self.found
    }

    pub(crate) fn step(&self) -> SetupStep {
        self.shown.last().copied().unwrap_or(SetupStep::Origin)
    }

    pub(crate) fn shown(&self) -> &[SetupStep] {
        &self.shown
    }

    pub(crate) fn can_go_back(&self) -> bool {
        self.shown.len() > 1
    }

    pub(crate) fn back(&mut self) {
        if self.can_go_back() {
            self.shown.pop();
        }
    }

    #[cfg(test)]
    pub(crate) fn advance(&mut self) {
        if let Some(next) = self.step().next() {
            self.shown.push(next);
        }
    }

    // The origin's choices go past steps that do not apply to them.
    pub(crate) fn go_to(&mut self, step: SetupStep) {
        if !self.shown.contains(&step) {
            self.shown.push(step);
        }
    }

    pub(crate) fn record(&mut self, choice: FirstConnectionChoice) {
        self.recorded = Some(choice);
    }

    #[cfg(test)]
    pub(crate) fn recorded(&self) -> Option<FirstConnectionChoice> {
        self.recorded
    }

    // One connection written from a picked export makes the whole ending a selection.
    pub(crate) fn add_imported(&mut self, ids: &[Uuid], source: ImportSource) {
        if source == ImportSource::FileOrLink && !ids.is_empty() {
            self.imported_from = ImportSource::FileOrLink;
        }
        for id in ids {
            if !self.imported.contains(id) {
                self.imported.push(*id);
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn imported(&self) -> &[Uuid] {
        &self.imported
    }

    pub(crate) fn end(&self) -> SetupEnding {
        match self.recorded {
            Some(FirstConnectionChoice::NewConnection) => SetupEnding::NewConnection,
            Some(FirstConnectionChoice::Sample) => SetupEnding::Sample,
            None => handoff(&self.imported, self.imported_from),
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_foreign_import::{Inventory, PasswordOffer, UnreadableReason};

    use super::*;

    fn launch(library_ready: bool, connections: usize, seen: bool, first_picker_window: bool) -> SetupGate {
        SetupGate {
            opened_from_menu: false,
            library_ready,
            connections,
            seen,
            first_picker_window,
        }
    }

    // The Linux rows of ADR 0057's gate table, by their numbers there.
    #[test]
    fn the_gate_follows_the_linux_rows_of_the_table() {
        let rows = [
            ("G1", launch(true, 0, false, true), true),
            ("G2", launch(true, 0, true, true), false),
            ("G3", launch(true, 1, false, true), false),
            ("G3 sample", launch(true, 1, false, true), false),
            ("G4 loading", launch(false, 0, false, true), false),
            ("G4 unreadable", launch(false, 3, false, true), false),
            ("G5 groups only", launch(true, 0, false, true), true),
            ("G11", launch(true, 0, false, false), false),
        ];
        for (row, gate, shows) in rows {
            assert_eq!(should_show(&gate), shows, "{row}");
        }
    }

    #[test]
    fn the_menu_opens_the_guide_whatever_the_library_holds() {
        for (library_ready, connections, seen, first) in
            [(true, 0, false, true), (true, 4, true, false), (false, 0, true, false)]
        {
            let gate = SetupGate {
                opened_from_menu: true,
                ..launch(library_ready, connections, seen, first)
            };
            assert!(should_show(&gate), "G6 with {gate:?}");
        }
    }

    fn source(app: ForeignApp, availability: SourceAvailability) -> ForeignSource {
        ForeignSource {
            app,
            availability,
            inventory: Inventory::default(),
            password_offer: PasswordOffer::DecryptedWhileReading,
            offers_saved_queries: false,
        }
    }

    // Two apps that keep their data in their own store, and one the user picks an export file for.
    fn apps() -> (ForeignApp, ForeignApp, ForeignApp) {
        let mut stores = ForeignApp::ALL
            .into_iter()
            .filter(|app| app.picked_file_extensions().is_none());
        let picked = ForeignApp::ALL
            .into_iter()
            .find(|app| app.picked_file_extensions().is_some());
        match (stores.next(), stores.next(), picked) {
            (Some(first), Some(second), Some(picked)) => (first, second, picked),
            _ => panic!("the apps the tests need"),
        }
    }

    #[test]
    fn the_probe_selects_another_app_on_the_origin_and_names_the_apps_it_found() {
        let (first, second, picked) = apps();
        let unreadable = SourceAvailability::Unreadable(UnreadableReason {
            code: "foreign_import.parse",
            detail: "bad".to_owned(),
        });
        let probed = [
            source(first, SourceAvailability::Available),
            source(picked, SourceAvailability::Available),
            source(second, SourceAvailability::Available),
        ];
        let mut flow = SetupFlow::new();
        assert_eq!(flow.origin(), OriginChoice::StartFresh);

        assert!(flow.probe_answered(Duration::from_millis(300), &probed));
        assert_eq!(flow.origin(), OriginChoice::OtherApp);
        assert_eq!(flow.shown(), [SetupStep::Origin], "the probe left the origin");
        assert_eq!(flow.found(), [first, second], "an export file the user picks was named");
        assert_eq!(
            found_subtitle(flow.found()),
            format!(
                "Found on this computer: {} and {}",
                first.display_name(),
                second.display_name()
            )
        );
        assert_eq!(flow.continue_from_origin().next_step(), Some(SetupStep::Import));

        let mut nothing = SetupFlow::new();
        let none_with_data = [
            source(first, SourceAvailability::NotFound),
            source(picked, SourceAvailability::Available),
            source(second, unreadable),
        ];
        assert!(
            !nothing.probe_answered(Duration::from_millis(300), &none_with_data),
            "data that is missing or cannot be read is no app with data"
        );
        assert_eq!(nothing.origin(), OriginChoice::StartFresh);
        assert!(nothing.found().is_empty());
    }

    #[test]
    fn the_found_apps_read_as_a_sentence() {
        let (first, second, third) = apps();
        let name = |app: ForeignApp| app.display_name();
        assert_eq!(
            found_subtitle(&[first]),
            format!("Found on this computer: {}", name(first))
        );
        assert_eq!(
            found_subtitle(&[first, second, third]),
            format!(
                "Found on this computer: {}, {} and {}",
                name(first),
                name(second),
                name(third)
            )
        );
    }

    #[test]
    fn a_choice_the_user_made_first_is_kept() {
        let (first, _, _) = apps();
        let probed = [source(first, SourceAvailability::Available)];
        let mut chosen = SetupFlow::new();
        chosen.choose_origin(OriginChoice::ConnectionsFile);
        assert!(!chosen.probe_answered(Duration::from_millis(300), &probed));
        assert_eq!(chosen.origin(), OriginChoice::ConnectionsFile);
        assert!(chosen.found().is_empty(), "the probe named apps over the user's choice");

        let mut kept_the_first_card = SetupFlow::new();
        kept_the_first_card.choose_origin(OriginChoice::StartFresh);
        assert!(!kept_the_first_card.probe_answered(Duration::from_millis(300), &probed));
        assert_eq!(kept_the_first_card.origin(), OriginChoice::StartFresh);

        let mut went_on = SetupFlow::new();
        let next = went_on.continue_from_origin().next_step();
        assert_eq!(next, Some(SetupStep::FirstConnection));
        went_on.go_to(SetupStep::FirstConnection);
        went_on.back();
        assert!(
            !went_on.probe_answered(Duration::from_millis(300), &probed),
            "the card the pill ran was replaced after Back"
        );
        assert_eq!(went_on.origin(), OriginChoice::StartFresh);
    }

    #[test]
    fn a_late_probe_answer_does_nothing() {
        let (first, _, _) = apps();
        let probed = [source(first, SourceAvailability::Available)];
        let mut flow = SetupFlow::new();
        let before = flow.clone();
        assert!(!flow.probe_answered(PROBE_LIMIT + Duration::from_millis(1), &probed));
        assert_eq!(flow, before);

        let mut at_the_limit = SetupFlow::new();
        assert!(at_the_limit.probe_answered(PROBE_LIMIT, &probed));
    }

    #[test]
    fn the_origin_cards_lead_to_their_steps() {
        assert_eq!(OriginChoice::OtherApp.next_step(), Some(SetupStep::Import));
        assert_eq!(OriginChoice::ConnectionsFile.next_step(), None);
        assert_eq!(OriginChoice::StartFresh.next_step(), Some(SetupStep::FirstConnection));
    }

    #[test]
    fn steps_go_forward_in_order_and_back_only_from_the_second_shown() {
        let mut flow = SetupFlow::new();
        assert!(!flow.can_go_back());
        flow.back();
        assert_eq!(flow.step(), SetupStep::Origin);

        for step in [SetupStep::Import, SetupStep::FirstConnection, SetupStep::Options] {
            flow.advance();
            assert_eq!(flow.step(), step);
        }
        flow.advance();
        assert_eq!(flow.step(), SetupStep::Options, "the last step has no next");
        flow.back();
        assert_eq!(flow.step(), SetupStep::FirstConnection);
    }

    #[test]
    fn the_origin_can_go_past_import_and_back_returns_to_it() {
        let mut flow = SetupFlow::new();
        flow.go_to(SetupStep::FirstConnection);
        assert_eq!(flow.shown(), [SetupStep::Origin, SetupStep::FirstConnection]);
        flow.back();
        assert_eq!(flow.step(), SetupStep::Origin);
    }

    #[test]
    fn the_ending_runs_the_recorded_choice_first_then_the_imported_ids() {
        let (first, second) = (Uuid::new_v4(), Uuid::new_v4());
        let mut flow = SetupFlow::new();
        assert_eq!(flow.end(), SetupEnding::Stay);

        flow.add_imported(&[first], ImportSource::ThisComputer);
        assert_eq!(flow.end(), SetupEnding::Open(first));
        flow.add_imported(&[first, second], ImportSource::ThisComputer);
        assert_eq!(
            flow.imported(),
            [first, second],
            "an id written twice is one connection"
        );
        assert_eq!(flow.end(), SetupEnding::Select(vec![first, second]));

        flow.record(FirstConnectionChoice::Sample);
        assert_eq!(flow.end(), SetupEnding::Sample);
        flow.record(FirstConnectionChoice::NewConnection);
        assert_eq!(flow.recorded(), Some(FirstConnectionChoice::NewConnection));
        assert_eq!(flow.end(), SetupEnding::NewConnection);
    }

    #[test]
    fn an_import_from_another_app_hands_off_by_how_many_it_wrote() {
        let ids = [Uuid::new_v4(), Uuid::new_v4()];
        assert_eq!(handoff(&[], ImportSource::ThisComputer), SetupEnding::Stay);
        assert_eq!(
            handoff(&ids[..1], ImportSource::ThisComputer),
            SetupEnding::Open(ids[0])
        );
        assert_eq!(
            handoff(&ids, ImportSource::ThisComputer),
            SetupEnding::Select(ids.to_vec())
        );
    }

    #[test]
    fn a_file_or_link_import_shows_what_it_wrote_and_never_opens_it() {
        let ids = [Uuid::new_v4(), Uuid::new_v4()];
        assert_eq!(handoff(&[], ImportSource::FileOrLink), SetupEnding::Stay);
        assert_eq!(
            handoff(&ids[..1], ImportSource::FileOrLink),
            SetupEnding::Select(vec![ids[0]])
        );
        assert_eq!(
            handoff(&ids, ImportSource::FileOrLink),
            SetupEnding::Select(ids.to_vec())
        );
    }

    #[test]
    fn only_an_app_read_from_a_picked_export_counts_as_a_file() {
        let (picked, stores): (Vec<ForeignApp>, Vec<ForeignApp>) = ForeignApp::ALL
            .into_iter()
            .partition(|app| app.picked_file_extensions().is_some());
        assert!(!picked.is_empty() && !stores.is_empty());
        for app in &picked {
            assert_eq!(import_source(*app), ImportSource::FileOrLink, "{app:?}");
        }
        for app in &stores {
            assert_eq!(import_source(*app), ImportSource::ThisComputer, "{app:?}");
        }

        let id = Uuid::new_v4();
        assert_eq!(handoff(&[id], import_source(picked[0])), SetupEnding::Select(vec![id]));
        assert_eq!(handoff(&[id], import_source(stores[0])), SetupEnding::Open(id));
    }

    #[test]
    fn a_connection_from_a_picked_export_makes_the_guide_select_instead_of_open() {
        let (first, second) = (Uuid::new_v4(), Uuid::new_v4());
        let mut picked = SetupFlow::new();
        picked.add_imported(&[first], ImportSource::FileOrLink);
        assert_eq!(picked.end(), SetupEnding::Select(vec![first]));

        let mut mixed = SetupFlow::new();
        mixed.add_imported(&[first], ImportSource::ThisComputer);
        mixed.add_imported(&[second], ImportSource::FileOrLink);
        assert_eq!(mixed.end(), SetupEnding::Select(vec![first, second]));

        let mut empty_export = SetupFlow::new();
        empty_export.add_imported(&[first], ImportSource::ThisComputer);
        empty_export.add_imported(&[], ImportSource::FileOrLink);
        assert_eq!(
            empty_export.end(),
            SetupEnding::Open(first),
            "an export that wrote nothing changes nothing"
        );
    }
}
