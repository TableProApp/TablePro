use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};

use chrono::{Local, NaiveDate};
use posthog_rs::{ClientOptionsBuilder, Event};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tablepro_session::runtime::Tasks;

// A request PostHog does not answer holds a flush, and so the exit, this long at most.
const REQUEST_TIMEOUT_SECONDS: u64 = 5;
const SHUTDOWN_TIMEOUT_MS: u64 = 2_000;
// Each event carries the turn of Share Usage Data it was captured in until before_send takes it off.
const TURN: &str = "tablepro_turn";

// The keys macOS sets, so one PostHog person reads the same from either app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonProperties {
    pub app_version: String,
    pub os_version: String,
    pub architecture: String,
    pub locale: String,
}

pub struct TelemetrySettings {
    pub key: String,
    pub host: String,
    pub state_file: PathBuf,
    pub person: PersonProperties,
}

const SHUTDOWN_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

// clients.md, macOS Telemetry, without feature_gate_shown. Without a key there is nothing at all,
// and the PostHog client is made at the first time Share Usage Data is on. Clones share one.
#[derive(Clone, Default)]
pub struct Telemetry {
    inner: Arc<OnceLock<Arc<Inner>>>,
}

struct Inner {
    key: String,
    host: String,
    client: OnceLock<posthog_rs::Client>,
    kept: Mutex<Kept>,
    state_file: PathBuf,
    // The generation on disk: writes run on the blocking pool, so an older one may finish last.
    written: Arc<Mutex<u64>>,
    person: PersonProperties,
    tasks: Tasks,
    // The turn posthog-rs's worker checks each event against as it goes out, 0 while Share Usage Data is off.
    turn: Arc<AtomicU64>,
}

struct Kept {
    state: State,
    generation: u64,
    sharing: bool,
    // Moved each time Share Usage Data turns on, so an event queued before it went off stays unsent once it is on
    // again.
    turn: u64,
    connecting: bool,
    // Captured while the client was still being made, off the GTK thread.
    pending: Vec<Event>,
    account: Account,
    identified_this_run: Option<String>,
    // From the user's Sign Out until the status says signed out, an answer still on its way names that account.
    signing_out: bool,
}

