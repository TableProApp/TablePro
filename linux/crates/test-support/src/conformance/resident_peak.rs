use std::fs;

use crate::conformance::ConformanceFailure;

/// How far the process's resident memory rose while a measure ran, by
/// the peak the kernel keeps for the process (`VmHWM`).
///
/// The peak is the whole process's, so it means something only while no
/// other test runs in the process: nextest gives each test a process of
/// its own.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ResidentPeak {
    baseline: u64,
}

impl ResidentPeak {
    /// Bring the kernel's peak down to what is resident now, and measure
    /// from there.
    pub(crate) fn start() -> Result<Self, ConformanceFailure> {
        // 5 resets the peak to the current resident size (proc_pid_clear_refs(5)).
        fs::write("/proc/self/clear_refs", "5")
            .map_err(|error| ConformanceFailure::setup(format!("could not reset the memory peak: {error}")))?;
        Ok(Self { baseline: peak()? })
    }

    /// Bytes the peak rose above where it stood at the start.
    pub(crate) fn growth(&self) -> Result<u64, ConformanceFailure> {
        Ok(peak()?.saturating_sub(self.baseline))
    }
}

fn peak() -> Result<u64, ConformanceFailure> {
    let status = fs::read_to_string("/proc/self/status")
        .map_err(|error| ConformanceFailure::setup(format!("could not read the memory peak: {error}")))?;
    peak_in(&status).ok_or_else(|| ConformanceFailure::setup("/proc/self/status has no VmHWM line"))
}

fn peak_in(status: &str) -> Option<u64> {
    let value = status.lines().find_map(|line| line.strip_prefix("VmHWM:"))?;
    let kib: u64 = value.trim().strip_suffix("kB")?.trim_end().parse().ok()?;
    kib.checked_mul(1024)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_peak_is_read_in_bytes_from_its_status_line() {
        let status = "Name:\ttest\nVmPeak:\t  900000 kB\nVmHWM:\t   20480 kB\nVmRSS:\t   10240 kB\n";

        assert_eq!(peak_in(status), Some(20 * 1024 * 1024));
        assert_eq!(peak_in("VmRSS:\t10240 kB\n"), None);
        assert_eq!(peak_in("VmHWM:\t10240 pages\n"), None);
    }

    const MIB: usize = 1024 * 1024;

    /// Pages that are resident, not only reserved.
    fn touched(bytes: usize) -> Vec<u8> {
        std::hint::black_box(vec![1; bytes])
    }

    #[test]
    fn a_reset_peak_counts_only_what_came_after() {
        drop(touched(96 * MIB));

        let peak = ResidentPeak::start().unwrap();
        let held = touched(24 * MIB);
        let growth = peak.growth().unwrap();
        drop(held);

        // A reset that did not take leaves the 96 MiB peak above the
        // 24 MiB, which then reads as no growth at all. Half is the bar
        // because the other tests in this process can free pages while
        // it runs.
        assert!(growth >= (12 * MIB) as u64, "{growth} bytes for 24 MiB held");
    }
}
