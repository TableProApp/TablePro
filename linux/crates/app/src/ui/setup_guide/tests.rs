use std::time::Duration;

use tablepro_foreign_import::{ForeignPlatform, Inventory, PasswordOffer};
use tablepro_storage::StoragePaths;

use super::*;
use crate::services::setup_guide::PROBE_LIMIT;
use crate::test_support::{MemorySettings, OwnedWindow, assert_labelled, descendants, test_runtime, wait_until};
use crate::ui::import_from_app::tests::{dbeaver_home, drivers};

const WAIT: Duration = Duration::from_secs(30);
const IMPORT_REVIEW: &str = "import-review";

struct Guide {
    _runtime: crate::runtime::AppRuntime,
    _root: tempfile::TempDir,
    settings: MemorySettings,
    guide: SetupGuide,
    ended: Rc<RefCell<Vec<SetupEnding>>>,
    imported: Rc<RefCell<Vec<usize>>>,
    files: Rc<Cell<usize>>,
    window: OwnedWindow<adw::Window>,
}

impl Guide {
    // A home where another app keeps connections, or an empty one.
    fn new(with_an_app: bool) -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let root = tempfile::tempdir().expect("a temporary folder");
        let dirs = if with_an_app {
            dbeaver_home(root.path())
        } else {
            ForeignAppDirs::conventional(ForeignPlatform::Linux, &root.path().join("home"))
        };
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let settings = MemorySettings::new();
        let ended = Rc::new(RefCell::new(Vec::new()));
        let imported = Rc::new(RefCell::new(Vec::new()));
        let files = Rc::new(Cell::new(0));
        let (ends, sink, picked) = (ended.clone(), imported.clone(), files.clone());
        let guide = SetupGuide::new(SetupGuideInit {
            dirs,
            drivers: drivers(),
            connections: ConnectionStore::new(&paths),
            tasks: runtime.tasks(),
            settings: settings.get().clone(),
            on_import: Box::new(move |_review, plan, done| {
                sink.borrow_mut().push(plan.connections().len());
                // A plan's new rows hold the nil id until the write gives each its own.
                done(plan.connections().iter().map(|_| Uuid::new_v4()).collect());
            }),
            on_import_file: Box::new(move || picked.set(picked.get() + 1)),
            on_end: Box::new(move |ending| ends.borrow_mut().push(ending)),
        });
        let window = OwnedWindow::new(adw::Window::new());
        window.set_default_size(800, 800);
        window.set_content(Some(&guide));
        window.present();
        guide.start();
        Self {
            _runtime: runtime,
            _root: root,
            settings,
            guide,
            ended,
            imported,
            files,
            window,
        }
    }

    fn imp(&self) -> &imp::SetupGuide {
        self.guide.imp()
    }

    fn page(&self) -> Option<String> {
        self.imp()
            .navigation
            .visible_page()
            .and_then(|page| page.tag())
            .map(|tag| tag.to_string())
    }

    fn stack(&self) -> Vec<String> {
        let stack = self.imp().navigation.navigation_stack();
        (0..stack.n_items())
            .filter_map(|at| stack.item(at).and_downcast::<adw::NavigationPage>())
            .filter_map(|page| page.tag().map(|tag| tag.to_string()))
            .collect()
    }

    fn flow(&self) -> SetupFlow {
        self.guide
            .parts()
            .map(|parts| parts.flow.borrow().clone())
            .expect("the guide's flow")
    }

    fn source_check(&self, counted: bool) -> gtk::CheckButton {
        self.guide
            .parts()
            .and_then(|parts| {
                parts
                    .sources
                    .borrow()
                    .iter()
                    .find(|source| source.row.is_sensitive() && (source.connections > 0) == counted)
                    .map(|source| source.check.clone())
            })
            .expect("a source row")
    }

    fn default_widget(&self) -> Option<gtk::Widget> {
        self.window.default_widget()
    }

    fn other_app_subtitle(&self) -> Option<String> {
        self.imp().from_app_row.subtitle().map(|subtitle| subtitle.to_string())
    }

    // The probe only selects the other-app card; the pill goes on to the list.
    fn to_import(&self) {
        wait_until(WAIT, || self.imp().from_app_check.is_active()).expect("the probe to select the other-app card");
        assert_eq!(self.page().as_deref(), Some(ORIGIN), "the probe left the origin");
        self.imp().origin_continue.emit_clicked();
        assert_eq!(self.page().as_deref(), Some(IMPORT));
        wait_until(WAIT, || {
            self.imp().import_stack.visible_child_name().as_deref() == Some("sources")
        })
        .expect("the apps with their counts");
    }

    fn import_button(&self) -> gtk::Button {
        descendants(&self.guide)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some("_Import") && button.is_mapped())
            .expect("the review's Import button")
    }
}

