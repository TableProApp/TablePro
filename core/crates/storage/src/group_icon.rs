use serde::{Deserialize, Serialize};

use crate::ConnectionIcon;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupIcon {
    Named(ConnectionIcon),
    /// Kept so a macOS library round-trips. Only the Apple apps can draw
    /// it; the others draw the plain folder.
    Symbol(SymbolName),
}

/// The shape macOS accepts from a file. Whether the symbol exists is the
/// Apple app's question, since a newer macOS knows names an older one
/// does not.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct SymbolName(String);

impl SymbolName {
    pub const MAX_BYTES: usize = 100;

    pub fn new(value: &str) -> Option<Self> {
        let name = value.trim();
        let well_formed = !name.is_empty()
            && name.len() <= Self::MAX_BYTES
            && name.split('.').all(|part| {
                !part.is_empty()
                    && part
                        .bytes()
                        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
            });
        well_formed.then(|| Self(name.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for SymbolName {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(&value).ok_or("a symbol name is dot-separated lowercase letters and digits, at most 100 bytes")
    }
}

impl From<SymbolName> for String {
    fn from(name: SymbolName) -> Self {
        name.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_symbol_name_takes_the_shape_macos_reads() {
        for good in ["folder", "server.rack", "externaldrive.fill", "1.circle", " star "] {
            assert!(SymbolName::new(good).is_some(), "{good:?}");
        }
        for bad in [
            "",
            "  ",
            "Folder",
            "server..rack",
            ".star",
            "star.",
            "star fill",
            "star-fill",
        ] {
            assert_eq!(SymbolName::new(bad), None, "{bad:?}");
        }
        assert!(SymbolName::new(&"a".repeat(SymbolName::MAX_BYTES)).is_some());
        assert_eq!(SymbolName::new(&"a".repeat(SymbolName::MAX_BYTES + 1)), None);
    }

    #[test]
    fn each_kind_of_icon_is_stored_under_its_own_key() {
        let named = GroupIcon::Named(ConnectionIcon::Server);
        let symbol = GroupIcon::Symbol(SymbolName::new("server.rack").expect("a symbol"));

        let named_json = serde_json::to_string(&named).expect("serialize");
        let symbol_json = serde_json::to_string(&symbol).expect("serialize");

        assert_eq!(named_json, r#"{"named":"server"}"#);
        assert_eq!(symbol_json, r#"{"symbol":"server.rack"}"#);
        assert_eq!(serde_json::from_str::<GroupIcon>(&named_json).expect("named"), named);
        assert_eq!(serde_json::from_str::<GroupIcon>(&symbol_json).expect("symbol"), symbol);
    }

    #[test]
    fn a_malformed_symbol_or_an_unknown_icon_is_refused() {
        assert!(serde_json::from_str::<GroupIcon>(r#"{"symbol":"Not A Symbol"}"#).is_err());
        assert!(serde_json::from_str::<GroupIcon>(r#"{"named":"rocket"}"#).is_err());
    }
}
