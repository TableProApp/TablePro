// The core's `tracing` events in the host's own log, as macOS's os_log or Windows' event tracing. Linux links the
// crates directly and logs them through its own subscriber.
//
// An event never waits for the host: it is queued for a thread of its own, which calls the sink outside every core
// lock (core ADR 0002), and a full queue drops the event and counts it. A sink that panics loses only that line.
//
// What a host may show as public: the event's callsite, which names its file and line and is fixed at build time, and
// the fields in `PUBLIC`, which hold codes, kind names and counts. The event's text is private like every other field,
// since a message can be formatted from what it reports. Only the core's own crates log here: a driver's library can
// log the statements it sends, as the Linux app's subscriber notes where it silences them, and the core maps what it
// needs from them into its own events.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use tracing::field::{Field, Visit};
use tracing::level_filters::LevelFilter;
use tracing::span::{Attributes, Id, Record};
use tracing::subscriber::Interest;
use tracing::{Event, Level, Metadata, Subscriber};

const PUBLIC: [&str; 4] = ["code", "kind", "reason", "count"];

// Lines queued for the sink at most; beyond it the emitter drops rather than waits.
const QUEUE: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreLogLevel {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

impl CoreLogLevel {
    const fn rank(self) -> u8 {
        match self {
            Self::Error => 1,
            Self::Warn => 2,
            Self::Info => 3,
            Self::Debug => 4,
            Self::Trace => 5,
        }
    }

    fn of(level: Level) -> Self {
        match level {
            Level::ERROR => Self::Error,
            Level::WARN => Self::Warn,
            Level::INFO => Self::Info,
            Level::DEBUG => Self::Debug,
            Level::TRACE => Self::Trace,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreLogField {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreLogLine {
    pub level: CoreLogLevel,
    // The module that logged, as `tablepro_sync::engine::held`.
    pub target: String,
    // The callsite, as `event core/crates/sync/src/engine/held.rs:50`; the event's text is the private `message` field.
    pub message: String,
    pub public_fields: Vec<CoreLogField>,
    pub private_fields: Vec<CoreLogField>,
}

// Called on a thread of the core's own, one line at a time, in the order the core logged them.
#[uniffi::export(callback_interface)]
pub trait CoreLogSink: Send + Sync {
    fn log(&self, line: CoreLogLine);
}

// Once at launch; a later call replaces the sink and the level.
#[uniffi::export]
pub fn set_core_log_sink(sink: Box<dyn CoreLogSink>, level: CoreLogLevel) {
    static BRIDGE: OnceLock<Bridge> = OnceLock::new();
    let mut installed = false;
    let bridge = BRIDGE.get_or_init(|| {
        installed = true;
        Bridge::start(QUEUE)
    });
    bridge.set(Arc::from(sink), level);
    // Another subscriber may already be the process's; the core then logs there.
    if installed {
        let _ = tracing::dispatcher::set_global_default(tracing::Dispatch::new(bridge.clone()));
    }
}

#[derive(Clone)]
struct Bridge {
    shared: Arc<Shared>,
    queue: SyncSender<CoreLogLine>,
}

struct Shared {
    level: AtomicU8,
    sink: Mutex<Option<Arc<dyn CoreLogSink>>>,
    dropped: AtomicU64,
}

impl Bridge {
    fn start(capacity: usize) -> Self {
        let (queue, lines) = sync_channel(capacity);
        let shared = Arc::new(Shared {
            level: AtomicU8::new(0),
            sink: Mutex::new(None),
            dropped: AtomicU64::new(0),
        });
        let forwarding = Arc::clone(&shared);
        // A thread that cannot start leaves the queue with no reader: every line is dropped, and nothing waits.
        let _ = std::thread::Builder::new()
            .name("tablepro-log".to_owned())
            .spawn(move || forward(&forwarding, &lines));
        Self { shared, queue }
    }

    fn set(&self, sink: Arc<dyn CoreLogSink>, level: CoreLogLevel) {
        let replaced = self
            .shared
            .sink
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .replace(sink);
        // Dropped once the lock is let go: the last reference to a foreign sink runs the host's own release.
        drop(replaced);
        self.shared.level.store(level.rank(), Ordering::SeqCst);
        tracing::callsite::rebuild_interest_cache();
    }

    fn takes(&self, level: Level) -> bool {
        CoreLogLevel::of(level).rank() <= self.shared.level.load(Ordering::Relaxed)
    }
}

fn forward(shared: &Shared, lines: &Receiver<CoreLogLine>) {
    while let Ok(line) = lines.recv() {
        let sink = shared.sink.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let Some(sink) = sink else { continue };
        let dropped = shared.dropped.swap(0, Ordering::SeqCst);
        if dropped > 0 {
            let _ = catch_unwind(AssertUnwindSafe(|| sink.log(dropped_line(dropped))));
        }
        let _ = catch_unwind(AssertUnwindSafe(|| sink.log(line)));
    }
}

fn dropped_line(count: u64) -> CoreLogLine {
    CoreLogLine {
        level: CoreLogLevel::Warn,
        target: module_path!().to_owned(),
        message: "log lines dropped while the host's log was behind".to_owned(),
        public_fields: vec![CoreLogField {
            name: "count".to_owned(),
            value: count.to_string(),
        }],
        private_fields: Vec::new(),
    }
}

impl Subscriber for Bridge {
    // The level can change at any time, so no callsite's answer is kept.
    fn register_callsite(&self, _metadata: &'static Metadata<'static>) -> Interest {
        Interest::sometimes()
    }

    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.is_event() && is_core(metadata) && self.takes(*metadata.level())
    }

    fn max_level_hint(&self) -> Option<LevelFilter> {
        Some(match self.shared.level.load(Ordering::Relaxed) {
            1 => LevelFilter::ERROR,
            2 => LevelFilter::WARN,
            3 => LevelFilter::INFO,
            4 => LevelFilter::DEBUG,
            5 => LevelFilter::TRACE,
            _ => LevelFilter::OFF,
        })
    }

    // Spans carry nothing the host's log takes.
    fn new_span(&self, _span: &Attributes<'_>) -> Id {
        Id::from_u64(1)
    }

    fn record(&self, _span: &Id, _values: &Record<'_>) {}

    fn record_follows_from(&self, _span: &Id, _follows: &Id) {}

    fn event(&self, event: &Event<'_>) {
        if !is_core(event.metadata()) || !self.takes(*event.metadata().level()) {
            return;
        }
        match self.queue.try_send(line_of(event)) {
            Ok(()) | Err(TrySendError::Disconnected(_)) => {}
            Err(TrySendError::Full(_)) => {
                self.shared.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    fn enter(&self, _span: &Id) {}

    fn exit(&self, _span: &Id) {}
}

fn is_core(metadata: &Metadata<'_>) -> bool {
    metadata.target().starts_with("tablepro")
}

fn line_of(event: &Event<'_>) -> CoreLogLine {
    let metadata = event.metadata();
    let mut fields = Fields::default();
    event.record(&mut fields);
    CoreLogLine {
        level: CoreLogLevel::of(*metadata.level()),
        target: metadata.target().to_owned(),
        message: metadata.name().to_owned(),
        public_fields: fields.public,
        private_fields: fields.private,
    }
}

#[derive(Default)]
struct Fields {
    public: Vec<CoreLogField>,
    private: Vec<CoreLogField>,
}

impl Fields {
    fn put(&mut self, field: &Field, value: String) {
        let entry = CoreLogField {
            name: field.name().to_owned(),
            value,
        };
        if PUBLIC.contains(&field.name()) {
            self.public.push(entry);
        } else {
            self.private.push(entry);
        }
    }
}

impl Visit for Fields {
    fn record_str(&mut self, field: &Field, value: &str) {
        self.put(field, value.to_owned());
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.put(field, value.to_string());
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.put(field, value.to_string());
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.put(field, value.to_string());
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.put(field, format!("{value:?}"));
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc::{Sender, channel};
    use std::time::{Duration, Instant};

    use super::*;

    struct Collect(Mutex<Sender<CoreLogLine>>);

    impl CoreLogSink for Collect {
        fn log(&self, line: CoreLogLine) {
            let _ = self.0.lock().unwrap().send(line);
        }
    }

    fn collecting(capacity: usize, level: CoreLogLevel) -> (Bridge, Receiver<CoreLogLine>) {
        let bridge = Bridge::start(capacity);
        let (sent, lines) = channel();
        bridge.set(Arc::new(Collect(Mutex::new(sent))), level);
        (bridge, lines)
    }

    fn field(name: &str, value: &str) -> CoreLogField {
        CoreLogField {
            name: name.to_owned(),
            value: value.to_owned(),
        }
    }

    fn next(lines: &Receiver<CoreLogLine>) -> CoreLogLine {
        lines.recv_timeout(Duration::from_secs(5)).unwrap()
    }

    // The event's text, which crosses as a private field.
    fn text(line: &CoreLogLine) -> &str {
        line.private_fields
            .iter()
            .find(|field| field.name == "message")
            .map_or("", |field| field.value.as_str())
    }

    #[test]
    fn a_core_line_shows_its_callsite_and_codes_and_keeps_its_text_and_the_rest_private() {
        let (bridge, lines) = collecting(QUEUE, CoreLogLevel::Info);

        tracing::subscriber::with_default(bridge, || {
            tracing::info!(
                target: "tablepro_sync::engine::held",
                kind = "connection",
                reason = "awaiting_approval",
                count = 2_u64,
                record_id = "6F1C2A9E",
                "records held"
            );
        });
        let line = next(&lines);

        assert_eq!(line.level, CoreLogLevel::Info);
        assert!(line.message.starts_with("event "), "{}", line.message);
        assert!(line.message.contains("core_log.rs:"), "{}", line.message);
        assert_eq!(
            line.public_fields,
            [
                field("kind", "connection"),
                field("reason", "awaiting_approval"),
                field("count", "2")
            ]
        );
        assert_eq!(
            line.private_fields,
            [field("message", "records held"), field("record_id", "6F1C2A9E")]
        );
    }

    // Codex review: a core message formatted from what it reports, as the SSH stderr line is, stays private.
    #[test]
    fn a_message_formatted_from_data_never_reaches_a_public_part() {
        let (bridge, lines) = collecting(QUEUE, CoreLogLevel::Trace);

        tracing::subscriber::with_default(bridge, || {
            let line = "debug1: Connecting to db.internal as app";
            tracing::debug!(target: "tablepro_ssh::session", "ssh: {line}");
        });
        let line = next(&lines);

        assert!(!line.message.contains("db.internal"), "{}", line.message);
        assert!(line.public_fields.is_empty());
        assert_eq!(text(&line), "ssh: debug1: Connecting to db.internal as app");
    }

    #[test]
    fn a_dependency_s_event_never_reaches_the_host() {
        let (bridge, lines) = collecting(QUEUE, CoreLogLevel::Trace);

        tracing::subscriber::with_default(bridge, || {
            tracing::warn!(target: "sqlx::query", statement = "SELECT * FROM orders", "slow statement");
            tracing::info!(target: "tablepro_sync", "after");
        });

        assert_eq!(text(&next(&lines)), "after");
        assert!(lines.recv_timeout(Duration::from_millis(100)).is_err());
    }

    #[test]
    fn a_level_below_the_one_set_is_not_sent() {
        let (bridge, lines) = collecting(QUEUE, CoreLogLevel::Warn);

        tracing::subscriber::with_default(bridge, || {
            tracing::info!(target: "tablepro_sync", "left out");
            tracing::warn!(target: "tablepro_sync", "kept");
        });

        assert_eq!(text(&next(&lines)), "kept");
        assert!(lines.recv_timeout(Duration::from_millis(100)).is_err());
    }

    struct Stuck {
        entered: Mutex<Sender<()>>,
        release: Mutex<Receiver<()>>,
    }

    impl CoreLogSink for Stuck {
        fn log(&self, _line: CoreLogLine) {
            let _ = self.entered.lock().unwrap().send(());
            let _ = self.release.lock().unwrap().recv();
        }
    }

    #[test]
    fn a_sink_that_never_returns_holds_no_event_and_the_lines_past_the_queue_are_counted() {
        let bridge = Bridge::start(4);
        let (entered, held) = channel();
        let (release, released) = channel();
        bridge.set(
            Arc::new(Stuck {
                entered: Mutex::new(entered),
                release: Mutex::new(released),
            }),
            CoreLogLevel::Info,
        );
        let started = Instant::now();

        tracing::subscriber::with_default(bridge.clone(), || {
            tracing::info!(target: "tablepro_sync", "first");
            held.recv_timeout(Duration::from_secs(5)).unwrap();
            for _ in 0..100 {
                tracing::info!(target: "tablepro_sync", "behind");
            }
        });

        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(bridge.shared.dropped.load(Ordering::SeqCst), 96);
        drop(release);
    }

    // A host's sink whose release registers a sink again, as a host that sets one up on teardown may.
    struct Reenters {
        bridge: Bridge,
        released: Mutex<Sender<()>>,
    }

    impl CoreLogSink for Reenters {
        fn log(&self, _line: CoreLogLine) {}
    }

    impl Drop for Reenters {
        fn drop(&mut self) {
            let (sent, _lines) = channel();
            self.bridge.set(Arc::new(Collect(Mutex::new(sent))), CoreLogLevel::Info);
            let _ = self.released.lock().unwrap().send(());
        }
    }

    // Codex review: the sink a new one replaces is let go outside the lock, so its release can call back in.
    #[test]
    fn a_replaced_sink_is_released_outside_the_lock() {
        let bridge = Bridge::start(QUEUE);
        let (released, done) = channel();
        bridge.set(
            Arc::new(Reenters {
                bridge: bridge.clone(),
                released: Mutex::new(released),
            }),
            CoreLogLevel::Info,
        );
        let replacing = bridge.clone();

        std::thread::spawn(move || {
            let (sent, _lines) = channel();
            replacing.set(Arc::new(Collect(Mutex::new(sent))), CoreLogLevel::Info);
        });

        assert!(done.recv_timeout(Duration::from_secs(5)).is_ok());
    }

    struct Panics(Mutex<Sender<CoreLogLine>>);

    impl CoreLogSink for Panics {
        fn log(&self, line: CoreLogLine) {
            if text(&line) == "fails" {
                panic!("the host's log failed");
            }
            let _ = self.0.lock().unwrap().send(line);
        }
    }

    #[test]
    fn a_sink_that_panics_loses_that_line_only() {
        let bridge = Bridge::start(QUEUE);
        let (sent, lines) = channel();
        bridge.set(Arc::new(Panics(Mutex::new(sent))), CoreLogLevel::Info);

        tracing::subscriber::with_default(bridge, || {
            tracing::info!(target: "tablepro_sync", "fails");
            tracing::info!(target: "tablepro_sync", "after");
        });

        assert_eq!(text(&next(&lines)), "after");
    }
}
