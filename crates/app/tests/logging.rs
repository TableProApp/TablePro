#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::io;
use std::sync::{Arc, Mutex};

use tablepro_app::logging::{LogFormat, build_subscriber, log_format};
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::MakeWriter;

#[derive(Clone, Default)]
struct CapturedLogs(Arc<Mutex<Vec<u8>>>);

impl CapturedLogs {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).to_string()
    }
}

impl io::Write for CapturedLogs {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for CapturedLogs {
    type Writer = CapturedLogs;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

fn emit(format: LogFormat) -> String {
    let captured = CapturedLogs::default();
    let subscriber = build_subscriber(format, EnvFilter::new("info"), captured.clone());
    tracing::subscriber::with_default(subscriber, || {
        tracing::info!(drivers = 8, "starting tablepro-app");
    });
    captured.text()
}

#[test]
fn the_json_format_writes_one_structured_object_per_event() {
    let output = emit(LogFormat::Json);
    let line = output.lines().next().expect("a log line");
    let parsed: serde_json::Value = serde_json::from_str(line).expect("valid json");
    assert_eq!(parsed["level"], "INFO");
    assert_eq!(parsed["fields"]["message"], "starting tablepro-app");
    assert_eq!(parsed["fields"]["drivers"], 8);
}

#[test]
fn the_human_format_is_unchanged_and_hides_the_target() {
    let output = emit(LogFormat::Human);
    assert!(serde_json::from_str::<serde_json::Value>(output.trim()).is_err());
    assert!(output.contains("starting tablepro-app"), "{output}");
    assert!(output.contains("drivers"), "{output}");
    assert!(!output.contains("logging"), "{output}");
}

#[test]
fn an_unknown_log_format_falls_back_to_human_rather_than_failing() {
    assert_eq!(log_format(Some("yaml")), None);
    assert_eq!(log_format(None), Some(LogFormat::Human));
}