// Unknown until the account has restored, so a launch never resets an identity it has not checked.
#[derive(Clone)]
enum Account {
    Unknown,
    Known(Option<String>),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct State {
    anonymous_id: String,
    // The account PostHog knows this install as, until a reset.
    #[serde(default)]
    identified: Option<String>,
    #[serde(default)]
    opened_on: Option<NaiveDate>,
    #[serde(default)]
    sent_once: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opened {
    pub driver_ids: Vec<String>,
    pub connection_count: usize,
}

impl Telemetry {
    pub fn start(settings: TelemetrySettings, sharing: bool, tasks: &Tasks) -> Self {
        let telemetry = Self::default();
        telemetry.begin(settings, sharing, tasks);
        telemetry
    }

    pub fn begin(&self, settings: TelemetrySettings, sharing: bool, tasks: &Tasks) {
        let key = settings.key.trim().to_owned();
        if key.is_empty() || self.inner.get().is_some() {
            return;
        }
        // A few bytes, read before any event can need the ID.
        let state = read_state(&settings.state_file);
        let inner = Arc::new(Inner {
            key,
            host: settings.host,
            client: OnceLock::new(),
            kept: Mutex::new(Kept {
                state: state.clone().unwrap_or_else(State::fresh),
                generation: 0,
                sharing: false,
                turn: 0,
                connecting: false,
                pending: Vec::new(),
                account: Account::Unknown,
                identified_this_run: None,
                signing_out: false,
            }),
            state_file: settings.state_file,
            written: Arc::new(Mutex::new(0)),
            person: settings.person,
            tasks: tasks.clone(),
            turn: Arc::new(AtomicU64::new(0)),
        });
        if self.inner.set(inner.clone()).is_err() {
            return;
        }
        if state.is_none() {
            inner.save(&mut inner.kept());
        }
        inner.set_sharing(sharing);
    }

    pub fn has_project_key(&self) -> bool {
        self.inner.get().is_some()
    }

    pub fn is_sending(&self) -> bool {
        self.inner
            .get()
            .is_some_and(|inner| inner.client.get().is_some() && inner.kept().sharing)
    }

    pub fn set_sharing(&self, sharing: bool) {
        if let Some(inner) = self.inner.get() {
            inner.set_sharing(sharing);
        }
    }

    // The account's ID while signed in, None signed out.
    pub fn account_changed(&self, account_id: Option<&str>) {
        let Some(inner) = self.inner.get() else {
            return;
        };
        let mut kept = inner.kept();
        match account_id {
            Some(_) if kept.signing_out => return,
            Some(_) => {}
            None => kept.signing_out = false,
        }
        kept.account = Account::Known(account_id.map(str::to_owned));
        inner.reconcile(&mut kept);
    }

    pub fn signed_in(&self, account_id: &str) {
        if let Some(inner) = self.inner.get() {
            inner.kept().signing_out = false;
        }
        self.account_changed(Some(account_id));
        self.capture("signed_in", vec![("method", Value::from("interactive"))]);
    }

    // The user's own sign-out: the event goes out as the account, what follows under a new anonymous ID.
    pub fn signed_out(&self) {
        let Some(inner) = self.inner.get() else {
            return;
        };
        let mut kept = inner.kept();
        inner.capture(&mut kept, "signed_out", Vec::new());
        kept.account = Account::Known(None);
        kept.signing_out = true;
        inner.reconcile(&mut kept);
    }

    // Once per local day, while Share Usage Data is on.
    pub fn app_opened(&self, opened: Opened) {
        self.app_opened_on(Local::now().date_naive(), opened);
    }

    pub fn connection_attempted(&self, driver_id: &str) {
        self.capture_once("connection_attempted", driver_id);
    }

    pub fn connection_succeeded(&self, driver_id: &str) {
        self.capture_once("connection_succeeded", driver_id);
    }

    pub fn query_executed(&self, driver_id: &str) {
        self.capture_once("first_query_executed", driver_id);
    }

    pub fn upgrade_clicked(&self, source: &str) {
        self.capture("upgrade_clicked", vec![("source", Value::from(source))]);
    }

    // The license ask, with no properties: the count of days used stays on this computer (clients.md, macOS).
    pub fn support_ask_shown(&self) {
        self.capture("support_ask_shown", Vec::new());
    }

    // Only `buy`: a toast that goes on its own is no answer, and it has no I Use It Personally.
    pub fn support_ask_answered(&self, answer: &str) {
        self.capture("support_ask_answered", vec![("answer", Value::from(answer))]);
    }

    // posthog-rs's flush waits for every event still queued, each up to its own request timeout, so the
    // wait is bounded here as a whole: quitting never holds for more than SHUTDOWN_WAIT.
    pub fn flush(&self) {
        let Some(inner) = self.inner.get().filter(|inner| inner.client.get().is_some()).cloned() else {
            return;
        };
        let (done, flushed) = std::sync::mpsc::channel();
        let flushing = std::thread::Builder::new()
            .name("usage-data-flush".to_owned())
            .spawn(move || {
                if let Some(client) = inner.client.get() {
                    client.flush();
                }
                let _ = done.send(());
            });
        if let Err(error) = flushing {
            tracing::warn!(%error, "the usage data was not flushed");
            return;
        }
        if flushed.recv_timeout(SHUTDOWN_WAIT).is_err() {
            tracing::info!("usage data still waiting for PostHog was left unsent");
        }
    }

    #[cfg(test)]
    fn has_client(&self) -> bool {
        self.inner.get().is_some_and(|inner| inner.client.get().is_some())
    }

    fn app_opened_on(&self, today: NaiveDate, opened: Opened) {
        let Some(inner) = self.inner.get() else {
            return;
        };
        let mut kept = inner.kept();
        if !kept.sharing || kept.state.opened_on == Some(today) {
            return;
        }
        kept.state.opened_on = Some(today);
        inner.save(&mut kept);
        let mut database_types: Vec<&str> = opened.driver_ids.iter().map(|id| database_type(id)).collect();
        database_types.sort_unstable();
        database_types.dedup();
        let properties = vec![
            ("database_types", Value::from(database_types)),
            ("connection_count", Value::from(opened.connection_count)),
        ];
        inner.capture(&mut kept, "app_opened", properties);
    }

    // As on macOS, the first one counts whether it went out or Share Usage Data was off.
    fn capture_once(&self, name: &str, driver_id: &str) {
        let Some(inner) = self.inner.get() else {
            return;
        };
        let mut kept = inner.kept();
        if !kept.state.sent_once.insert(name.to_owned()) {
            return;
        }
        inner.save(&mut kept);
        let properties = vec![("database_type", Value::from(database_type(driver_id)))];
        inner.capture(&mut kept, name, properties);
    }

    fn capture(&self, name: &str, properties: Vec<(&str, Value)>) {
        if let Some(inner) = self.inner.get() {
            inner.capture(&mut inner.kept(), name, properties);
        }
    }
}

impl Inner {
    fn kept(&self) -> MutexGuard<'_, Kept> {
        self.kept.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn set_sharing(self: &Arc<Self>, sharing: bool) {
        let mut kept = self.kept();
        if sharing && !kept.sharing {
            kept.turn += 1;
        }
        kept.sharing = sharing;
        self.turn.store(if sharing { kept.turn } else { 0 }, Ordering::SeqCst);
        if !sharing {
            kept.pending.clear();
            // An $identify still queued is dropped with the rest, so turning it on again sends it again.
            kept.identified_this_run = None;
            return;
        }
        self.reconcile(&mut kept);
        if self.client.get().is_some() || kept.connecting {
            return;
        }
        kept.connecting = true;
        let inner = self.clone();
        // reqwest's blocking client starts a runtime of its own, which a runtime worker may not drop.
        drop(self.tasks.spawn_blocking_task(move || inner.connect()));
    }

    fn connect(&self) {
        let turn = self.turn.clone();
        let options = ClientOptionsBuilder::default()
            .api_key(self.key.clone())
            .host(self.host.clone())
            .is_server(false)
            .request_timeout_seconds(REQUEST_TIMEOUT_SECONDS)
            .shutdown_timeout_ms(SHUTDOWN_TIMEOUT_MS)
            // Sent as captured and never tried again, so a failed one is lost rather than kept.
            .flush_at(1_usize)
            .max_capture_attempts(1_u32)
            // The worker sends one request at a time, so what was captured behind a slow one is dropped when sharing
            // goes off, and stays dropped once it is on again.
            .before_send(move |mut event| {
                let given = event.remove_prop(TURN).and_then(|turn| turn.as_u64());
                let current = turn.load(Ordering::SeqCst);
                (current != 0 && given == Some(current)).then_some(event)
            })
            .build();
        let options = match options {
            Ok(options) => options,
            Err(error) => {
                tracing::warn!(%error, "usage data stays off");
                self.kept().pending.clear();
                return;
            }
        };
        let client = posthog_rs::client(options);
        let mut kept = self.kept();
        if self.client.set(client).is_err() {
            return;
        }
        if let Some(client) = self.client.get() {
            for event in kept.pending.drain(..) {
                client.capture(event);
            }
        }
    }

    // While sharing, PostHog's person follows the account: a reset when it changed, an $identify once a run.
    fn reconcile(&self, kept: &mut Kept) {
        let Account::Known(account) = kept.account.clone() else {
            return;
        };
        if !kept.sharing {
            return;
        }
        if kept.state.identified.is_some() && kept.state.identified != account {
            kept.state.identified = None;
            kept.state.anonymous_id = State::fresh().anonymous_id;
            kept.identified_this_run = None;
            self.save(kept);
        }
        let Some(account) = account else {
            return;
        };
        if kept.identified_this_run.as_ref() == Some(&account) {
            return;
        }
        let anonymous_id = kept.state.anonymous_id.clone();
        kept.state.identified = Some(account.clone());
        kept.identified_this_run = Some(account.clone());
        self.save(kept);
        let mut event = Event::new("$identify".to_owned(), account);
        if let Err(error) = event
            .insert_prop("$anon_distinct_id", anonymous_id)
            .and_then(|()| event.insert_prop("$set", &self.person))
        {
            tracing::debug!(%error, "the identify event was not built");
            return;
        }
        self.send(kept, event);
    }

    fn capture(&self, kept: &mut Kept, name: &str, properties: Vec<(&str, Value)>) {
        if !kept.sharing {
            return;
        }
        let mut event = match &kept.state.identified {
            Some(account) => Event::new(name.to_owned(), account.clone()),
            // As posthog-ios's identifiedOnly: an anonymous event makes no person.
            None => {
                let mut event = Event::new(name.to_owned(), kept.state.anonymous_id.clone());
                if let Err(error) = event.insert_prop("$process_person_profile", false) {
                    tracing::debug!(%error, name, "a usage property was not added");
                }
                event
            }
        };
        for (key, value) in properties {
            if let Err(error) = event.insert_prop(key, value) {
                tracing::debug!(%error, name, "a usage property was not added");
            }
        }
        self.send(kept, event);
    }

    fn send(&self, kept: &mut Kept, mut event: Event) {
        if let Err(error) = event.insert_prop(TURN, kept.turn) {
            tracing::debug!(%error, "a usage event was not tagged");
            return;
        }
        match self.client.get() {
            Some(client) => client.capture(event),
            None => kept.pending.push(event),
        }
    }

    fn save(&self, kept: &mut Kept) {
        let bytes = match serde_json::to_vec_pretty(&kept.state) {
            Ok(bytes) => bytes,
            Err(error) => {
                tracing::warn!(%error, "the usage data state was not written");
                return;
            }
        };
        kept.generation += 1;
        let generation = kept.generation;
        let (path, written) = (self.state_file.clone(), self.written.clone());
        drop(self.tasks.spawn_blocking_task(move || {
            let mut written = written.lock().unwrap_or_else(PoisonError::into_inner);
            if *written > generation {
                return;
            }
            *written = generation;
            if let Err(error) = tablepro_storage::fs::write_private_blocking(&path, &bytes) {
                tracing::warn!(%error, "the usage data state was not written");
            }
        }));
    }
}

impl State {
    fn fresh() -> Self {
        Self {
            anonymous_id: uuid::Uuid::new_v4().to_string(),
            identified: None,
            opened_on: None,
            sent_once: BTreeSet::new(),
        }
    }
}

// macOS's DatabaseType names, so a breakdown by database type reads the same from either app. MariaDB goes
// through the MySQL driver and ScyllaDB through Cassandra's, so neither is told apart here.
fn database_type(driver_id: &str) -> &str {
    match driver_id {
        "cassandra" => "Cassandra",
        "clickhouse" => "ClickHouse",
        "duckdb" => "DuckDB",
        "mongodb" => "MongoDB",
        "mssql" => "SQL Server",
        "mysql" => "MySQL",
        "postgres" => "PostgreSQL",
        "redis" => "Redis",
        "sqlite" => "SQLite",
        other => other,
    }
}

// clients.md lists macOS's arm64 or x86_64, and Rust names arm64 aarch64.
pub(crate) fn architecture(target_arch: &str) -> &str {
    match target_arch {
        "aarch64" => "arm64",
        other => other,
    }
}

fn read_state(path: &Path) -> Option<State> {
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice(&bytes)
        .inspect_err(|error| tracing::warn!(%error, "the usage data state does not read; starting a new one"))
        .ok()
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;
    use crate::test_support::{PostHogCollector as Collector, test_runtime};

    const WAIT: Duration = Duration::from_secs(20);
    const ACCOUNT: &str = "acct_01k8d6wk00f8xsr79e7x052rkk";

    fn person() -> PersonProperties {
        PersonProperties {
            app_version: "0.1.0-test".to_owned(),
            os_version: "Ubuntu 26.04 LTS".to_owned(),
            architecture: "arm64".to_owned(),
            locale: "vi_VN".to_owned(),
        }
    }

    fn start(key: &str, sharing: bool, collector: &Collector, dir: &tempfile::TempDir, tasks: &Tasks) -> Telemetry {
        let settings = TelemetrySettings {
            key: key.to_owned(),
            host: collector.url.clone(),
            state_file: dir.path().join("telemetry.json"),
            person: person(),
        };
        Telemetry::start(settings, sharing, tasks)
    }

    fn until(condition: impl Fn() -> bool) {
        let started = Instant::now();
        while !condition() {
            assert!(started.elapsed() < WAIT, "gave up waiting");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn kept(dir: &tempfile::TempDir) -> Option<serde_json::Value> {
        serde_json::from_str(&std::fs::read_to_string(dir.path().join("telemetry.json")).ok()?).ok()
    }

    // Writes run on the blocking pool, so the state shows a change a little after the call.
    fn kept_when(dir: &tempfile::TempDir, condition: impl Fn(&serde_json::Value) -> bool) -> serde_json::Value {
        let started = Instant::now();
        loop {
            if let Some(state) = kept(dir).filter(|state| condition(state)) {
                return state;
            }
            assert!(started.elapsed() < WAIT, "gave up waiting");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn opened() -> Opened {
        Opened {
            driver_ids: ["postgres", "mysql", "postgres"].map(str::to_owned).to_vec(),
            connection_count: 3,
        }
    }

    fn everything(telemetry: &Telemetry) {
        telemetry.app_opened(opened());
        telemetry.connection_attempted("postgres");
        telemetry.connection_succeeded("postgres");
        telemetry.query_executed("postgres");
        telemetry.upgrade_clicked("app-settings");
        telemetry.signed_in(ACCOUNT);
        telemetry.signed_out();
        telemetry.flush();
    }

    fn names(collector: &Collector) -> Vec<String> {
        collector
            .events()
            .iter()
            .map(|event| event["event"].as_str().unwrap_or_default().to_owned())
            .collect()
    }

    // The properties the app sets, without those posthog-rs adds to every event.
    fn own_properties(event: &serde_json::Value) -> Vec<String> {
        let properties: std::collections::BTreeMap<String, serde_json::Value> =
            serde_json::from_value(event["properties"].clone()).unwrap_or_default();
        properties
            .into_keys()
            .filter(|key| !key.starts_with("$lib") && key != "$os" && key != "$os_version")
            .collect()
    }

    #[test]
    fn without_a_project_key_nothing_leaves_the_machine() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");

        let telemetry = start("  ", true, &collector, &dir, &runtime.tasks());
        everything(&telemetry);
        telemetry.account_changed(Some(ACCOUNT));
        std::thread::sleep(Duration::from_millis(500));

        assert!(!telemetry.has_project_key());
        assert!(!telemetry.has_client());
        assert_eq!(collector.connections(), 0);
        assert!(!dir.path().join("telemetry.json").exists());
    }

    #[test]
    fn launched_with_usage_data_off_no_client_is_made_and_the_identify_waits_until_it_is_on() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");

        let telemetry = start("phc_test", false, &collector, &dir, &runtime.tasks());
        everything(&telemetry);
        // The status the sign-out ends in, then a later sign-in.
        telemetry.account_changed(None);
        telemetry.account_changed(Some(ACCOUNT));
        std::thread::sleep(Duration::from_millis(500));
        let made_while_off = telemetry.has_client();
        let sent_while_off = collector.connections();
        telemetry.set_sharing(true);
        until(|| !collector.named("$identify").is_empty());

        assert!(telemetry.has_project_key());
        assert!(!made_while_off);
        assert_eq!(sent_while_off, 0);
        assert_eq!(names(&collector), ["$identify"]);
        assert_eq!(collector.named("$identify")[0]["distinct_id"], ACCOUNT);
    }

    #[test]
    fn each_event_carries_the_properties_clients_md_lists() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());

        everything(&telemetry);

        until(|| !collector.named("signed_out").is_empty());
        assert_eq!(
            names(&collector),
            [
                "app_opened",
                "connection_attempted",
                "connection_succeeded",
                "first_query_executed",
                "upgrade_clicked",
                "$identify",
                "signed_in",
                "signed_out"
            ]
        );
        let event = |name: &str| collector.named(name).remove(0);
        let opened = event("app_opened");
        assert_eq!(
            opened["properties"]["database_types"],
            serde_json::json!(["MySQL", "PostgreSQL"])
        );
        assert_eq!(opened["properties"]["connection_count"], 3);
        assert_eq!(opened["properties"]["$process_person_profile"], false);
        assert_eq!(
            own_properties(&opened),
            ["$process_person_profile", "connection_count", "database_types"]
        );
        for name in ["connection_attempted", "connection_succeeded", "first_query_executed"] {
            let once = event(name);
            assert_eq!(once["properties"]["database_type"], "PostgreSQL", "{name}");
            assert_eq!(
                own_properties(&once),
                ["$process_person_profile", "database_type"],
                "{name}"
            );
        }
        assert_eq!(event("upgrade_clicked")["properties"]["source"], "app-settings");
        let identify = event("$identify");
        assert_eq!(identify["distinct_id"], ACCOUNT);
        assert_eq!(identify["properties"]["$anon_distinct_id"], opened["distinct_id"]);
        let person: std::collections::BTreeMap<String, String> =
            serde_json::from_value(identify["properties"]["$set"].clone()).expect("the person properties");
        let expected = [
            ("app_version", "0.1.0-test"),
            ("architecture", "arm64"),
            ("locale", "vi_VN"),
            ("os_version", "Ubuntu 26.04 LTS"),
        ]
        .map(|(key, value)| (key.to_owned(), value.to_owned()));
        assert_eq!(person, std::collections::BTreeMap::from(expected));
        let signed_in = event("signed_in");
        assert_eq!(signed_in["distinct_id"], ACCOUNT);
        assert_eq!(own_properties(&signed_in), ["method"]);
        assert_eq!(signed_in["properties"]["method"], "interactive");
        let signed_out = event("signed_out");
        assert_eq!(signed_out["distinct_id"], ACCOUNT);
        assert!(own_properties(&signed_out).is_empty(), "{signed_out}");
        assert!(collector.bodies()[0].contains("phc_test"));
    }

    #[test]
    fn an_event_leaves_as_it_is_captured_without_a_flush() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());

        let captured = Instant::now();
        telemetry.upgrade_clicked("app-settings");
        while collector.named("upgrade_clicked").is_empty() {
            // posthog-rs's own batching would hold it for 5 seconds.
            assert!(
                captured.elapsed() < Duration::from_secs(4),
                "the event waited in the queue"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn the_first_connection_and_query_count_once_per_install_and_the_launch_once_a_day() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        telemetry.app_opened(opened());
        telemetry.connection_attempted("sqlite");
        telemetry.connection_attempted("postgres");
        telemetry.query_executed("sqlite");
        until(|| !collector.named("first_query_executed").is_empty());
        let today = Local::now().date_naive().to_string();
        until(|| {
            kept(&dir).is_some_and(|state| {
                state["opened_on"] == today.as_str()
                    && state["sent_once"].as_array().is_some_and(|sent| sent.len() == 2)
            })
        });

        let restarted = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| restarted.is_sending());
        restarted.app_opened(opened());
        restarted.connection_attempted("redis");
        restarted.query_executed("redis");
        restarted.connection_succeeded("redis");
        until(|| !collector.named("connection_succeeded").is_empty());

        assert_eq!(collector.named("app_opened").len(), 1);
        let attempts = collector.named("connection_attempted");
        assert_eq!(attempts.len(), 1);
        assert_eq!(attempts[0]["properties"]["database_type"], "SQLite");
        assert_eq!(collector.named("first_query_executed").len(), 1);
        assert_eq!(
            collector.named("connection_succeeded")[0]["distinct_id"],
            attempts[0]["distinct_id"]
        );
    }

    #[test]
    fn turned_off_nothing_is_captured_identified_or_reset_and_a_sign_out_meanwhile_resets_once_on_again() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());
        telemetry.signed_in(ACCOUNT);
        until(|| !collector.named("signed_in").is_empty());
        let anonymous = kept_when(&dir, |state| state["identified"] == ACCOUNT)["anonymous_id"].clone();

