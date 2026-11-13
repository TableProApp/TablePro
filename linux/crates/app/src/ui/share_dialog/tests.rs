use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{TimeDelta, Utc};
use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_account::{
    Account, AccountSettings, AccountStatus, AppClient, BrowserLauncher, CallbackPage, DeviceDescription, Endpoints,
    MachineId, Url, fakes,
};
use tablepro_core::Value;
use tablepro_core::column::{ColumnType, ResultColumn};
use tokio::sync::watch;

use super::*;
use crate::runtime::AppRuntime;
use crate::services::grid::RowSnapshot;
use crate::services::share_subject::SharedRows;
use crate::test_support::{
    Approving, CloudStub, MemoryKeyring, OwnedWindow, assert_labelled, descendants, finish_on_main, test_runtime,
    unlabelled_icon_buttons, wait_until,
};

const WAIT: Duration = Duration::from_secs(20);
const URL: &str = "https://s.tablepro.app/Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";

struct Cloud {
    pro: bool,
    max_rows: u64,
    live: AtomicU64,
    verified: AtomicBool,
    disabled: AtomicBool,
    offline: AtomicBool,
    hold_limits: AtomicBool,
    hold_create: AtomicBool,
    create: Mutex<(u16, String)>,
    // What a create changes on the server before it answers.
    after_create: Mutex<Option<fn(&Cloud)>>,
    teams: Mutex<String>,
    suspended: AtomicBool,
}

impl Cloud {
    fn free(live: u64) -> Self {
        Self {
            pro: false,
            max_rows: 1_000,
            live: AtomicU64::new(live),
            verified: AtomicBool::new(true),
            disabled: AtomicBool::new(false),
            offline: AtomicBool::new(false),
            hold_limits: AtomicBool::new(false),
            hold_create: AtomicBool::new(false),
            create: Mutex::new((201, created(URL))),
            after_create: Mutex::new(None),
            teams: Mutex::new("[]".to_owned()),
            suspended: AtomicBool::new(false),
        }
    }