// As a click does: the row hands the activation to its radio, which selects the card.
fn activate(row: &adw::ActionRow) {
    ActionRowExt::activate(row);
}

#[gtk4::test]
fn with_no_app_found_the_guide_starts_on_the_origin_and_records_the_sample_for_the_end() {
    let guide = Guide::new(false);
    let selected = wait_until(Duration::from_millis(500), || guide.imp().from_app_check.is_active());
    assert!(selected.is_err(), "the other-app card was selected with no app found");
    assert!(guide.imp().start_check.is_active());
    assert_eq!(guide.page().as_deref(), Some(ORIGIN));
    assert!(!guide.flow().can_go_back());

    activate(&guide.imp().start_row);
    guide.imp().origin_continue.emit_clicked();
    assert_eq!(guide.page().as_deref(), Some(FIRST_CONNECTION));
    assert_eq!(
        guide.stack(),
        [ORIGIN, FIRST_CONNECTION],
        "the import step was not passed over"
    );
    assert!(
        guide.imp().navigation.pop(),
        "the first connection step could not go back"
    );
    assert_eq!(guide.flow().step(), SetupStep::Origin, "Back did not reach the flow");

    activate(&guide.imp().start_row);
    guide.imp().origin_continue.emit_clicked();
    guide.imp().sample_check.set_active(true);
    guide.imp().first_continue.emit_clicked();
    assert_eq!(guide.page().as_deref(), Some(OPTIONS));
    assert!(
        guide.ended.borrow().is_empty(),
        "the sample opened before the guide ended"
    );
    assert_eq!(
        guide.imp().finish_button.label().as_deref(),
        Some("_Open Sample"),
        "the last button does not say what it runs"
    );

    guide.imp().finish_button.emit_clicked();
    guide.imp().options_skip.emit_clicked();
    assert_eq!(
        *guide.ended.borrow(),
        [SetupEnding::Sample],
        "the guide ended other than once"
    );
}

#[gtk4::test]
fn an_app_found_at_launch_is_selected_on_the_origin_and_its_ids_decide_the_end() {
    let guide = Guide::new(true);
    wait_until(WAIT, || guide.imp().from_app_check.is_active()).expect("the probe to select the other-app card");
    assert_eq!(guide.page().as_deref(), Some(ORIGIN), "the probe left the origin");
    let found = guide.flow().found().to_vec();
    assert!(!found.is_empty(), "the probe named no app");
    let subtitle = guide.other_app_subtitle().unwrap_or_default();
    assert_eq!(subtitle, found_subtitle(&found));
    for app in &found {
        assert!(
            subtitle.contains(app.display_name()),
            "{subtitle} does not name {app:?}"
        );
    }

    guide.to_import();
    assert!(
        guide.flow().can_go_back(),
        "the import step cannot go back to the origin"
    );
    let ticked: Vec<ForeignApp> = guide
        .guide
        .parts()
        .map(|parts| {
            parts
                .sources
                .borrow()
                .iter()
                .filter(|source| source.check.is_active())
                .map(|source| source.app)
                .collect()
        })
        .unwrap_or_default();
    assert_eq!(
        ticked,
        [ForeignApp::DBeaver],
        "only an app with connections starts ticked"
    );

    guide.imp().import_continue.emit_clicked();
    wait_until(WAIT, || guide.page().as_deref() == Some(IMPORT_REVIEW)).expect("the review");
    assert_eq!(
        guide.stack(),
        [ORIGIN, IMPORT, IMPORT_REVIEW],
        "Back from the review leaves the guide"
    );

    guide.import_button().emit_clicked();
    wait_until(WAIT, || guide.page().as_deref() == Some(FIRST_CONNECTION)).expect("the next step");
    assert_eq!(*guide.imported.borrow(), [2]);
    assert_eq!(
        guide.stack(),
        [ORIGIN, IMPORT, FIRST_CONNECTION],
        "the import pages stayed under the step"
    );

    guide.imp().first_continue.emit_clicked();
    assert_eq!(guide.imp().finish_button.label().as_deref(), Some("_Show Connections"));
    guide.imp().options_skip.emit_clicked();
    let ended = guide.ended.borrow();
    assert!(
        matches!(ended.as_slice(), [SetupEnding::Select(ids)] if ids.len() == 2),
        "Skip did not run the ending: {ended:?}"
    );
}

