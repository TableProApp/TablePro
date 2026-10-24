use std::io;
use std::time::{Duration, Instant};

use serde::Serialize;
use tablepro_app_services::workspace_state::{ConnectionWorkspaceState, WorkspaceStore, WorkspaceTabRecord};
use uuid::Uuid;

#[derive(Serialize)]
struct Measurement {
    connections: usize,
    draft_bytes_each: usize,
    updates: usize,
    read_chars: u64,
    written_chars: u64,
    cpu_runtime_ns: u64,
    update_elapsed_ns: u128,
    peak_rss_kib_before_updates: u64,
    peak_rss_kib: u64,
    restoration: &'static str,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = std::env::var_os("WORKSPACE_PROFILE_OUTPUT")
        .ok_or_else(|| io::Error::other("WORKSPACE_PROFILE_OUTPUT is required"))?;
    let connections = std::env::var("WORKSPACE_PROFILE_CONNECTIONS")?.parse::<usize>()?;
    if !matches!(connections, 1 | 4) {
        return Err(io::Error::other("WORKSPACE_PROFILE_CONNECTIONS must be 1 or 4").into());
    }
    let measurement = run_case(connections)?;
    std::fs::write(output, serde_json::to_vec_pretty(&measurement)?)?;
    Ok(())
}

fn run_case(connection_count: usize) -> Result<Measurement, Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("workspace_state.json");
    let drafts = dir.path().join("drafts");
    let store = WorkspaceStore::new(Some(path.clone()), drafts.clone());
    let ids: Vec<_> = (0..connection_count).map(|_| Uuid::new_v4()).collect();
    let original = "SELECT '東京é';\n".repeat(65_536);
    for id in &ids {
        store.save_connection(*id, record(original.clone()));
    }
    flush(&store)?;

    let before_read = process_io("rchar")?;
    let before_write = process_io("wchar")?;
    let before_cpu = process_cpu_runtime()?;
    let before_rss = process_value("/proc/self/status", "VmHWM")?;
    let started = Instant::now();
    let mut latest = String::new();
    for revision in 0..3 {
        latest = format!("{original}SELECT {revision};\n");
        store.save_connection(ids[0], record(latest.clone()));
        flush(&store)?;
    }
    let update_elapsed_ns = started.elapsed().as_nanos();
    let cpu_runtime_ns = process_cpu_runtime()? - before_cpu;
    let read_chars = process_io("rchar")? - before_read;
    let written_chars = process_io("wchar")? - before_write;
    let peak_rss_kib = process_value("/proc/self/status", "VmHWM")?;

    verify_restoration(&path, &drafts, &ids, connection_count, &latest, &original)?;
    Ok(Measurement {
        connections: connection_count,
        draft_bytes_each: original.len(),
        updates: 3,
        read_chars,
        written_chars,
        cpu_runtime_ns,
        update_elapsed_ns,
        peak_rss_kib_before_updates: before_rss,
        peak_rss_kib,
        restoration: "passed",
    })
}

fn record(query: String) -> ConnectionWorkspaceState {
    ConnectionWorkspaceState {
        tabs: vec![WorkspaceTabRecord::Editor {
            query,
            draft_id: None,
            file: None,
        }],
        ..Default::default()
    }
}

fn flush(store: &WorkspaceStore) -> io::Result<()> {
    store
        .flush()
        .recv_timeout(Duration::from_secs(5))
        .map_err(io::Error::other)?
        .map_err(|error| io::Error::other(format!("workspace flush failed: {error:?}")))
}

fn process_value(path: &str, name: &str) -> io::Result<u64> {
    let content = std::fs::read_to_string(path)?;
    content
        .lines()
        .find_map(|line| {
            let (key, value) = line.split_once(':')?;
            (key == name)
                .then(|| value.split_whitespace().next()?.parse().ok())
                .flatten()
        })
        .ok_or_else(|| io::Error::other(format!("{name} is absent from {path}")))
}

fn process_io(name: &str) -> io::Result<u64> {
    process_value("/proc/self/io", name)
}

fn process_cpu_runtime() -> io::Result<u64> {
    std::fs::read_dir("/proc/self/task")?.try_fold(0_u64, |total, entry| {
        let tid = entry?.file_name();
        let stat = std::fs::read_to_string(format!("/proc/self/task/{}/schedstat", tid.to_string_lossy()))?;
        let runtime = stat
            .split_whitespace()
            .next()
            .ok_or_else(|| io::Error::other("thread scheduler statistics are empty"))?
            .parse::<u64>()
            .map_err(io::Error::other)?;
        total
            .checked_add(runtime)
            .ok_or_else(|| io::Error::other("thread CPU time overflowed"))
    })
}

fn verify_restoration(
    path: &std::path::Path,
    drafts: &std::path::Path,
    ids: &[Uuid],
    connection_count: usize,
    latest: &str,
    original: &str,
) -> io::Result<()> {
    let restored = WorkspaceStore::new(Some(path.to_path_buf()), drafts.to_path_buf());
    restored
        .prefetch_connections(ids)
        .map_err(|error| io::Error::other(format!("workspace restore failed: {error:?}")))?;
    for (index, id) in ids.iter().enumerate() {
        let state = restored
            .load_connection(*id)
            .ok_or_else(|| io::Error::other("restored connection is missing"))?;
        let expected = if index == 0 { latest } else { original };
        if !matches!(&state.tabs[0], WorkspaceTabRecord::Editor { query, .. } if query == expected) {
            return Err(io::Error::other("restored editor query does not match"));
        }
    }
    if ids.len() != connection_count {
        return Err(io::Error::other("restored connection count does not match"));
    }
    Ok(())
}