    fn limits(&self) -> String {
        let (plan, limit, expiries, default) = match self.pro {
            true => ("pro", 1_000, r#"["1d","7d","30d","never"]"#, "never"),
            false => ("free", 5, r#"["1d","7d","30d"]"#, "30d"),
        };
        format!(
            r#"{{"plan":"{plan}","live":{},"live_limit":{limit},"max_rows":{},"expiries":{expiries},"default_expiry":"{default}","password":{pro},"disable_download":{pro},"team":{pro},"email_verified":{},"sharing_disabled":{},"teams":{}}}"#,
            self.live.load(Ordering::SeqCst),
            self.max_rows,
            self.verified.load(Ordering::SeqCst),
            self.disabled.load(Ordering::SeqCst),
            self.teams.lock().expect("the teams"),
            pro = self.pro,
        )
    }

    fn answer(&self, method: &str, path: &str) -> Option<(u16, String)> {
        match (method, path) {
            ("GET", "/v2/share-limits") => {
                wait_out(&self.hold_limits);
                // Not an HTTP status, so the client sees no answer it can read, as offline.
                Some(match self.offline.load(Ordering::SeqCst) {
                    true => (0, String::new()),
                    false => (200, self.limits()),
                })
            }
            ("GET", "/v2/shares") => Some((
                200,
                format!(
                    r#"{{"data":[{},{}]}}"#,
                    view_of("shr_new", "Newest", 1, self.suspended.load(Ordering::SeqCst)),
                    view("shr_old", "Oldest", 9)
                ),
            )),
            ("POST", "/v2/shares") => {
                wait_out(&self.hold_create);
                if let Some(change) = *self.after_create.lock().expect("the change") {
                    change(self);
                }
                Some(self.create.lock().expect("the create answer").clone())
            }
            ("DELETE", "/v2/shares/shr_old") => {
                self.live.fetch_sub(1, Ordering::SeqCst);
                Some((204, String::new()))
            }
            _ => None,
        }
    }
}

// The stub serves each request on a thread of its own, so a held answer holds only its request.
fn wait_out(hold: &AtomicBool) {
    while hold.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn view(id: &str, title: &str, days_ago: i64) -> String {
    view_of(id, title, days_ago, false)
}

fn view_of(id: &str, title: &str, days_ago: i64, suspended: bool) -> String {
    let at = (Utc::now() - TimeDelta::days(days_ago)).to_rfc3339();
    format!(
        r#"{{"id":"{id}","kind":"query","scope":"account","title":"{title}","note":"","dialect":"postgres","has_snapshot":false,"hide_sql":false,"allow_download":true,"has_password":false,"state":"live","suspended":{suspended},"view_count":0,"created_at":"{at}","updated_at":"{at}"}}"#
    )
}

fn created(url: &str) -> String {
    format!(
        r#"{{"share":{},"token":"Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK","url":"{url}"}}"#,
        view("shr_made", "Orders", 0)
    )
}

// Opens nothing, so a sign-in waits until it is canceled.
struct Silent;

#[async_trait::async_trait]
impl BrowserLauncher for Silent {
    async fn open(&self, _url: &Url) -> Result<(), String> {
        Ok(())
    }
}

fn problem(status: u16, code: &str) -> (u16, String) {
    (
        status,
        format!(r#"{{"type":"about:blank","title":"Refused","status":{status},"code":"{code}"}}"#),
    )
}

fn stub(machine: &MachineId, cloud: Arc<Cloud>) -> CloudStub {
    let mut claims = fakes::claims(Utc::now(), TimeDelta::days(14), &[]);
    claims.mid = machine.as_str().to_owned();
    claims.dev = "dev_here".to_owned();
    let entitlement = format!(
        r#"{{"token":"{}","expires_at":"2026-11-12T00:00:00Z","refresh_after":"2026-10-30T00:00:00Z"}}"#,
        fakes::sign(&claims).expect("a token")
    );
    let device = format!(
        r#"{{"id":"dev_here","machine_id":"{}","platform":"linux","name":"Ada's laptop","app_version":"0.1.0","os_version":"Ubuntu 26.04","created_at":"2026-10-29T00:00:00Z","last_seen_at":"2026-10-29T00:00:00Z"}}"#,
        machine.as_str()
    );
    let tokens =
        r#"{"access_token":"stub-access","token_type":"Bearer","expires_in":3600,"refresh_token":"stub-refresh"}"#;
    CloudStub::start(move |method, path| {
        if let Some(answer) = cloud.answer(method, path) {
            return answer;
        }
        match (method, path) {
            ("POST", "/oauth/token") => (200, tokens.to_owned()),
            ("POST", "/v2/devices") => (201, device.clone()),
            ("POST", "/v2/devices/dev_here/entitlement") => (200, entitlement.clone()),
            _ => (404, String::new()),
        }
    })
}

struct Harness {
    window: OwnedWindow<adw::Window>,
    dialog: ShareDialog,
    stub: CloudStub,
    cloud: Arc<Cloud>,
    _runtime: AppRuntime,
    _dir: tempfile::TempDir,
}

impl Harness {
    fn new(cloud: Cloud, subject: ShareSubject, sign_in: bool) -> Self {
        Self::with_browser(cloud, subject, sign_in, Arc::new(Approving))
    }

    fn with_browser(cloud: Cloud, subject: ShareSubject, sign_in: bool, browser: Arc<dyn BrowserLauncher>) -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
        let cloud = Arc::new(cloud);
        let stub = stub(&machine, cloud.clone());
        let (status, receiver) = watch::channel(AccountStatus::SignedOut);
        let account = Account::new(
            settings(&stub, machine, &dir),
            Arc::new(MemoryKeyring::default()),
            browser,
            status,
        )
        .expect("an account");
        if sign_in {
            let signing_in = account.clone();
            finish_on_main(
                WAIT,
                runtime
                    .tasks()
                    .spawn_task(async move { signing_in.sign_in(std::future::pending()).await }),
            )
            .expect("the sign-in finished")
            .expect("the task ran")
            .expect("signed in");
        }
        let handle = AccountHandle {
            status: receiver,
            start: watch::channel(AccountStart::Ready(account)).1,
            portal: stub.url.clone(),
        };
        let window = OwnedWindow::presented(adw::Window::builder().default_width(720).default_height(800).build());
        let dialog = ShareDialog::new(ShareDialogInit {
            subject,
            account: handle,
            tasks: runtime.tasks(),
            telemetry: Telemetry::default(),
        });
        dialog.present(Some(&*window));
        let harness = Self {
            window,
            dialog,
            stub,
            cloud,
            _runtime: runtime,
            _dir: dir,
        };
        harness.settle();
        harness
    }

    fn settle(&self) {
        let _ = wait_until(Duration::from_millis(50), || false);
        crate::test_support::drain_main_context();
    }

    fn page(&self) -> Option<SheetPage> {
        self.dialog.page()
    }

    fn wait_for(&self, wanted: impl Fn(&SheetPage) -> bool) {
        wait_until(WAIT, || self.page().as_ref().is_some_and(&wanted))
            .unwrap_or_else(|_| panic!("the sheet stayed on {:?}", self.page()));
    }

    fn chrome(&self) -> &Chrome {
        self.dialog.imp().chrome.get().expect("the chrome")
    }

    fn content(&self) -> gtk::Widget {
        self.chrome().toolbar.content().expect("a page")
    }

    fn buttons(&self, label: &str) -> Vec<gtk::Button> {
        descendants(&self.content())
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .filter(|button| button.label().is_some_and(|text| text == label))
            .collect()
    }

    fn row_titles(&self) -> Vec<String> {
        descendants(&self.content())
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::PreferencesRow>().ok())
            .map(|row| row.title().to_string())
            .collect()
    }

    fn requested(&self, wanted: &str) -> usize {
        self.stub.requests().iter().filter(|request| *request == wanted).count()
    }

    fn entry(&self, title: &str) -> adw::EntryRow {
        descendants(&self.content())
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::EntryRow>().ok())
            .find(|row| row.title() == title)
            .unwrap_or_else(|| panic!("no {title} field"))
    }

    fn posts(&self) -> usize {
        self.stub
            .requests()
            .iter()
            .filter(|request| *request == "POST /v2/shares")
            .count()
    }

    fn audit(&self) {
        let content = self.content();
        for row in descendants(&content)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::PreferencesRow>().ok())
        {
            assert_labelled(&row).unwrap_or_else(|problem| panic!("{}: {problem}", row.title()));
        }
        // libadwaita names a password row's peek button with a tooltip alone (testing.md, Application tests).
        let peeks: Vec<String> = descendants(&content)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::PasswordEntryRow>().ok())
            .flat_map(|row| unlabelled_icon_buttons(&row))
            .collect();
        assert_eq!(unlabelled_icon_buttons(&content), peeks);
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.dialog.force_close();
        self.window.close();
    }
}

