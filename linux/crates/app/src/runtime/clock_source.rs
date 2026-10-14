use super::ClockSample;

pub trait ClockSource {
    fn sample(&self) -> ClockSample;
}
