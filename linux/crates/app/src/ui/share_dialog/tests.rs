use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{TimeDelta, Utc};
use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_account::{
    Account, AccountSettings, AccountStatus, AppClient, CallbackPage, DeviceDescription, Endpoints, MachineId, fakes,
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
    verified: bool,
    live: AtomicU64,
    max_rows: u64,
    create: Mutex<(u16, String)>,
    revoked: AtomicBool,
}

impl Cloud {
    fn free(live: u64) -> Self {
        Self {
            pro: false,
            verified: true,
            live: AtomicU64::new(live),
            max_rows: 1_000,
            create: Mutex::new((201, created())),
            revoked: AtomicBool::new(false),
        }
    }

    fn limits(&self) -> String {
        let (plan, limit, expiries, default) = match self.pro {
            true => ("pro", 1_000, r#"["1d","7d","30d","never"]"#, "never"),
            false => ("free", 5, r#"["1d","7d","30d"]"#, "30d"),
        };
        format!(
            r#"{{"plan":"{plan}","live":{},"live_limit":{limit},"max_rows":{},"expiries":{expiries},"default_expiry":"{default}","password":{pro},"disable_download":{pro},"team":{pro},"email_verified":{},"sharing_disabled":false}}"#,
            self.live.load(Ordering::SeqCst),
            self.max_rows,
            self.verified,
            pro = self.pro,
        )
    }

    fn answer(&self, method: &str, path: &str) -> Option<(u16, String)> {
        match (method, path) {
            ("GET", "/v2/share-limits") => Some((200, self.limits())),
            ("GET", "/v2/shares") => Some((
                200,
                format!(
                    r#"{{"data":[{},{}]}}"#,
                    view("shr_new", "Newest", 1),
                    view("shr_old", "Oldest", 9)
                ),
            )),
            ("POST", "/v2/shares") => Some(self.create.lock().expect("the create answer").clone()),
            ("DELETE", "/v2/shares/shr_old") => {
                self.revoked.store(true, Ordering::SeqCst);
                self.live.fetch_sub(1, Ordering::SeqCst);
                Some((204, String::new()))
            }
            _ => None,
        }
    }
}

fn view(id: &str, title: &str, days_ago: i64) -> String {
    let at = (Utc::now() - TimeDelta::days(days_ago)).to_rfc3339();
    format!(
        r#"{{"id":"{id}","kind":"query","scope":"account","title":"{title}","note":"","dialect":"postgres","has_snapshot":false,"hide_sql":false,"allow_download":true,"has_password":false,"state":"live","view_count":0,"created_at":"{at}","updated_at":"{at}"}}"#
    )
}

fn created() -> String {
    format!(
        r#"{{"share":{},"token":"Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK","url":"{URL}"}}"#,
        view("shr_made", "Orders", 0)
    )
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
    _runtime: AppRuntime,
    _dir: tempfile::TempDir,
}

impl Harness {
    fn new(cloud: Cloud, subject: ShareSubject, sign_in: bool) -> Self {
        crate::register_test_resources();
        let runtime = test_runtime();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let machine = MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID");
        let stub = stub(&machine, Arc::new(cloud));
        let (status, receiver) = watch::channel(AccountStatus::SignedOut);
        let account = Account::new(
            settings(&stub, machine, &dir),
            Arc::new(MemoryKeyring::default()),
            Arc::new(Approving),
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
    ShareSubject {
        title: "Orders".to_owned(),
        sql: "SELECT * FROM orders".to_owned(),
        dialect: Some("postgres".to_owned()),
        rows: None,
    }
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
    assert_eq!(
        harness.buttons("Pro").len(),
        3,
        "Never, Password and downloads carry the tag"
    );
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
    harness.wait_for(|page| matches!(page, SheetPage::Created(_)));

    assert_eq!(harness.page(), Some(SheetPage::Created(URL.to_owned())));
    assert_eq!(harness.posts(), 1);
    assert_eq!(harness.buttons("Copy").len(), 1);
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
        Some("You have 5 live links, the Free limit. Revoke one to share another. Pro allows up to 1,000.")
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
    let mut cloud = Cloud::free(0);
    cloud.verified = false;
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