fn settings(stub: &CloudStub, machine: MachineId, dir: &tempfile::TempDir) -> AccountSettings {
    AccountSettings {
        client: AppClient::LINUX,
        endpoints: Endpoints::new(&stub.url, &format!("{}/v2", stub.url)).expect("the endpoints"),
        device: DeviceDescription {
            name: "Ada's laptop".to_owned(),
            app_version: "0.1.0".to_owned(),
            os_version: "Ubuntu 26.04".to_owned(),
        },
        machine_id: machine,
        keys: fakes::keys().expect("the test key"),
        account_file: dir.path().join("account.json"),
        callback_page: CallbackPage {
            finished: String::new(),
            unknown: String::new(),
        },
    }
}

fn query() -> ShareSubject {
    ShareSubject::query(
        "Orders".to_owned(),
        "SELECT * FROM orders".to_owned(),
        Some("postgres".to_owned()),
    )
}

fn result(rows: usize) -> ShareSubject {
    let columns: Arc<[ResultColumn]> = vec![
        ResultColumn::new("id", ColumnType::untyped_text("text")),
        ResultColumn::new("password", ColumnType::untyped_text("text")),
    ]
    .into();
    ShareSubject {
        rows: Some(SharedRows {
            columns,
            rows: (0..rows)
                .map(|id| RowSnapshot::new(vec![Value::Text(id.to_string()), Value::Null].into(), Vec::new()))
                .collect(),
            row_count: rows as u64,
        }),
        ..query()
    }
}

