/// SQL Server's `IDENTITY(seed, increment)` as the catalog lists it. Text,
/// since a decimal identity's numbers go past any integer type.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct IdentitySeed {
    seed: String,
    increment: String,
}

impl IdentitySeed {
    /// `None` unless both are whole numbers, the only form an identity
    /// takes, so nothing else reaches a statement.
    pub fn new(seed: &str, increment: &str) -> Option<Self> {
        (whole_number(seed) && whole_number(increment)).then(|| Self {
            seed: seed.to_owned(),
            increment: increment.to_owned(),
        })
    }

    pub fn seed(&self) -> &str {
        &self.seed
    }

    pub fn increment(&self) -> &str {
        &self.increment
    }
}

fn whole_number(text: &str) -> bool {
    let digits = text.strip_prefix('-').unwrap_or(text);
    !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_whole_numbers_make_a_seed() {
        assert!(IdentitySeed::new("-3", "1").is_some());
        assert_eq!(IdentitySeed::new("1)", "1"), None);
        assert_eq!(IdentitySeed::new("", "1"), None);
    }
}
