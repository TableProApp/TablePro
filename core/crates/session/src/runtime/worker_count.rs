// A database client is not compute-bound: its work is waiting on sockets and files. More workers than this only adds
// context switching, and fewer than two lets one blocking call stall the rest.
pub fn worker_count() -> usize {
    std::thread::available_parallelism().map_or(2, |count| clamped(count.get()))
}

fn clamped(available: usize) -> usize {
    available.clamp(2, 4)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_count_clamps() {
        assert_eq!(clamped(1), 2);
        assert_eq!(clamped(3), 3);
        assert_eq!(clamped(16), 4);
        assert!((2..=4).contains(&worker_count()));
    }
}