#[gtk4::test]
fn signed_out_the_sheet_offers_sign_in_and_nothing_else() {
    let harness = Harness::new(Cloud::free(0), query(), false);

    assert_eq!(harness.page(), Some(SheetPage::SignedOut));
    assert_eq!(harness.buttons("Sign In…").len(), 1);
    assert!(!harness.chrome().create.is_visible());
    assert!(harness.row_titles().is_empty());
    assert!(harness.stub.requests().iter().all(|request| !request.contains("share")));
}

#[gtk4::test]
fn a_free_result_shows_its_fields_pro_tags_preview_and_footer() {
    let mut cloud = Cloud::free(2);
    cloud.max_rows = 3;
    let harness = Harness::new(cloud, result(8), true);

    harness.wait_for(|page| *page == SheetPage::Form);

    assert_eq!(
        harness.row_titles(),
        [
            "Title",
            "Note",
            "Expires",
            "Hide SQL",
            "Password",
            "Allow viewers to download",
            "Some columns may hold secrets: password.",
        ]
    );
    let form = harness.dialog.imp().form.borrow();
    let values = form.as_ref().expect("the form").values();
    assert_eq!(values.title, "Orders");
    assert_eq!(values.expiry, tablepro_account::ShareExpiry::ThirtyDays);
    drop(form);
    let tags = harness.buttons("Pro");
    assert_eq!(tags.len(), 3, "Never, Password and downloads carry the tag");
    if crate::test_support::test_backend_records_properties() {
        for tag in &tags {
            assert!(
                gtk::test_accessible_has_property(tag, gtk::AccessibleProperty::Description),
                "a Pro tag does not say which option it is for"
            );
        }
    }
    let never = descendants(&harness.content())
        .into_iter()
        .find_map(|widget| widget.downcast::<adw::ToggleGroup>().ok())
        .and_then(|group| group.toggle_by_name("never"))
        .expect("the Never toggle");
    assert!(!never.is_enabled());
    let preview = descendants(&harness.content())
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::ColumnView>().ok())
        .expect("the preview");
    assert_eq!(preview.model().map(|model| model.n_items()), Some(5));
    let groups: Vec<adw::PreferencesGroup> = descendants(&harness.content())
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::PreferencesGroup>().ok())
        .collect();
    assert!(
        groups
            .iter()
            .any(|group| group.description().as_deref() == Some("Shares the first 3 of 8 rows."))
    );
    assert_eq!(harness.chrome().footer.label(), "Free · 2 of 5 links · first 3 rows");
    assert!(harness.chrome().create.is_visible());
    harness.audit();
}

#[gtk4::test]
fn create_copies_the_link_once_however_often_it_is_pressed() {
    let harness = Harness::new(Cloud::free(0), result(2), true);
    harness.wait_for(|page| *page == SheetPage::Form);

    harness.chrome().create.emit_clicked();
    harness.dialog.create();
    harness.wait_for(|page| matches!(page, SheetPage::Created { .. }));

    assert_eq!(
        harness.page(),
        Some(SheetPage::Created {
            url: URL.to_owned(),
            copied: true,
            columns_truncated: false,
        })
    );
    assert_eq!(harness.posts(), 1);
    assert_eq!(harness.buttons("Copy").len(), 1);
    assert_eq!(
        harness.dialog.focus(),
        harness.buttons("Copy").first().map(|copy| copy.clone().upcast()),
        "Copy does not take the focus"
    );
    assert_eq!(harness.buttons("Open in Browser").len(), 1);
    let clipboard = harness.dialog.clipboard();
    let copied = finish_on_main(WAIT, async move { clipboard.read_text_future().await })
        .expect("the clipboard to answer")
        .expect("text on the clipboard");
    assert_eq!(copied.as_deref(), Some(URL));
}

