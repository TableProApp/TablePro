use std::process::ExitCode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Exit {
    Success = 0,
    Failure = 1,
    Usage = 2,
    Refused = 3,
    TimedOut = 4,
}

impl Exit {
    pub fn code(self) -> u8 {
        self as u8
    }
}

impl From<Exit> for ExitCode {
    fn from(exit: Exit) -> Self {
        ExitCode::from(exit.code())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_status_has_its_documented_number() {
        let codes: Vec<u8> = [Exit::Success, Exit::Failure, Exit::Usage, Exit::Refused, Exit::TimedOut]
            .into_iter()
            .map(Exit::code)
            .collect();

        assert_eq!(codes, vec![0, 1, 2, 3, 4]);
        assert_eq!(ExitCode::from(Exit::Refused), ExitCode::from(3));
    }
}