#[gtk4::test]
fn skip_on_the_first_connection_step_runs_the_choice_made_there() {
    let guide = Guide::new(false);
    activate(&guide.imp().start_row);
    guide.imp().origin_continue.emit_clicked();
    assert_eq!(guide.page().as_deref(), Some(FIRST_CONNECTION));

    guide.imp().sample_check.set_active(true);
    guide.imp().new_connection_check.set_active(true);
    guide.imp().first_skip.emit_clicked();

    assert_eq!(
        *guide.ended.borrow(),
        [SetupEnding::NewConnection],
        "Skip ran another choice than the one shown"
    );
}

#[gtk4::test]
fn skip_on_the_first_step_ends_with_nothing_to_run() {
    let guide = Guide::new(false);

    guide.imp().origin_skip.emit_clicked();

    assert_eq!(*guide.ended.borrow(), [SetupEnding::Stay]);
}

#[gtk4::test]
fn a_tablepro_file_leaves_the_guide_for_the_file_import() {
    let guide = Guide::new(false);

    activate(&guide.imp().from_file_row);
    assert!(
        guide.imp().from_file_check.is_active(),
        "the file card was not selected"
    );
    assert_eq!(guide.files.get(), 0, "selecting the card left the guide");
    guide.imp().origin_continue.emit_clicked();
    activate(&guide.imp().start_row);
    guide.imp().origin_continue.emit_clicked();

    assert_eq!(guide.files.get(), 1);
    assert!(guide.ended.borrow().is_empty());
    assert_eq!(
        guide.page().as_deref(),
        Some(ORIGIN),
        "the guide went on after it was left"
    );
}

#[gtk4::test]
fn the_options_apply_at_once_and_every_control_is_named() {
    let guide = Guide::new(false);
    let imp = guide.imp();

    imp.vim_row.set_active(true);
    assert!(guide.settings.get().vim_keybindings());
    let model = imp.shortcuts_row.model().expect("the presets");
    assert!(model.n_items() > 1, "no preset is offered");
    imp.shortcuts_row.set_selected(1);
    assert_ne!(guide.settings.get().shortcut_preset(), "tablepro");

    for row in [&imp.from_app_row.get(), &imp.from_file_row.get(), &imp.start_row.get()] {
        assert_labelled(row).unwrap_or_else(|problem| panic!("{problem:?}"));
    }
    assert_labelled(&imp.shortcuts_row.get()).unwrap_or_else(|problem| panic!("{problem:?}"));
    assert_labelled(&imp.vim_row.get()).unwrap_or_else(|problem| panic!("{problem:?}"));
    assert_labelled(&imp.system_style_row.get()).unwrap_or_else(|problem| panic!("{problem:?}"));
}

#[gtk4::test]
fn the_import_pill_counts_the_connections_of_the_ticked_apps() {
    let guide = Guide::new(true);
    guide.to_import();
    let cards = guide
        .guide
        .parts()
        .map(|parts| parts.sources.borrow().len())
        .unwrap_or_default();
    let apps = ForeignApp::ALL
        .into_iter()
        .filter(|app| app.runs_on(ForeignPlatform::Linux))
        .count();
    assert!(cards < apps, "an app that is not there got a card");
    assert!(
        guide.imp().not_found_label.is_visible(),
        "the apps not found are not named"
    );
    let label = || guide.imp().import_continue.label().map(|label| label.to_string());
    assert_eq!(label().as_deref(), Some("_Import 3 Connections"));

    guide.source_check(true).set_active(false);
    assert_eq!(label().as_deref(), Some("_Continue"));
    guide.source_check(false).set_active(true);
    assert_eq!(
        label().as_deref(),
        Some("_Import"),
        "an app with no count promised a number"
    );
    guide.source_check(true).set_active(true);
    assert_eq!(label().as_deref(), Some("_Import 3 Connections"));
    assert_eq!(import_label(1, 1), "_Import 1 Connection");
}