#[gtk4::test]
fn a_refused_create_keeps_the_form_and_says_why_in_the_plans_words() {
    let cloud = Cloud::free(0);
    *cloud.create.lock().expect("the create answer") = problem(403, "pro_required");
    let harness = Harness::new(cloud, query(), true);
    harness.wait_for(|page| *page == SheetPage::Form);

    harness.chrome().create.emit_clicked();
    wait_until(WAIT, || harness.chrome().banner.is_revealed()).expect("the refusal shown");

    assert_eq!(harness.chrome().banner.title(), "This option needs TablePro Pro.");
    assert_eq!(harness.page(), Some(SheetPage::Form));
    assert!(harness.chrome().create.is_sensitive());
}

#[gtk4::test]
fn at_the_limit_the_oldest_link_is_offered_first_and_a_revoke_brings_the_form_back() {
    let harness = Harness::new(Cloud::free(5), query(), true);
    harness.wait_for(|page| *page == SheetPage::AtLimit);

    assert_eq!(harness.row_titles(), ["Oldest", "Newest"]);
    let groups: Vec<adw::PreferencesGroup> = descendants(&harness.content())
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::PreferencesGroup>().ok())
        .collect();
    assert_eq!(
        groups[0].description().as_deref(),
        Some("You have 5 live links. Free allows 5. Revoke one to share another. Pro allows up to 1,000.")
    );
    harness.audit();

    harness.buttons("Revoke")[0].emit_clicked();
    harness.wait_for(|page| *page == SheetPage::Form);

    assert!(
        harness
            .stub
            .requests()
            .contains(&"DELETE /v2/shares/shr_old".to_owned())
    );
    assert_eq!(
        harness.chrome().footer.label(),
        "Free · 4 of 5 links · first 1,000 rows"
    );
}

#[gtk4::test]
fn an_unverified_email_offers_the_account_page_and_no_create() {
    let cloud = Cloud::free(0);
    cloud.verified.store(false, Ordering::SeqCst);
    let harness = Harness::new(cloud, query(), true);

    harness.wait_for(|page| *page == SheetPage::Unverified);

    assert_eq!(harness.buttons("Open Account").len(), 1);
    assert!(!harness.chrome().create.is_visible());
    assert_eq!(harness.posts(), 0);
}

#[gtk4::test]
fn a_query_share_has_no_hide_sql_and_pro_gets_its_own_options() {
    let mut cloud = Cloud::free(12);
    cloud.pro = true;
    let harness = Harness::new(cloud, query(), true);

    harness.wait_for(|page| *page == SheetPage::Form);

    assert_eq!(
        harness.row_titles(),
        ["Title", "Note", "Expires", "Password", "Allow viewers to download"]
    );
    assert!(harness.buttons("Pro").is_empty());
    assert_eq!(harness.chrome().footer.label(), "Pro · 12 links");
    harness.audit();
}

#[gtk4::test]
fn offline_the_sheet_says_so_and_try_again_reads_the_limits_again() {
    let cloud = Cloud::free(1);
    cloud.offline.store(true, Ordering::SeqCst);
    let harness = Harness::new(cloud, query(), true);
    harness.wait_for(|page| matches!(page, SheetPage::Failed(_)));

    assert_eq!(
        harness.page(),
        Some(SheetPage::Failed(
            "You appear to be offline. Try again once you’re connected.".to_owned()
        ))
    );
    harness.cloud.offline.store(false, Ordering::SeqCst);
    harness.buttons("Try Again")[0].emit_clicked();
    harness.wait_for(|page| *page == SheetPage::Form);

    assert_eq!(harness.requested("GET /v2/share-limits"), 2);
}

#[gtk4::test]
fn sharing_turned_off_says_so_and_offers_no_create() {
    let cloud = Cloud::free(0);
    cloud.disabled.store(true, Ordering::SeqCst);
    let harness = Harness::new(cloud, query(), true);

    harness.wait_for(|page| *page == SheetPage::Disabled);

    assert!(!harness.chrome().create.is_visible());
    assert_eq!(harness.posts(), 0);
}