        telemetry.set_sharing(false);
        telemetry.signed_out();
        telemetry.connection_attempted("sqlite");
        telemetry.upgrade_clicked("app-settings");
        telemetry.signed_in("acct_01k8d6x3q0f8xsr79e7x052zzz");
        telemetry.account_changed(None);
        telemetry.flush();
        std::thread::sleep(Duration::from_millis(500));
        let while_off = names(&collector);
        let state_while_off = kept_when(&dir, |state| {
            state["sent_once"].as_array().is_some_and(|sent| !sent.is_empty())
        });

        telemetry.set_sharing(true);
        telemetry.upgrade_clicked("app-settings");
        until(|| !collector.named("upgrade_clicked").is_empty());

        assert_eq!(while_off, ["$identify", "signed_in"]);
        assert_eq!(state_while_off["identified"], ACCOUNT);
        assert_eq!(state_while_off["anonymous_id"], anonymous);
        assert_eq!(names(&collector), ["$identify", "signed_in", "upgrade_clicked"]);
        let after = &collector.named("upgrade_clicked")[0];
        assert_ne!(after["distinct_id"], anonymous);
        assert_ne!(after["distinct_id"], ACCOUNT);
        assert_eq!(after["properties"]["$process_person_profile"], false);
        kept_when(&dir, |state| state["identified"].is_null());
    }

    #[test]
    fn a_launch_signed_in_identifies_once_and_a_restored_sign_out_resets_without_an_event() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        telemetry.account_changed(Some(ACCOUNT));
        telemetry.account_changed(Some(ACCOUNT));
        until(|| collector.named("$identify").len() == 1);
        kept_when(&dir, |state| state["identified"] == ACCOUNT);

        let restarted = start("phc_test", true, &collector, &dir, &runtime.tasks());
        restarted.upgrade_clicked("app-settings");
        restarted.account_changed(None);
        restarted.connection_attempted("sqlite");
        until(|| !collector.named("connection_attempted").is_empty());

        assert_eq!(collector.named("$identify").len(), 1);
        assert_eq!(collector.named("upgrade_clicked")[0]["distinct_id"], ACCOUNT);
        let after = &collector.named("connection_attempted")[0];
        assert_ne!(after["distinct_id"], ACCOUNT);
        assert!(collector.named("signed_out").is_empty());
    }

    #[test]
    fn every_driver_the_app_registers_reports_the_name_macos_sends() {
        let registry = crate::build_registry();

        let mut reported: Vec<(&str, &str)> = registry
            .iter()
            .map(|driver| (driver.id(), database_type(driver.id())))
            .collect();
        reported.sort_unstable();

        assert_eq!(
            reported,
            [
                ("cassandra", "Cassandra"),
                ("clickhouse", "ClickHouse"),
                ("duckdb", "DuckDB"),
                ("mongodb", "MongoDB"),
                ("mssql", "SQL Server"),
                ("mysql", "MySQL"),
                ("postgres", "PostgreSQL"),
                ("redis", "Redis"),
                ("sqlite", "SQLite"),
            ]
        );
        assert_eq!(database_type("a-driver-from-later"), "a-driver-from-later");
    }

    #[test]
    fn the_architecture_is_the_name_macos_sends() {
        let cases = [("aarch64", "arm64"), ("x86_64", "x86_64"), ("riscv64", "riscv64")];

        for (target_arch, sent) in cases {
            assert_eq!(architecture(target_arch), sent, "{target_arch}");
        }
    }

    #[test]
    fn a_running_app_sends_app_opened_again_on_the_next_local_day() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        let day = NaiveDate::from_ymd_opt(2026, 10, 30).expect("a day");
        let next = day.succ_opt().expect("the next day");

        telemetry.app_opened_on(day, opened());
        telemetry.app_opened_on(day, opened());
        telemetry.app_opened_on(next, opened());
        telemetry.app_opened_on(next, opened());

        until(|| collector.named("app_opened").len() == 2);
        telemetry.flush();
        assert_eq!(collector.named("app_opened").len(), 2);
        kept_when(&dir, |state| state["opened_on"] == "2026-10-31");
    }

    #[test]
    fn a_send_posthog_refuses_is_not_tried_again() {
        let runtime = test_runtime();
        let collector = Collector::answering(503);
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());

        telemetry.upgrade_clicked("app-settings");
        telemetry.flush();
        // posthog-rs's default would try twice more, 200 and 400 ms apart.
        std::thread::sleep(Duration::from_millis(1_500));
        telemetry.flush();

        assert_eq!(collector.bodies().len(), 1);
    }

    #[test]
    fn an_event_waiting_behind_a_slow_request_is_dropped_when_turned_off() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());
        collector.hold();

        telemetry.upgrade_clicked("app-settings");
        until(|| !collector.named("upgrade_clicked").is_empty());
        telemetry.connection_attempted("sqlite");
        telemetry.set_sharing(false);
        collector.release();
        telemetry.flush();

        assert_eq!(names(&collector), ["upgrade_clicked"]);
    }

    #[test]
    fn an_event_queued_before_turning_off_stays_unsent_once_on_again() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());
        collector.hold();

        telemetry.upgrade_clicked("app-settings");
        until(|| !collector.named("upgrade_clicked").is_empty());
        telemetry.connection_attempted("sqlite");
        telemetry.set_sharing(false);
        telemetry.set_sharing(true);
        telemetry.query_executed("sqlite");
        collector.release();
        telemetry.flush();

        assert_eq!(names(&collector), ["upgrade_clicked", "first_query_executed"]);
    }

    #[test]
    fn an_identify_dropped_when_turned_off_goes_out_once_on_again() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());
        collector.hold();

        telemetry.upgrade_clicked("app-settings");
        until(|| !collector.named("upgrade_clicked").is_empty());
        telemetry.account_changed(Some(ACCOUNT));
        telemetry.set_sharing(false);
        telemetry.set_sharing(true);
        collector.release();
        telemetry.flush();

        assert_eq!(names(&collector), ["upgrade_clicked", "$identify"]);
    }

    #[test]
    fn quitting_waits_for_posthog_at_most_the_shutdown_wait_however_many_events_queue() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());
        collector.hold();
        for source in ["app-settings", "app-ask", "app-settings", "app-ask"] {
            telemetry.upgrade_clicked(source);
        }

        let started = Instant::now();
        telemetry.flush();
        let waited = started.elapsed();
        collector.release();

        assert!(waited < SHUTDOWN_WAIT + Duration::from_secs(1), "{waited:?}");
    }

    #[test]
    fn after_the_users_sign_out_an_answer_still_naming_the_account_identifies_nobody() {
        let runtime = test_runtime();
        let collector = Collector::start();
        let dir = tempfile::tempdir().expect("a temporary directory");
        let telemetry = start("phc_test", true, &collector, &dir, &runtime.tasks());
        until(|| telemetry.is_sending());
        telemetry.signed_in(ACCOUNT);

        telemetry.signed_out();
        telemetry.account_changed(Some(ACCOUNT));
        telemetry.upgrade_clicked("app-settings");
        until(|| !collector.named("upgrade_clicked").is_empty());
        telemetry.flush();
        let identified_meanwhile = collector.named("$identify").len();
        telemetry.account_changed(None);
        telemetry.account_changed(Some(ACCOUNT));
        until(|| collector.named("$identify").len() == 2);

        assert_eq!(identified_meanwhile, 1);
        assert_eq!(collector.named("signed_out").len(), 1);
        let after = &collector.named("upgrade_clicked")[0];
        assert_ne!(after["distinct_id"], ACCOUNT);
        assert_eq!(after["properties"]["$process_person_profile"], false);
    }
}