#[gtk4::test]
fn return_runs_the_step_pill_and_never_reaches_under_a_pushed_import_page() {
    let guide = Guide::new(true);
    wait_until(WAIT, || guide.imp().from_app_check.is_active()).expect("the probe to select the other-app card");
    assert_eq!(
        guide.default_widget(),
        Some(guide.imp().origin_continue.get().upcast()),
        "the origin's pill is not the default"
    );

    guide.to_import();
    assert_eq!(
        guide.default_widget(),
        Some(guide.imp().import_continue.get().upcast()),
        "the import step's pill is not the default"
    );

    guide.imp().import_continue.emit_clicked();
    wait_until(WAIT, || guide.page().as_deref() == Some(IMPORT_REVIEW)).expect("the review");
    assert_eq!(guide.default_widget(), None, "Return reaches the step under the review");

    guide.import_button().emit_clicked();
    wait_until(WAIT, || guide.page().as_deref() == Some(FIRST_CONNECTION)).expect("the next step");
    assert_eq!(
        guide.default_widget(),
        Some(guide.imp().first_continue.get().upcast()),
        "the next step's pill is not the default"
    );
}

fn found_on_this_computer() -> Vec<ForeignSource> {
    ForeignApp::ALL
        .into_iter()
        .filter(|app| app.runs_on(ForeignPlatform::Linux) && app.picked_file_extensions().is_none())
        .take(2)
        .map(|app| ForeignSource {
            app,
            availability: SourceAvailability::Available,
            inventory: Inventory::default(),
            password_offer: PasswordOffer::DecryptedWhileReading,
            offers_saved_queries: false,
        })
        .collect()
}

// The home is empty, so the launch's own probe finds nothing and the answer given here is the only one.
#[gtk4::test]
fn the_probe_keeps_a_card_the_user_selected_first_and_ignores_a_late_answer() {
    let found = found_on_this_computer();
    let apps: Vec<ForeignApp> = found.iter().map(|source| source.app).collect();
    assert_eq!(apps.len(), 2, "two apps that keep their own data on Linux");

    let untouched = Guide::new(false);
    let shipped = untouched.other_app_subtitle();
    untouched.guide.probe_answered(Ok(found.clone()));
    assert!(untouched.imp().from_app_check.is_active());
    assert_eq!(untouched.page().as_deref(), Some(ORIGIN), "the probe left the origin");
    assert_eq!(untouched.other_app_subtitle(), Some(found_subtitle(&apps)));

    let kept_start = Guide::new(false);
    activate(&kept_start.imp().start_row);
    kept_start.guide.probe_answered(Ok(found.clone()));
    assert!(
        kept_start.imp().start_check.is_active(),
        "the probe replaced the card the user selected again"
    );
    assert_eq!(kept_start.other_app_subtitle(), shipped);

    let kept_file = Guide::new(false);
    activate(&kept_file.imp().from_file_row);
    kept_file.guide.probe_answered(Ok(found.clone()));
    assert!(
        kept_file.imp().from_file_check.is_active(),
        "the probe replaced the card the user selected"
    );
    assert_eq!(kept_file.files.get(), 0, "selecting the card left the guide");

    let late = Guide::new(false);
    if let Some(parts) = late.guide.parts() {
        parts
            .opened
            .set(Instant::now().checked_sub(PROBE_LIMIT + Duration::from_secs(1)));
    }
    late.guide.probe_answered(Ok(found));
    assert!(late.imp().start_check.is_active(), "a late answer changed the card");
    assert_eq!(late.other_app_subtitle(), shipped);
}