#[gtk4::test]
fn closing_while_the_link_is_made_keeps_the_sheet_until_the_link_is_there() {
    let cloud = Cloud::free(0);
    cloud.hold_create.store(true, Ordering::SeqCst);
    let harness = Harness::new(cloud, query(), true);
    harness.wait_for(|page| *page == SheetPage::Form);

    harness.chrome().create.emit_clicked();
    wait_until(WAIT, || harness.posts() == 1).expect("the create sent");
    harness.dialog.close();
    harness.settle();

    assert!(
        harness
            .window
            .visible_dialog()
            .is_some_and(|shown| shown == harness.dialog),
        "the sheet closed with its link on the way"
    );
    assert!(harness.chrome().banner.is_revealed());
    harness.cloud.hold_create.store(false, Ordering::SeqCst);
    harness.wait_for(|page| matches!(page, SheetPage::Created { .. }));
    assert!(harness.dialog.can_close());
}

// The account holds its session through a call, so a real sign-out would wait for the read; the sheet
// leaving the read's page is what the read must respect.
#[gtk4::test]
fn a_read_that_lands_after_the_sheet_left_its_page_changes_nothing() {
    let cloud = Cloud::free(0);
    cloud.hold_limits.store(true, Ordering::SeqCst);
    let harness = Harness::new(cloud, query(), true);
    wait_until(WAIT, || harness.requested("GET /v2/share-limits") == 1).expect("the read sent");

    harness.dialog.show(SheetPage::SignedOut);
    harness.cloud.hold_limits.store(false, Ordering::SeqCst);
    let _ = wait_until(Duration::from_millis(500), || false);
    harness.settle();

    assert_eq!(harness.page(), Some(SheetPage::SignedOut));
}

#[gtk4::test]
fn a_sign_in_a_later_one_replaced_leaves_the_later_one_waiting() {
    let harness = Harness::with_browser(Cloud::free(0), query(), false, Arc::new(Silent));

    harness.buttons("Sign In…")[0].emit_clicked();
    harness.wait_for(|page| *page == SheetPage::SigningIn);
    harness.dialog.sign_in();
    let _ = wait_until(Duration::from_millis(500), || false);
    harness.settle();

    assert_eq!(harness.page(), Some(SheetPage::SigningIn));
    assert!(
        harness.dialog.imp().signing_in.borrow().is_some(),
        "the later sign-in lost its Cancel"
    );
    harness.dialog.cancel_sign_in();
    harness.wait_for(|page| *page == SheetPage::SignedOut);
}

#[gtk4::test]
fn a_create_refused_for_an_unverified_email_moves_to_that_page() {
    let cloud = Cloud::free(0);
    *cloud.create.lock().expect("the create answer") = problem(403, "email_unverified");
    *cloud.after_create.lock().expect("the change") = Some(|cloud| cloud.verified.store(false, Ordering::SeqCst));
    let harness = Harness::new(cloud, query(), true);
    harness.wait_for(|page| *page == SheetPage::Form);

    harness.chrome().create.emit_clicked();
    harness.wait_for(|page| *page == SheetPage::Unverified);

    assert_eq!(harness.buttons("Open Account").len(), 1);
}

#[gtk4::test]
fn a_revoke_after_the_limit_brings_the_form_back_as_it_was_typed() {
    let cloud = Cloud::free(4);
    *cloud.create.lock().expect("the create answer") = problem(409, "share_limit_reached");
    *cloud.after_create.lock().expect("the change") = Some(|cloud| cloud.live.store(5, Ordering::SeqCst));
    let harness = Harness::new(cloud, query(), true);
    harness.wait_for(|page| *page == SheetPage::Form);
    harness.entry("Title").set_text("Monthly orders");
    harness.entry("Note").set_text("For the review");

    harness.chrome().create.emit_clicked();
    harness.wait_for(|page| *page == SheetPage::AtLimit);
    harness.buttons("Revoke")[0].emit_clicked();
    harness.wait_for(|page| *page == SheetPage::Form);

    assert_eq!(harness.entry("Title").text(), "Monthly orders");
    assert_eq!(harness.entry("Note").text(), "For the review");
}

