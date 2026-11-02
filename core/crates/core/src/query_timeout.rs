use std::time::Duration;

/// How long the SQL editor lets a statement run on one connection.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum QueryTimeout {
    /// The query timeout in Preferences, which every connection starts on.
    #[default]
    Preference,
    Off,
    After(Duration),
}

impl QueryTimeout {
    /// The seconds a connection saves: none follows Preferences, and
    /// zero turns the limit off, as zero does there.
    pub fn from_seconds(seconds: Option<u32>) -> Self {
        match seconds {
            None => Self::Preference,
            Some(0) => Self::Off,
            Some(seconds) => Self::After(Duration::from_secs(u64::from(seconds))),
        }
    }

    /// The limit a run gets, given the one Preferences sets.
    pub fn resolve(self, preference: Option<Duration>) -> Option<Duration> {
        match self {
            Self::Preference => preference,
            Self::Off => None,
            Self::After(limit) => Some(limit),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PREFERENCE: Option<Duration> = Some(Duration::from_secs(60));

    #[test]
    fn a_connection_without_its_own_timeout_follows_preferences() {
        assert_eq!(QueryTimeout::from_seconds(None), QueryTimeout::Preference);
        assert_eq!(QueryTimeout::Preference.resolve(PREFERENCE), PREFERENCE);
        assert_eq!(QueryTimeout::Preference.resolve(None), None);
    }

    #[test]
    fn a_connection_timeout_wins_over_preferences_and_zero_turns_it_off() {
        assert_eq!(
            QueryTimeout::from_seconds(Some(300)).resolve(PREFERENCE),
            Some(Duration::from_secs(300))
        );
        assert_eq!(
            QueryTimeout::from_seconds(Some(5)).resolve(None),
            Some(Duration::from_secs(5))
        );
        assert_eq!(QueryTimeout::from_seconds(Some(0)), QueryTimeout::Off);
        assert_eq!(QueryTimeout::Off.resolve(PREFERENCE), None);
    }
}
