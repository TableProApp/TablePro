use std::time::Duration;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CloseBehaviour {
    #[default]
    Immediate,
    Delay(Duration),
    Hang,
}