#[gtk4::test]
fn a_link_with_a_control_character_is_refused_rather_than_shown() {
    let cloud = Cloud::free(0);
    // JSON's escape for NUL, which no GTK label can hold.
    *cloud.create.lock().expect("the create answer") = (201, created(r"https://s.tablepro.app/a\u0000b"));
    let harness = Harness::new(cloud, query(), true);
    harness.wait_for(|page| *page == SheetPage::Form);

    harness.chrome().create.emit_clicked();
    wait_until(WAIT, || harness.chrome().banner.is_revealed()).expect("the refusal shown");

    assert_eq!(harness.page(), Some(SheetPage::Form));
    assert_eq!(
        harness.chrome().banner.title(),
        "The link couldn’t be created. Try again."
    );
}

#[gtk4::test]
fn a_link_the_clipboard_did_not_take_is_shown_as_created_not_copied() {
    let harness = Harness::new(Cloud::free(0), query(), true);
    harness.wait_for(|page| *page == SheetPage::Form);

    harness.dialog.show(SheetPage::Created {
        url: URL.to_owned(),
        copied: false,
        columns_truncated: false,
    });

    let status = harness
        .content()
        .downcast::<adw::StatusPage>()
        .expect("the created page");
    assert_eq!(status.title(), "Link created");
    assert_eq!(
        status.description().as_deref(),
        Some("The link could not be copied to the clipboard. Copy it with the button below.")
    );
    assert_eq!(harness.buttons("Copy").len(), 1);
}

fn wide_result(columns: usize) -> ShareSubject {
    let names: Arc<[ResultColumn]> = (0..columns)
        .map(|index| ResultColumn::new(format!("c{index}"), ColumnType::untyped_text("text")))
        .collect();
    ShareSubject {
        rows: Some(SharedRows {
            columns: names,
            rows: vec![RowSnapshot::new(
                (0..columns)
                    .map(|index| Value::Text(index.to_string()))
                    .collect::<Vec<_>>()
                    .into(),
                Vec::new(),
            )],
            row_count: 1,
        }),
        ..query()
    }
}

const TEAMS: &str = r#"[{"id":"team_01","name":"Data","live":3,"live_limit":1000,"public_links":true},
    {"id":"team_02","name":"Ops","live":0,"live_limit":1000,"public_links":false}]"#;

#[gtk4::test]
fn share_as_lists_personal_then_each_team_and_a_team_choice_reads_that_teams_limits() {
    let mut cloud = Cloud::free(12);
    cloud.pro = true;
    *cloud.teams.lock().expect("the teams") = TEAMS.to_owned();
    let harness = Harness::new(cloud, query(), true);
    harness.wait_for(|page| *page == SheetPage::Form);
    let rows: Vec<adw::ActionRow> = descendants(&harness.content())
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
        .filter(|row| {
            row.activatable_widget()
                .is_some_and(|widget| widget.is::<gtk::CheckButton>())
        })
        .collect();

    assert_eq!(
        rows.iter().map(|row| row.title().to_string()).collect::<Vec<_>>(),
        ["Personal", "Data", "Ops"]
    );
    assert!(!rows[2].is_sensitive());
    assert_eq!(
        rows[2].subtitle().as_deref(),
        Some("Public links are off for this team.")
    );
    assert_eq!(harness.chrome().footer.label(), "Pro · 12 links");
    harness.audit();

    assert!(WidgetExt::activate(&rows[1]), "the Data row did not activate");
    wait_until(WAIT, || harness.requested("GET /v2/share-limits") == 2).expect("the limits read again");
    harness.wait_for(|page| *page == SheetPage::Form);

    assert_eq!(harness.chrome().footer.label(), "Data · 3 of 1,000 links");
    let form = harness.dialog.imp().form.borrow();
    assert_eq!(
        form.as_ref().map(|form| form.values().team),
        Some(Some("team_01".to_owned()))
    );
}

#[gtk4::test]
fn a_result_past_the_column_cap_says_so_before_and_after_the_link_is_made() {
    let harness = Harness::new(Cloud::free(0), wide_result(101), true);
    harness.wait_for(|page| *page == SheetPage::Form);
    let preview = descendants(&harness.content())
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::ColumnView>().ok())
        .expect("the preview");
    let described = descendants(&harness.content())
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::PreferencesGroup>().ok())
        .any(|group| group.description().as_deref() == Some("Shares the first 100 columns."));

    assert!(described, "the preview does not say the columns are cut");
    assert_eq!(preview.columns().n_items(), 100);

    harness.chrome().create.emit_clicked();
    harness.wait_for(|page| matches!(page, SheetPage::Created { .. }));

    assert!(matches!(
        harness.page(),
        Some(SheetPage::Created {
            columns_truncated: true,
            ..
        })
    ));
    let status = harness
        .content()
        .downcast::<adw::StatusPage>()
        .expect("the created page");
    assert_eq!(
        status.description().as_deref(),
        Some("The link holds the first 100 columns of the result.")
    );
}

#[gtk4::test]
fn a_suspended_link_says_so_in_the_list_at_the_limit() {
    let cloud = Cloud::free(5);
    cloud.suspended.store(true, Ordering::SeqCst);
    let harness = Harness::new(cloud, query(), true);
    harness.wait_for(|page| *page == SheetPage::AtLimit);

    let newest = descendants(&harness.content())
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::ActionRow>().ok())
        .find(|row| row.title() == "Newest")
        .expect("the newest link");

    assert!(
        newest
            .subtitle()
            .is_some_and(|subtitle| subtitle.starts_with("Suspended · ")),
        "{:?}",
        newest.subtitle()
    );
}

#[gtk4::test]
fn a_table_view_is_read_up_to_the_plans_rows_before_the_form_shows() {
    use tablepro_core::Truncation;
    use tablepro_test_support::{ConnectionScript, FakeReply};

    let runtime = test_runtime();
    let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("name", ColumnType::untyped_text("text"))].into();
    let mut script = ConnectionScript::default();
    script.stream_read.always(FakeReply::ok(vec![
        tablepro_core::ResultEvent::ResultSetStarted { columns },
        tablepro_core::ResultEvent::Rows((0..7).map(|row| vec![Value::Text(format!("n{row}"))]).collect()),
        tablepro_core::ResultEvent::ResultSetFinished {
            retained: 7,
            total_rows: Some(7),
            truncation: Truncation::Complete,
        },
    ]));
    let fake = crate::test_support::FakeSession::start(script, [], runtime.tasks());
    let mut cloud = Cloud::free(0);
    cloud.max_rows = 3;
    let subject = ShareSubject {
        table: Some(crate::services::share_table::TableShare {
            session: fake.session.clone(),
            table: tablepro_core::meta::TableRef::new(None, "people"),
            columns: vec![crate::services::grid::test_columns::info("name", "text")].into(),
            shown: vec![0],
            filter: tablepro_core::FilterSet::default(),
            sort: Vec::new(),
            identity: tablepro_core::meta::RowIdentity::UniqueKey {
                columns: vec!["name".to_owned()],
            },
            total: Some(40),
        }),
        ..query()
    };
    let harness = Harness::new(cloud, subject, true);

    harness.wait_for(|page| *page == SheetPage::Form);

    let read = harness
        .dialog
        .subject()
        .and_then(|subject| subject.rows.clone())
        .expect("the rows read");
    assert_eq!(read.rows.len(), 3);
    assert_eq!(read.row_count, 40);
    let described = descendants(&harness.content())
        .into_iter()
        .filter_map(|widget| widget.downcast::<adw::PreferencesGroup>().ok())
        .any(|group| group.description().as_deref() == Some("Shares the first 3 of 40 rows."));
    assert!(described, "the cap note is missing");
}
